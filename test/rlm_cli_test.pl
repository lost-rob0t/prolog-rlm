:- begin_tests(rlm_cli).

:- use_module('../prolog/rlm_cli').
:- use_module('../prolog/rlm_trace').

session_passes(Args, Session) :-
    cli_run(Args, ok(Session)),
    assertion(Session.status == pass).

test(no_arguments_runs_credential_free_demo) :-
    session_passes([], Session),
    assertion(Session.command == demo(all)),
    assertion(Session.payload.status == pass),
    assertion(length(Session.payload.cases, 6)).

test(demo_subcommand_selects_family) :-
    session_passes([demo,graph], Session),
    assertion(Session.command == demo(graph)),
    assertion(Session.payload.name == graph),
    assertion(Session.payload.value.completed_status == completed).

test(agent_graph_mcp_shortcuts_route_to_demos) :-
    session_passes([agent], Agent),
    session_passes([graph], Graph),
    session_passes([mcp], Mcp),
    assertion(Agent.payload.name == agent),
    assertion(Graph.payload.name == graph),
    assertion(Mcp.payload.name == mcp).

test(default_openrouter_provider_is_constructed_without_resolving_secret) :-
    rlm_cli:default_cli_options(Default),
    rlm_cli:provider_from_options(Default,
                                  Name,
                                  Provider,
                                  Model),
    assertion(Name == openrouter),
    assertion(nonvar(Model)),
    Provider = provider(openrouter, Config),
    assertion(memberchk(credential(env('OPENROUTER_API_KEY')), Config)).

test(local_openai_compatible_provider_supports_no_credential) :-
    rlm_cli:default_cli_options(Default),
    Options = Default.put(_{endpoint:"http://127.0.0.1:8000/v1/chat/completions",
                            model:'local-model',
                            no_credential:true}),
    rlm_cli:provider_from_options(Options,
                                  Name,
                                  Provider,
                                  Model),
    assertion(Name == openai_compatible),
    assertion(Model == 'local-model'),
    Provider = provider(openai_compatible, Config),
    assertion(memberchk(credential(none), Config)).

test(custom_endpoint_requires_model) :-
    rlm_cli:default_cli_options(Default),
    Options = Default.put(endpoint,
                          "http://127.0.0.1:8000/v1/chat/completions"),
    catch(rlm_cli:provider_from_options(Options, _, _, _),
          Exception,
          true),
    assertion(Exception ==
              cli_fault(model_required_for_endpoint(
                            "http://127.0.0.1:8000/v1/chat/completions"))).

test(default_rlm_plan_is_depth_one_and_uses_context_variable) :-
    rlm_cli:simple_recursive_plan(openrouter,
                                  128,
                                  "Question: test",
                                  Plan),
    Plan = plan([
               context(input(context), slice(0, ContextLength), snippet),
               rlm(plan([
                       model(openrouter,
                             var(snippet),
                             ModelOptions,
                             child_response),
                       final(var(child_response))
                   ]),
                   child),
               final(var(child))
           ]),
    assertion(ContextLength =:= 14),
    assertion(ModelOptions.max_tokens =:= 128).

test(fixed_cli_planner_returns_exact_plan_without_token_usage) :-
    rlm_cli:simple_recursive_plan(openrouter,
                                  64,
                                  "Question: test",
                                  Plan),
    rlm_cli:fixed_cli_planner(Plan, _{}, Output),
    assertion(Output.plan == Plan),
    assertion(Output.usage.prompt_tokens =:= 0),
    assertion(Output.usage.completion_tokens =:= 0),
    assertion(Output.usage.total_tokens =:= 0),
    assertion(Output.usage.cost =:= 0.0).

test(demo_trace_export_and_trace_view_are_roundtrippable) :-
    tmp_file_stream(text, Path, Stream),
    close(Stream),
    setup_call_cleanup(
        true,
        ( cli_run([demo,recursion,'--trace',Path,'--trace-format',json],
                  ok(Session)),
          assertion(Session.status == pass),
          assertion(Session.trace_export = ok(_)),
          cli_run(['trace-view',Path,'--trace-format',json],
                  ok(ViewSession)),
          assertion(ViewSession.status == pass),
          assertion(sub_string(ViewSession.summary,
                               _, _, _,
                               "selected_policy"))
        ),
        delete_file(Path)).

test(json_and_view_flags_are_preserved) :-
    cli_run([demo,mcp,'--json','--view'], ok(Session)),
    assertion(Session.output.json == true),
    assertion(Session.output.view == true).

test(unknown_option_is_structured_error) :-
    cli_run([demo,'--wat'], error(Error)),
    assertion(Error.kind == invalid_cli_request),
    assertion(Error.detail == unknown_option('--wat')).

test(help_is_a_valid_session) :-
    cli_run([help], ok(Session)),
    assertion(Session.status == pass),
    assertion(Session.command == help),
    assertion(sub_string(Session.summary, _, _, _, "Usage:")),
    assertion(is_dict(Session.output)).

test(global_long_help_is_a_valid_session) :-
    cli_run(['--help'], ok(Session)),
    assertion(Session.status == pass),
    assertion(Session.command == help),
    assertion(sub_string(Session.summary, _, _, _, "Usage:")),
    assertion(is_dict(Session.output)).

test(rlm_long_help_is_a_valid_non_provider_session) :-
    cli_run([rlm,'--help'], ok(Session)),
    assertion(Session.status == pass),
    assertion(Session.command == help(rlm)),
    assertion(sub_string(Session.summary, _, _, _, "prolog-rlm rlm QUERY")),
    assertion(is_dict(Session.output)).

test(long_help_execute_paths_exit_zero) :-
    with_output_to(string(_GlobalOutput),
                   cli_execute(['--help'], GlobalExit)),
    with_output_to(string(_RlmOutput),
                   cli_execute([rlm,'--help'], RlmExit)),
    assertion(GlobalExit =:= 0),
    assertion(RlmExit =:= 0).

test(unknown_command_with_help_remains_unknown) :-
    cli_run([wat,'--help'], error(Error)),
    assertion(Error.kind == invalid_cli_request),
    assertion(Error.detail == unknown_command(wat)).

test(reasoning_effort_options_parse_and_propagate) :-
    rlm_cli:parse_cli_options(['--reasoning-effort',max,
                               '--planner-reasoning-effort',low],
                              Options,
                              []),
    assertion(Options.reasoning_effort == max),
    assertion(Options.planner_reasoning_effort == low),
    rlm_cli:runtime_reasoning_options(Options, RuntimeOptions),
    assertion(memberchk(reasoning_effort(max), RuntimeOptions)),
    assertion(memberchk(planner_reasoning_effort(low), RuntimeOptions)).

test(default_reasoning_options_do_not_add_runtime_controls) :-
    rlm_cli:default_cli_options(Options),
    rlm_cli:runtime_reasoning_options(Options, RuntimeOptions),
    assertion(RuntimeOptions == []).

test(invalid_cli_reasoning_effort_is_rejected) :-
    cli_run([demo,'--reasoning-effort',turbo], error(Error)),
    assertion(Error.kind == invalid_cli_request),
    assertion(Error.detail == invalid_option(reasoning_effort, turbo)).

test(help_documents_reasoning_controls) :-
    cli_usage(Usage),
    assertion(sub_string(Usage, _, _, _, "--reasoning-effort")),
    assertion(sub_string(Usage, _, _, _, "--planner-reasoning-effort")).

:- end_tests(rlm_cli).
