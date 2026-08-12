:- begin_tests(live_plan_openrouter).

:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/rlm_context').
:- use_module('../prolog/rlm_plan').
:- use_module('support/plan_test_tools').

test(real_openrouter_model_produces_executable_typed_plan) :-
    require_live_plan_credential,
    context_register(text("alpha\nneedle one\nneedle two\nomega"), [], ok(Ref)),
    setup_call_cleanup(
        true,
        run_live_plan_case(Ref.handle),
        context_delete(Ref.handle, _)).

run_live_plan_case(Handle) :-
    default_openrouter_model(RequestedModel),
    openrouter_provider(RequestedModel, Provider),
    planner_prompt(Prompt),
    real_typed_plan_attempt(1,
                            2,
                            Provider,
                            Prompt,
                            Response,
                            Plan,
                            PlanChannel,
                            AttemptUsed),
    Caps = [context(search), tool(count_items)],
    Runtime = [providers([provider_ref(openrouter, Provider)]),
               tools([tool(count_items, plan_test_tools:count_items)]),
               context_options([max_results(8), max_bytes(1024)]),
               budget(_{max_steps:8,
                        max_depth:2,
                        max_parallel:2,
                        max_model_calls:0,
                        max_tool_calls:2,
                        max_context_ops:2,
                        max_output_bytes:8192,
                        time_limit:5.0})],
    plan_run(Plan, Caps, Runtime, _{context:Handle}, PlanOutcome),
    require_live_plan_execution_success(PlanOutcome, Result),
    validate_live_plan_result(Result),
    log_live_plan_evidence(RequestedModel,
                           Response,
                           PlanChannel,
                           AttemptUsed,
                           Result).

real_typed_plan_attempt(Attempt,
                        MaxAttempts,
                        Provider,
                        Prompt,
                        Response,
                        Plan,
                        PlanChannel,
                        AttemptUsed) :-
    Request = model_request{
                  messages:[message{role:user, content:Prompt}],
                  options:_{max_tokens:512}
              },
    model_complete(Provider, Request, ProviderOutcome),
    require_live_plan_provider_success(ProviderOutcome, Candidate),
    (   response_typed_plan(Candidate, CandidatePlan, CandidateChannel)
    ->  Response = Candidate,
        Plan = CandidatePlan,
        PlanChannel = CandidateChannel,
        AttemptUsed = Attempt
    ;   Attempt < MaxAttempts
    ->  Next is Attempt+1,
        real_typed_plan_attempt(Next,
                                MaxAttempts,
                                Provider,
                                Prompt,
                                Response,
                                Plan,
                                PlanChannel,
                                AttemptUsed)
    ;   throw(error(live_plan_parse_failure,
                    context(live_plan_openrouter_test,
                            'real model responses did not contain a valid typed JSON plan')))
    ).

planner_prompt(
"Return ONLY one JSON object. No markdown and no explanation.\n\
You are selecting a typed plan for this goal: search the opaque external context input named context for the literal word needle, count the matches with the trusted tool count_items, and return that count.\n\
Use exactly these available operations: context search, tool count_items, final.\n\
The JSON must have this exact shape and binding names:\n\
{\"steps\":[\
{\"op\":\"context\",\"handle\":{\"ref\":\"input\",\"name\":\"context\"},\"action\":{\"type\":\"search\",\"pattern\":\"needle\"},\"bind\":\"hits\"},\
{\"op\":\"tool\",\"name\":\"count_items\",\"args\":{\"ref\":\"var\",\"name\":\"hits\"},\"bind\":\"count\"},\
{\"op\":\"final\",\"value\":{\"ref\":\"var\",\"name\":\"count\"}}]}" ).

require_live_plan_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '', Key \== ""
    ->  true
    ;   throw(error(missing_live_credential('OPENROUTER_API_KEY'),
                    context(live_plan_openrouter_test,
                            'OPENROUTER_API_KEY is not configured for live plan CI')))
    ).

require_live_plan_provider_success(ok(Response), Response) :-
    !.
require_live_plan_provider_success(error(Error), _) :-
    throw(error(live_plan_provider_failure(Error),
                context(live_plan_openrouter_test,
                        'real OpenRouter planner request failed'))).

response_typed_plan(Response, Plan, text) :-
    get_dict(text, Response, Text),
    nonempty_string(Text),
    plan_parse(Text, ok(Plan)),
    !.
response_typed_plan(Response, Plan, reasoning) :-
    get_dict(reasoning, Response, Reasoning),
    nonempty_string(Reasoning),
    plan_parse(Reasoning, ok(Plan)),
    !.

nonempty_string(Value) :-
    string(Value),
    Value \== "".

require_live_plan_execution_success(ok(Result), Result) :-
    !.
require_live_plan_execution_success(error(Error), _) :-
    throw(error(live_plan_execution_failure(Error),
                context(live_plan_openrouter_test,
                        'real model-selected typed plan failed execution'))).

validate_live_plan_result(Result) :-
    assertion(Result.value =:= 2),
    assertion(length(Result.transitions, 3)),
    Result.transitions = [ContextTransition, ToolTransition, FinalTransition],
    assertion(ContextTransition.operation == context(search)),
    assertion(ToolTransition.operation == tool(count_items)),
    assertion(FinalTransition.operation == final).

log_live_plan_evidence(RequestedModel,
                       Response,
                       PlanChannel,
                       AttemptUsed,
                       Result) :-
    length(Result.transitions, TransitionCount),
    format('plan_provider: openrouter~n', []),
    format('plan_requested_model: ~w~n', [RequestedModel]),
    format('plan_selected_model: ~w~n', [Response.selected_model]),
    format('plan_http_status: ~d~n', [Response.metadata.http_status]),
    format('plan_response_received: true~n', []),
    format('plan_parsed: true~n', []),
    format('plan_output_channel: ~w~n', [PlanChannel]),
    format('plan_attempt_used: ~d~n', [AttemptUsed]),
    format('plan_context_executed: true~n', []),
    format('plan_tool_executed: true~n', []),
    format('plan_final_ok: true~n', []),
    format('plan_transition_count: ~d~n', [TransitionCount]).

:- end_tests(live_plan_openrouter).
