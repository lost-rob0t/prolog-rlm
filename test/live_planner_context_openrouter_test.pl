:- begin_tests(live_planner_context_openrouter).

:- use_module('../prolog/rlm_completion').
:- use_module('../prolog/rlm_tool').

test(real_planner_uses_opaque_context_and_registered_tool_without_fixed_plan) :-
    require_live_planner_context_credential,
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_live_planner_context_tool(Registry),
        run_live_planner_context_case(Registry),
        tool_registry_destroy(Registry)).

register_live_planner_context_tool(Registry) :-
    register_project_read_tool(Registry,
                               '.',
                               [max_file_bytes(32768), time_limit(1.0)],
                               Outcome),
    (   Outcome = ok(_)
    ->  true
    ;   Outcome = error(Error),
        throw(error(live_planner_context_tool_registration_failure(Error),
                    context(live_planner_context_openrouter_test,
                            'project_read registration failed')))
    ).

run_live_planner_context_case(Registry) :-
    Query = "Perform a repository self-audit before returning a final result. Retrieve the opaque context input, then use the active project_read tool to inspect all three authoritative records: README.md, docs/completion-runtime.md, and docs/tools.md. Do not guess their contents and do not omit or substitute any record.",
    Context = text("RLM_PLANNER_CONTEXT_OK: inspect the repository README and the completion/tool runtime documentation before finalizing."),
    Options = [ capabilities([context(slice), tool(project_read)]),
                child_capabilities([]),
                tool_registry(Registry),
                planner_attempts(3),
                planner_reasoning_effort(low),
                planner_max_tokens(4096),
                context_options([max_bytes(4096), time_limit(1.0)]),
                budget(_{max_iterations:12,
                         max_recursion_depth:0,
                         max_concurrent_subcalls:1,
                         max_model_calls:3,
                         max_tool_calls:3,
                         max_context_ops:1,
                         max_total_tokens:20000,
                         max_cost_usd:0.25,
                         max_output_bytes:131072,
                         time_limit:150.0})
              ],
    assertion(\+ memberchk(planner_instruction(_), Options)),
    rlm_completion(Query, Context, Options, Outcome),
    require_live_planner_context_success(Outcome, Result),
    validate_live_planner_context_result(Result),
    log_live_planner_context_evidence(Result).

require_live_planner_context_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '',
        Key \== ""
    ->  true
    ;   throw(error(missing_live_credential('OPENROUTER_API_KEY'),
                    context(live_planner_context_openrouter_test,
                            'OPENROUTER_API_KEY is not configured')))
    ).

require_live_planner_context_success(ok(Result), Result) :-
    !.
require_live_planner_context_success(error(Error), _) :-
    throw(error(live_planner_context_failure(Error),
                context(live_planner_context_openrouter_test,
                        'real planner did not execute the agentic context/tool task'))).

validate_live_planner_context_result(Result) :-
    member(plan_transition{operation:context(slice),
                           status:ok,
                           bind:ContextBind,
                           sequence:_},
           Result.transitions),
    get_dict(ContextBind, Result.vars, ContextValue),
    assertion(sub_string(ContextValue, _, _, _,
                         "RLM_PLANNER_CONTEXT_OK")),
    findall(ToolBind,
            member(plan_transition{operation:tool(project_read),
                                   status:ok,
                                   bind:ToolBind,
                                   sequence:_},
                   Result.transitions),
            ToolBinds),
    assertion(length(ToolBinds, 3)),
    maplist(tool_binding_envelope(Result.vars), ToolBinds, ToolEnvelopes),
    maplist(tool_envelope_path, ToolEnvelopes, Paths0),
    sort(Paths0, Paths),
    assertion(Paths == ["README.md",
                        "docs/completion-runtime.md",
                        "docs/tools.md"]),
    member(ReadmeEnvelope, ToolEnvelopes),
    ReadmeEnvelope.value.path == "README.md",
    assertion(sub_string(ReadmeEnvelope.value.content, _, _, _,
                         "Recursive Language Models")),
    member(RuntimeEnvelope, ToolEnvelopes),
    RuntimeEnvelope.value.path == "docs/completion-runtime.md",
    assertion(sub_string(RuntimeEnvelope.value.content, _, _, _,
                         "The temporary compiler catalog is always destroyed during cleanup")),
    member(ToolsEnvelope, ToolEnvelopes),
    ToolsEnvelope.value.path == "docs/tools.md",
    assertion(sub_string(ToolsEnvelope.value.content, _, _, _,
                         "trusted host boundary between model-selected tool names")),
    assertion(member(plan_transition{operation:final,
                                     status:ok,
                                     bind:none,
                                     sequence:_},
                     Result.transitions)).

tool_binding_envelope(Vars, Bind, Envelope) :-
    get_dict(Bind, Vars, Envelope),
    assertion(Envelope.authorization == allowed),
    assertion(Envelope.status == ok),
    assertion(Envelope.value.truncated == false).

tool_envelope_path(Envelope, Path) :-
    Path = Envelope.value.path.

log_live_planner_context_evidence(Result) :-
    length(Result.transitions, TransitionCount),
    Root = Result.trajectory.root_event,
    format('planner_context_provider: ~w~n', [Root.provider]),
    format('planner_context_selected_model: ~w~n', [Root.selected_model]),
    format('planner_context_http_status: ~d~n', [Root.http_status]),
    format('planner_context_fixed_plan_injected: false~n', []),
    format('planner_context_context_executed: true~n', []),
    format('planner_context_project_records_read: 3~n', []),
    format('planner_context_runtime_sentinels_checked: true~n', []),
    format('planner_context_final_executed: true~n', []),
    format('planner_context_transition_count: ~d~n', [TransitionCount]),
    format('planner_context_model_calls: ~d~n', [Result.usage.model_calls]).

:- end_tests(live_planner_context_openrouter).
