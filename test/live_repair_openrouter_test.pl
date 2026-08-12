:- begin_tests(live_repair_openrouter).

:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/rlm_plan').
:- use_module('../prolog/rlm_outcome').

:- dynamic live_repair_evidence/5.

test(real_openrouter_repairs_structured_validation_failure) :-
    require_live_repair_credential,
    retractall(live_repair_evidence(_, _, _, _, _)),
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
    request_required_repair_plan(Provider,
                                 Prompt,
                                 2,
                                 1,
                                 Response,
                                 RepairedPlan,
                                 Channel,
                                 ProviderAttempt),
    assertz(live_repair_evidence(RequestedModel,
                                 Response.selected_model,
                                 Response.metadata.http_status,
                                 Channel,
                                 ProviderAttempt)).

live_repair_prompt(Observation, Prompt) :-
    format(string(Prompt),
           "You are repairing a closed typed execution plan from a structured diagnostic.\n\
The diagnostic status is ~w and phase is ~w.\n\
Return ONLY the replacement JSON plan below, with no markdown and no explanation.\n\
{\"steps\":[{\"op\":\"final\",\"value\":{\"ref\":\"literal\",\"value\":\"REPAIR_OK\"}}]}",
           [Observation.status, Observation.phase]).

request_required_repair_plan(Provider,
                             Prompt,
                             Remaining,
                             Attempt,
                             Response,
                             Plan,
                             Channel,
                             UsedAttempt) :-
    Request = model_request{
                  messages:[message{role:user, content:Prompt}],
                  options:_{max_tokens:384, temperature:0}
              },
    model_complete(Provider, Request, ProviderOutcome),
    require_live_repair_provider_success(ProviderOutcome, Candidate),
    (   response_repair_plan(Candidate, CandidatePlan, CandidateChannel),
        required_repair_plan(CandidatePlan)
    ->  Response = Candidate,
        Plan = CandidatePlan,
        Channel = CandidateChannel,
        UsedAttempt = Attempt
    ;   retry_repair_plan(Provider,
                          Prompt,
                          Remaining,
                          Attempt,
                          Response,
                          Plan,
                          Channel,
                          UsedAttempt)
    ).

retry_repair_plan(Provider,
                  Prompt,
                  Remaining,
                  Attempt,
                  Response,
                  Plan,
                  Channel,
                  UsedAttempt) :-
    Remaining > 1,
    !,
    NextRemaining is Remaining-1,
    NextAttempt is Attempt+1,
    request_required_repair_plan(Provider,
                                 Prompt,
                                 NextRemaining,
                                 NextAttempt,
                                 Response,
                                 Plan,
                                 Channel,
                                 UsedAttempt).
retry_repair_plan(_, _, _, _, _, _, _, _) :-
    throw(error(live_repair_plan_shape_failure,
                context(live_repair_openrouter_test,
                        'real model responses did not contain the required repair plan'))).

response_repair_plan(Response, Plan, text) :-
    get_dict(text, Response, Text),
    nonempty_string(Text),
    plan_parse(Text, ok(Plan)),
    !.
response_repair_plan(Response, Plan, reasoning) :-
    get_dict(reasoning, Response, Reasoning),
    nonempty_string(Reasoning),
    plan_parse(Reasoning, ok(Plan)),
    !.

required_repair_plan(plan([final(literal("REPAIR_OK"))])).

nonempty_string(Value) :-
    string(Value),
    Value \== "".

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
    assertion(live_repair_evidence(_, _, 200, _, _)).

log_live_repair_evidence(Result) :-
    live_repair_evidence(RequestedModel,
                         SelectedModel,
                         HttpStatus,
                         Channel,
                         ProviderAttempt),
    format('repair_provider: openrouter~n', []),
    format('repair_requested_model: ~w~n', [RequestedModel]),
    format('repair_selected_model: ~w~n', [SelectedModel]),
    format('repair_http_status: ~d~n', [HttpStatus]),
    format('repair_observation_status: validation_failure~n', []),
    format('repair_plan_parsed: true~n', []),
    format('repair_plan_output_channel: ~w~n', [Channel]),
    format('repair_provider_attempt_used: ~d~n', [ProviderAttempt]),
    format('repair_attempts: ~d~n', [Result.repair.attempts]),
    format('repair_original_budget_preserved: true~n', []),
    format('repair_final_ok: true~n', []).

:- end_tests(live_repair_openrouter).
