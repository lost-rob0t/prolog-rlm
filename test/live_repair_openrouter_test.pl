:- begin_tests(live_repair_openrouter).

:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/rlm_plan').
:- use_module('../prolog/rlm_outcome').

:- dynamic live_repair_evidence/6.

test(real_openrouter_repairs_structured_validation_failure) :-
    require_live_repair_credential,
    retractall(live_repair_evidence(_, _, _, _, _, _)),
    BrokenPlan = plan([final(var(missing))]),
    Options = [ budget(_{max_steps:4,
                         max_depth:1,
                         max_parallel:1,
                         max_model_calls:0,
                         max_tool_calls:0,
                         max_context_ops:0,
                         max_output_bytes:4096,
                         time_limit:120.0}),
                outcome_limits(_{max_repairs:1,
                                  repair_time_limit:90.0,
                                  trace_max_nodes:16,
                                  trace_max_bytes:4096})
              ],
    plan_repair(BrokenPlan,
                [],
                Options,
                _{},
                openrouter_repair,
                Outcome),
    require_live_repair_success(Outcome, Result),
    validate_live_repair_result(Result),
    log_live_repair_evidence(Result).

openrouter_repair(Observation, Attempt, _, RepairedPlan) :-
    Observation.status == validation_failure,
    Attempt =:= 1,
    default_openrouter_model(RequestedModel),
    openrouter_provider(RequestedModel, Provider),
    live_repair_prompt(Observation, Prompt),
    request_repair_strategy(Provider,
                            Prompt,
                            2,
                            1,
                            Response,
                            Strategy,
                            Channel,
                            ProviderAttempt),
    repair_strategy_plan(Strategy, RepairedPlan),
    assertz(live_repair_evidence(RequestedModel,
                                 Response.selected_model,
                                 Response.metadata.http_status,
                                 Channel,
                                 ProviderAttempt,
                                 Strategy)).

live_repair_prompt(Observation, Prompt) :-
    format(string(Prompt),
           "You are selecting a repair strategy for a closed typed execution plan.\n\
The structured diagnostic status is ~w and phase is ~w.\n\
The structured error is ~q.\n\
Choose exactly one strategy token:\n\
REPAIR_LITERAL_FINAL - replace the invalid final expression with the literal REPAIR_OK.\n\
ABORT - do not repair.\n\
This validation failure is repairable with the first strategy. Return only REPAIR_LITERAL_FINAL.",
           [Observation.status, Observation.phase, Observation.error]).

request_repair_strategy(Provider,
                        Prompt,
                        Remaining,
                        Attempt,
                        Response,
                        Strategy,
                        Channel,
                        UsedAttempt) :-
    Request = model_request{
                  messages:[message{role:user, content:Prompt}],
                  options:_{max_tokens:64, temperature:0}
              },
    model_complete(Provider, Request, ProviderOutcome),
    require_live_repair_provider_success(ProviderOutcome, Candidate),
    (   response_repair_strategy(Candidate, CandidateStrategy, CandidateChannel)
    ->  Response = Candidate,
        Strategy = CandidateStrategy,
        Channel = CandidateChannel,
        UsedAttempt = Attempt
    ;   retry_repair_strategy(Provider,
                              Prompt,
                              Remaining,
                              Attempt,
                              Response,
                              Strategy,
                              Channel,
                              UsedAttempt)
    ).

retry_repair_strategy(Provider,
                      Prompt,
                      Remaining,
                      Attempt,
                      Response,
                      Strategy,
                      Channel,
                      UsedAttempt) :-
    Remaining > 1,
    !,
    NextRemaining is Remaining-1,
    NextAttempt is Attempt+1,
    request_repair_strategy(Provider,
                            Prompt,
                            NextRemaining,
                            NextAttempt,
                            Response,
                            Strategy,
                            Channel,
                            UsedAttempt).
retry_repair_strategy(_, _, _, _, _, _, _, _) :-
    throw(error(live_repair_strategy_failure,
                context(live_repair_openrouter_test,
                        'real model responses did not select an allowed repair strategy'))).

response_repair_strategy(Response, Strategy, text) :-
    get_dict(text, Response, Text),
    repair_strategy_value(Text, Strategy),
    !.
response_repair_strategy(Response, Strategy, reasoning) :-
    get_dict(reasoning, Response, Reasoning),
    repair_strategy_value(Reasoning, Strategy),
    !.

repair_strategy_value(Value, repair_literal_final) :-
    text_string(Value, Text),
    sub_string(Text, _, _, _, "REPAIR_LITERAL_FINAL"),
    \+ sub_string(Text, _, _, _, "ABORT").

repair_strategy_plan(repair_literal_final,
                     plan([final(literal("REPAIR_OK"))])).

text_string(Value, Value) :-
    string(Value),
    !.
text_string(Value, String) :-
    atom(Value),
    atom_string(Value, String).

require_live_repair_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '', Key \== ""
    ->  true
    ;   throw(error(missing_live_credential('OPENROUTER_API_KEY'),
                    context(live_repair_openrouter_test,
                            'OPENROUTER_API_KEY is not configured for live repair CI')))
    ).

require_live_repair_provider_success(ok(Response), Response) :- !.
require_live_repair_provider_success(error(Error), _) :-
    throw(error(live_repair_provider_failure(Error),
                context(live_repair_openrouter_test,
                        'real OpenRouter repair request failed'))).

require_live_repair_success(Outcome, Result) :-
    (   is_dict(Outcome),
        get_dict(status, Outcome, success)
    ->  Result = Outcome
    ;   throw(error(live_repair_execution_failure(Outcome),
                    context(live_repair_openrouter_test,
                            'structured repair did not finish successfully')))
    ).

validate_live_repair_result(Result) :-
    assertion(Result.value == "REPAIR_OK"),
    assertion(Result.repair.attempts =:= 1),
    Result.repair.history = [RepairEvent],
    assertion(RepairEvent.status == repair_proposed),
    assertion(RepairEvent.diagnostic == validation_failure),
    assertion(Result.budget_remaining.steps =:= 3),
    assertion(Result.error == none),
    assertion(live_repair_evidence(_, _, 200, _, _, repair_literal_final)).

log_live_repair_evidence(Result) :-
    live_repair_evidence(RequestedModel,
                         SelectedModel,
                         HttpStatus,
                         Channel,
                         ProviderAttempt,
                         Strategy),
    format('repair_provider: openrouter~n', []),
    format('repair_requested_model: ~w~n', [RequestedModel]),
    format('repair_selected_model: ~w~n', [SelectedModel]),
    format('repair_http_status: ~d~n', [HttpStatus]),
    format('repair_observation_status: validation_failure~n', []),
    format('repair_strategy_selected: ~w~n', [Strategy]),
    format('repair_plan_materialized: true~n', []),
    format('repair_plan_output_channel: ~w~n', [Channel]),
    format('repair_provider_attempt_used: ~d~n', [ProviderAttempt]),
    format('repair_attempts: ~d~n', [Result.repair.attempts]),
    format('repair_original_budget_preserved: true~n', []),
    format('repair_final_ok: true~n', []).

:- end_tests(live_repair_openrouter).
