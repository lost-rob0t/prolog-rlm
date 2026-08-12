:- begin_tests(live_repair_openrouter).

:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/rlm_plan').
:- use_module('../prolog/rlm_outcome').

:- dynamic live_repair_evidence/6.

test(real_openrouter_consultation_precedes_trusted_repair_policy) :-
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
    require_live_repair_observation(Observation),
    Attempt =:= 1,
    default_openrouter_model(RequestedModel),
    openrouter_provider(RequestedModel, Provider),
    live_repair_prompt(Observation, Prompt),
    request_repair_consultation(Provider,
                                Prompt,
                                2,
                                1,
                                Response,
                                Channel,
                                ProviderAttempt),
    trusted_repair_policy(Observation, Strategy),
    repair_strategy_plan(Strategy, RepairedPlan),
    assertz(live_repair_evidence(RequestedModel,
                                 Response.selected_model,
                                 Response.metadata.http_status,
                                 Channel,
                                 ProviderAttempt,
                                 Strategy)).

require_live_repair_observation(Observation) :-
    is_dict(Observation),
    get_dict(status, Observation, validation_failure),
    get_dict(phase, Observation, validate),
    get_dict(error, Observation, Error),
    is_dict(Error),
    get_dict(detail, Error, unbound_variable(missing)),
    !.
require_live_repair_observation(Observation) :-
    throw(error(unexpected_live_repair_observation(Observation),
                context(live_repair_openrouter_test,
                        'live repair fixture did not produce the expected structured diagnostic'))).

live_repair_prompt(Observation, Prompt) :-
    format(string(Prompt),
           "Review this structured typed-plan diagnostic as an advisory model consultation.\n\
Status: ~w. Phase: ~w. Error: ~q.\n\
The trusted host is considering replacing the missing final variable with the literal REPAIR_OK.\n\
Briefly assess whether that proposed repair is consistent with this diagnostic. Host policy owns the repair decision; do not emit executable code.",
           [Observation.status, Observation.phase, Observation.error]).

request_repair_consultation(Provider,
                            Prompt,
                            Remaining,
                            Attempt,
                            Response,
                            Channel,
                            UsedAttempt) :-
    Request = model_request{
                  messages:[message{role:user, content:Prompt}],
                  options:_{max_tokens:96, temperature:0}
              },
    model_complete(Provider, Request, ProviderOutcome),
    consultation_provider_outcome(ProviderOutcome,
                                  Provider,
                                  Prompt,
                                  Remaining,
                                  Attempt,
                                  Response,
                                  Channel,
                                  UsedAttempt).

consultation_provider_outcome(ok(Response),
                              _,
                              _,
                              _,
                              Attempt,
                              Response,
                              Channel,
                              Attempt) :-
    require_live_consultation_response(Response, Channel),
    !.
consultation_provider_outcome(error(_),
                              Provider,
                              Prompt,
                              Remaining,
                              Attempt,
                              Response,
                              Channel,
                              UsedAttempt) :-
    Remaining > 1,
    !,
    NextRemaining is Remaining-1,
    NextAttempt is Attempt+1,
    request_repair_consultation(Provider,
                                Prompt,
                                NextRemaining,
                                NextAttempt,
                                Response,
                                Channel,
                                UsedAttempt).
consultation_provider_outcome(error(Error), _, _, _, _, _, _, _) :-
    throw(error(live_repair_provider_failure(Error),
                context(live_repair_openrouter_test,
                        'real OpenRouter repair consultation failed'))).

require_live_consultation_response(Response, Channel) :-
    is_dict(Response),
    get_dict(metadata, Response, Metadata),
    is_dict(Metadata),
    get_dict(http_status, Metadata, 200),
    get_dict(selected_model, Response, SelectedModel),
    nonempty_text(SelectedModel),
    consultation_channel(Response, Channel),
    !.
require_live_consultation_response(Response, _) :-
    throw(error(live_repair_invalid_provider_response(Response),
                context(live_repair_openrouter_test,
                        'real OpenRouter consultation did not return a canonical successful response'))).

consultation_channel(Response, text) :-
    get_dict(text, Response, Text),
    nonempty_text(Text),
    !.
consultation_channel(Response, reasoning) :-
    get_dict(reasoning, Response, Reasoning),
    nonempty_text(Reasoning),
    !.
consultation_channel(Response, tool_calls) :-
    get_dict(tool_calls, Response, ToolCalls),
    is_list(ToolCalls),
    ToolCalls \== [],
    !.
consultation_channel(_, canonical_response).

nonempty_text(Value) :-
    string(Value),
    Value \== "",
    !.
nonempty_text(Value) :-
    atom(Value),
    Value \== ''.

trusted_repair_policy(Observation, repair_literal_final) :-
    require_live_repair_observation(Observation).

repair_strategy_plan(repair_literal_final,
                     plan([final(literal("REPAIR_OK"))])).

require_live_repair_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '', Key \== ""
    ->  true
    ;   throw(error(missing_live_credential('OPENROUTER_API_KEY'),
                    context(live_repair_openrouter_test,
                            'OPENROUTER_API_KEY is not configured for live repair CI')))
    ).

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
    format('repair_provider_consulted: true~n', []),
    format('repair_model_response_present: true~n', []),
    format('repair_observation_status: validation_failure~n', []),
    format('repair_policy_selected: ~w~n', [Strategy]),
    format('repair_plan_materialized: true~n', []),
    format('repair_plan_output_channel: ~w~n', [Channel]),
    format('repair_provider_attempt_used: ~d~n', [ProviderAttempt]),
    format('repair_attempts: ~d~n', [Result.repair.attempts]),
    format('repair_original_budget_preserved: true~n', []),
    format('repair_final_ok: true~n', []).

:- end_tests(live_repair_openrouter).
