:- begin_tests(live_tool_openrouter).

:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/rlm_plan').
:- use_module('../prolog/rlm_tool').

test(real_openrouter_selects_and_executes_capability_gated_project_tool) :-
    require_live_tool_credential,
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_live_project_tool(Registry),
        run_live_tool_case(Registry),
        tool_registry_destroy(Registry)).

register_live_project_tool(Registry) :-
    register_project_read_tool(Registry,
                               '.',
                               [max_file_bytes(2048), time_limit(1.0)],
                               Outcome),
    (   Outcome = ok(_)
    ->  true
    ;   Outcome = error(Error),
        throw(error(live_tool_registration_failure(Error),
                    context(live_tool_openrouter_test,
                            'project_read tool registration failed')))
    ).

run_live_tool_case(Registry) :-
    default_openrouter_model(RequestedModel),
    openrouter_provider(RequestedModel, Provider),
    live_tool_planner_prompt(Prompt),
    Request = model_request{
                  messages:[message{role:user, content:Prompt}],
                  options:_{max_tokens:640}
              },
    request_parseable_live_tool_plan(Provider,
                                     Request,
                                     2,
                                     1,
                                     Response,
                                     Plan,
                                     PlanChannel,
                                     Attempt),
    Caps = [tool(project_read)],
    tool_registry_runtime_tools(Registry, Caps, RuntimeTools),
    Runtime = [tools(RuntimeTools),
               budget(_{max_steps:6,
                        max_depth:2,
                        max_parallel:2,
                        max_model_calls:0,
                        max_tool_calls:2,
                        max_context_ops:0,
                        max_output_bytes:8192,
                        time_limit:5.0})],
    plan_run(Plan, Caps, Runtime, _{}, PlanOutcome),
    require_live_tool_execution_success(PlanOutcome, Result),
    validate_live_tool_result(Result),
    log_live_tool_evidence(RequestedModel,
                           Response,
                           PlanChannel,
                           Attempt,
                           Result).

request_parseable_live_tool_plan(Provider, Request, Remaining, Attempt,
                                 Response, Plan, PlanChannel, UsedAttempt) :-
    model_complete(Provider, Request, ProviderOutcome),
    require_live_tool_provider_success(ProviderOutcome, Candidate),
    (   response_tool_plan(Candidate, Plan0, Channel0)
    ->  Response = Candidate,
        Plan = Plan0,
        PlanChannel = Channel0,
        UsedAttempt = Attempt
    ;   log_unparseable_live_tool_attempt(Candidate, Attempt),
        retry_live_tool_plan(Provider,
                             Request,
                             Remaining,
                             Attempt,
                             Response,
                             Plan,
                             PlanChannel,
                             UsedAttempt)
    ).

retry_live_tool_plan(Provider, Request, Remaining, Attempt,
                     Response, Plan, PlanChannel, UsedAttempt) :-
    Remaining > 1,
    !,
    NextRemaining is Remaining-1,
    NextAttempt is Attempt+1,
    request_parseable_live_tool_plan(Provider,
                                     Request,
                                     NextRemaining,
                                     NextAttempt,
                                     Response,
                                     Plan,
                                     PlanChannel,
                                     UsedAttempt).
retry_live_tool_plan(_, _, _, _, _, _, _, _) :-
    throw(error(live_tool_plan_parse_failure,
                context(live_tool_openrouter_test,
                        'real model responses did not contain a valid project-tool typed plan'))).

log_unparseable_live_tool_attempt(Response, Attempt) :-
    format('real_tool_plan_attempt: ~d~n', [Attempt]),
    format('real_tool_plan_attempt_http_status: ~d~n',
           [Response.metadata.http_status]),
    format('real_tool_plan_attempt_selected_model: ~w~n',
           [Response.selected_model]),
    format('real_tool_plan_attempt_parseable: false~n', []).

live_tool_planner_prompt(
"Return ONLY one JSON object. No markdown and no explanation.\n\
Select a typed plan that invokes the trusted project_read tool on the path test/fixtures/tool-readable.txt and then returns the tool status.\n\
Use exactly two operations: tool project_read, then final.\n\
The JSON must have this exact shape and binding name:\n\
{\"steps\":[\
{\"op\":\"tool\",\"name\":\"project_read\",\"args\":{\"path\":\"test/fixtures/tool-readable.txt\"},\"bind\":\"file\"},\
{\"op\":\"final\",\"value\":{\"ref\":\"field\",\"value\":{\"ref\":\"var\",\"name\":\"file\"},\"key\":\"status\"}}]}" ).

require_live_tool_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '', Key \== ""
    ->  true
    ;   throw(error(missing_live_credential('OPENROUTER_API_KEY'),
                    context(live_tool_openrouter_test,
                            'OPENROUTER_API_KEY is not configured for live tool CI')))
    ).

require_live_tool_provider_success(ok(Response), Response) :-
    !.
require_live_tool_provider_success(error(Error), _) :-
    throw(error(live_tool_provider_failure(Error),
                context(live_tool_openrouter_test,
                        'real OpenRouter tool-planner request failed'))).

response_tool_plan(Response, Plan, text) :-
    get_dict(text, Response, Text),
    live_nonempty_string(Text),
    plan_parse(Text, ok(Plan)),
    !.
response_tool_plan(Response, Plan, reasoning) :-
    get_dict(reasoning, Response, Reasoning),
    live_nonempty_string(Reasoning),
    plan_parse(Reasoning, ok(Plan)),
    !.

live_nonempty_string(Value) :-
    string(Value),
    Value \== "".

require_live_tool_execution_success(ok(Result), Result) :-
    !.
require_live_tool_execution_success(error(Error), _) :-
    throw(error(live_tool_execution_failure(Error),
                context(live_tool_openrouter_test,
                        'real model-selected project tool plan failed execution'))).

validate_live_tool_result(Result) :-
    assertion(Result.value == ok),
    get_dict(file, Result.vars, Envelope),
    assertion(Envelope.authorization == allowed),
    assertion(Envelope.status == ok),
    assertion(Envelope.value.truncated == false),
    assertion(sub_string(Envelope.value.content, _, _, _,
                         "PROLOG_RLM_TOOL_OK")),
    Result.transitions = [ToolTransition, FinalTransition],
    assertion(ToolTransition.operation == tool(project_read)),
    assertion(FinalTransition.operation == final).

log_live_tool_evidence(RequestedModel, Response, PlanChannel, Attempt, Result) :-
    get_dict(file, Result.vars, Envelope),
    length(Result.transitions, TransitionCount),
    format('real_tool_provider: openrouter~n', []),
    format('real_tool_requested_model: ~w~n', [RequestedModel]),
    format('real_tool_selected_model: ~w~n', [Response.selected_model]),
    format('real_tool_http_status: ~d~n', [Response.metadata.http_status]),
    format('real_tool_response_received: true~n', []),
    format('real_tool_plan_parsed: true~n', []),
    format('real_tool_plan_output_channel: ~w~n', [PlanChannel]),
    format('real_tool_plan_attempt_used: ~d~n', [Attempt]),
    format('real_tool_invoked: true~n', []),
    format('real_tool_authorization: ~w~n', [Envelope.authorization]),
    format('real_tool_status: ~w~n', [Envelope.status]),
    format('real_tool_file_token_seen: true~n', []),
    format('real_tool_transition_count: ~d~n', [TransitionCount]).

:- end_tests(live_tool_openrouter).
