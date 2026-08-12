:- begin_tests(live_tool_openrouter).

:- use_module(library(http/json)).
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
    live_tool_request(Request),
    request_required_live_tool_call(Provider,
                                    Request,
                                    3,
                                    1,
                                    Response,
                                    Plan,
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
                           Attempt,
                           Result).

live_tool_request(
    model_request{
        messages:[message{
                      role:user,
                      content:"Use the project_read tool exactly once to read test/fixtures/tool-readable.txt. Do not answer from memory."
                  }],
        options:_{max_tokens:256,
                  temperature:0,
                  tool_choice:"required",
                  tools:[_{type:"function",
                           function:_{name:"project_read",
                                      description:"Read one file from the trusted project root.",
                                      parameters:_{type:"object",
                                                   properties:_{path:_{type:"string",
                                                                       description:"Project-relative file path"}},
                                                   required:["path"],
                                                   additionalProperties:false}}}]}
    }).

request_required_live_tool_call(Provider,
                                Request,
                                Remaining,
                                Attempt,
                                Response,
                                Plan,
                                UsedAttempt) :-
    model_complete(Provider, Request, ProviderOutcome),
    require_live_tool_provider_success(ProviderOutcome, Candidate),
    (   response_project_read_plan(Candidate, Plan0)
    ->  Response = Candidate,
        Plan = Plan0,
        UsedAttempt = Attempt
    ;   log_rejected_live_tool_attempt(Candidate, Attempt),
        retry_live_tool_call(Provider,
                             Request,
                             Remaining,
                             Attempt,
                             Response,
                             Plan,
                             UsedAttempt)
    ).

response_project_read_plan(Response,
                           plan([tool(project_read,
                                      object([path-literal(Path)]),
                                      file),
                                 final(field(var(file), status))])) :-
    get_dict(tool_calls, Response, Calls),
    member(Call, Calls),
    is_dict(Call),
    get_dict(function, Call, Function),
    is_dict(Function),
    get_dict(name, Function, Name0),
    normalize_tool_name(Name0, project_read),
    get_dict(arguments, Function, Arguments0),
    tool_arguments_dict(Arguments0, Arguments),
    get_dict(path, Arguments, Path),
    Path == "test/fixtures/tool-readable.txt",
    !.

normalize_tool_name(Name, Atom) :-
    atom(Name),
    !,
    Atom = Name.
normalize_tool_name(Name, Atom) :-
    string(Name),
    atom_string(Atom, Name).

tool_arguments_dict(Arguments, Arguments) :-
    is_dict(Arguments),
    !.
tool_arguments_dict(Arguments0, Arguments) :-
    string(Arguments0),
    !,
    atom_string(Atom, Arguments0),
    catch(atom_json_dict(Atom, Arguments, []), _, fail),
    is_dict(Arguments).
tool_arguments_dict(Arguments0, Arguments) :-
    atom(Arguments0),
    catch(atom_json_dict(Arguments0, Arguments, []), _, fail),
    is_dict(Arguments).

retry_live_tool_call(Provider, Request, Remaining, Attempt,
                     Response, Plan, UsedAttempt) :-
    Remaining > 1,
    !,
    NextRemaining is Remaining-1,
    NextAttempt is Attempt+1,
    request_required_live_tool_call(Provider,
                                    Request,
                                    NextRemaining,
                                    NextAttempt,
                                    Response,
                                    Plan,
                                    UsedAttempt).
retry_live_tool_call(_, _, _, _, _, _, _) :-
    throw(error(live_tool_call_shape_failure,
                context(live_tool_openrouter_test,
                        'real OpenRouter responses did not select project_read with the required fixture path'))).

log_rejected_live_tool_attempt(Response, Attempt) :-
    format('real_tool_call_attempt: ~d~n', [Attempt]),
    format('real_tool_call_attempt_http_status: ~d~n',
           [Response.metadata.http_status]),
    format('real_tool_call_attempt_selected_model: ~w~n',
           [Response.selected_model]),
    format('real_tool_call_attempt_required_shape: false~n', []).

require_live_tool_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '',
        Key \== ""
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
                        'real OpenRouter native tool request failed'))).

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
    assertion(sub_string(Envelope.value.content,
                         _,
                         _,
                         _,
                         "PROLOG_RLM_TOOL_OK")),
    Result.transitions = [ToolTransition, FinalTransition],
    assertion(ToolTransition.operation == tool(project_read)),
    assertion(FinalTransition.operation == final).

log_live_tool_evidence(RequestedModel, Response, Attempt, Result) :-
    get_dict(file, Result.vars, Envelope),
    length(Result.transitions, TransitionCount),
    format('real_tool_provider: openrouter~n', []),
    format('real_tool_requested_model: ~w~n', [RequestedModel]),
    format('real_tool_selected_model: ~w~n', [Response.selected_model]),
    format('real_tool_http_status: ~d~n', [Response.metadata.http_status]),
    format('real_tool_response_received: true~n', []),
    format('real_tool_selection_channel: native_tool_call~n', []),
    format('real_tool_plan_parsed: true~n', []),
    format('real_tool_plan_output_channel: native_tool_call~n', []),
    format('real_tool_plan_attempt_used: ~d~n', [Attempt]),
    format('real_tool_invoked: true~n', []),
    format('real_tool_authorization: ~w~n', [Envelope.authorization]),
    format('real_tool_status: ~w~n', [Envelope.status]),
    format('real_tool_file_token_seen: true~n', []),
    format('real_tool_transition_count: ~d~n', [TransitionCount]).

:- end_tests(live_tool_openrouter).
