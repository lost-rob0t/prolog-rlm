:- initialization(main, main).

:- use_module(library(plunit)).
:- use_module(library(apply), [maplist/2]).
:- consult(bootstrap_test).
:- consult(load_error_status_test).
:- consult(rlm_chain_test).
:- consult(rlm_chain_runtime_test).
:- consult(rlm_chain_message_metadata_test).
:- consult(rlm_chain_control_test).
:- consult(rlm_stream_canonical_test).
:- consult(rlm_mcp_model_test).
:- consult(rlm_mcp_2025_test).
:- consult(rlm_mcp_2026_test).
:- consult(rlm_mcp_2026_matrix_test).
:- consult(rlm_mcp_runtime_test).
:- consult(rlm_mcp_dual_test).
:- consult(rlm_mcp_boundary_test).
:- consult(rlm_mcp_declaration_security_test).
:- consult(rlm_context_test).
:- consult(rlm_context_adapter_test).
:- consult(rlm_context_budget_test).
:- consult(rlm_conversation_test).
:- consult(rlm_conversation_warm_test).
:- consult(rlm_conversation_runtime_test).
:- consult(rlm_conversation_cold_test).
:- consult(rlm_plan_test).
:- consult(rlm_tool_test).
:- consult(rlm_tool_effect_test).
:- consult(rlm_tool_loader_test).
:- consult(rlm_tool_loader_security_test).
:- consult(rlm_prompt_compiler_test).
:- consult(rlm_prompt_command_test).
:- consult(rlm_authority_test).
:- consult(rlm_authority_hardening_test).
:- consult(rlm_authority_lifecycle_test).
:- consult(rlm_effect_test).
:- consult(rlm_effect_authority_test).
:- consult(rlm_effect_executor_test).
:- consult(rlm_effect_restart_test).
:- consult(rlm_effect_hardening_test).
:- consult(rlm_effect_adversarial_test).
:- consult(rlm_effect_migration_test).
:- consult(rlm_effect_migration_restart_test).
:- consult(run_tool_mcp_async_tests).
:- consult(rlm_tool_mcp_scheduler_test).
:- consult(rlm_completion_test).
:- consult(rlm_completion_hardening_test).
:- consult(rlm_nested_usage_test).
:- consult(rlm_nested_trajectory_test).
:- consult(rlm_outcome_test).
:- consult(rlm_artifact_test).
:- consult(rlm_agent_test).
:- consult(rlm_subagent_test).
:- consult(rlm_evolution_test).
:- consult(rlm_agent_authority_test).
:- consult(rlm_graph_test).
:- consult(rlm_graph_authority_test).
:- consult(rlm_agent_graph_async_test).
:- consult(rlm_recursion_policy_test).
:- consult(rlm_recursion_runtime_test).
:- consult(rlm_benchmark_test).
:- consult(rlm_conformance_test).
:- consult(rlm_deep_experiment_test).
:- consult(rlm_trace_test).
:- consult(rlm_demo_test).
:- consult(rlm_cli_test).
:- consult(rlm_async_test).
:- consult(rlm_async_canonical_test).
:- consult(rlm_spec_verify_test).
:- consult(rlm_spec_lang_test).
:- consult(rlm_spec_workflow_test).
:- consult(rlm_project_source_test).
:- consult(prolog_agent_ui_v1_test).
:- consult(prolog_agent_ui_fixture_command_codec_test).

main(_) :-
    (   run_aggregate_tests
    ->  halt(0)
    ;   halt(1)
    ).

% Keep the aggregate manifest explicit so omitted or empty registered suites
% cannot silently turn a partial run into a successful gate.
aggregate_test_suites([
    bootstrap,
    load_error_status,
    rlm_chain,
    rlm_chain_runtime,
    rlm_chain_message_metadata,
    rlm_chain_control,
    rlm_stream_canonical,
    rlm_mcp_model,
    rlm_mcp_2025,
    rlm_mcp_2026,
    rlm_mcp_2026_matrix,
    rlm_mcp_runtime,
    rlm_mcp_dual,
    rlm_mcp_boundary,
    rlm_mcp_declaration_security,
    rlm_context,
    rlm_context_adapter,
    rlm_context_budget,
    rlm_conversation,
    rlm_conversation_warm,
    rlm_conversation_runtime,
    rlm_conversation_cold,
    rlm_plan,
    rlm_tool,
    rlm_tool_effect,
    rlm_tool_loader,
    rlm_tool_loader_security,
    rlm_prompt_compiler,
    rlm_prompt_command,
    rlm_authority,
    rlm_authority_hardening,
    rlm_authority_lifecycle,
    rlm_effect,
    rlm_effect_authority,
    rlm_effect_executor,
    rlm_effect_restart,
    rlm_effect_hardening,
    rlm_effect_adversarial,
    rlm_effect_migration,
    rlm_effect_migration_restart,
    rlm_tool_mcp_async,
    rlm_tool_mcp_scheduler,
    rlm_completion,
    rlm_completion_hardening,
    rlm_nested_usage,
    rlm_nested_trajectory,
    rlm_outcome,
    rlm_artifact,
    rlm_agent,
    rlm_subagent,
    rlm_evolution,
    rlm_agent_authority,
    rlm_graph,
    rlm_graph_authority,
    rlm_agent_graph_async,
    rlm_recursion_policy,
    rlm_recursion_runtime,
    rlm_benchmark,
    rlm_conformance,
    rlm_deep_experiment,
    rlm_trace,
    rlm_demo,
    rlm_cli,
    rlm_async,
    rlm_async_canonical,
    rlm_spec_verify,
    rlm_spec_lang,
    rlm_spec_workflow,
    rlm_project_source,
    prolog_agent_ui_v1,
    prolog_agent_ui_fixture_command_codec
]).

run_aggregate_tests :-
    aggregate_test_suites(Expected),
    run_aggregate_tests(Expected).

run_aggregate_tests(Expected) :-
    registered_test_suites(Registered),
    Expected \= [],
    same_test_suites(Expected, Registered),
    aggregate_test_counts(Expected, SuiteCounts, Discovered),
    maplist(positive_count, SuiteCounts),
    length(Expected, SuiteCount),
    format('aggregate_plunit_discovered suites=~d tests=~d~n',
           [SuiteCount, Discovered]),
    run_tests(Expected, [summary(Summary)]),
    summary_counts(Summary, Executed, Passed, Failed, Timeout, Blocked),
    format('aggregate_plunit_summary suites=~d discovered=~d executed=~d passed=~d failed=~d timeout=~d blocked=~d~n',
           [SuiteCount, Discovered, Executed, Passed, Failed, Timeout, Blocked]),
    Executed =:= Discovered,
    Passed =:= Discovered,
    Failed =:= 0,
    Timeout =:= 0,
    Blocked =:= 0,
    format('aggregate_plunit_complete suites=~d tests=~d~n',
           [SuiteCount, Discovered]).

registered_test_suites(Suites) :-
    findall(Unit, plunit:current_test_unit(Unit, _), Units),
    sort(Units, Suites).

same_test_suites(Expected, Registered) :-
    sort(Expected, Normalized),
    length(Expected, ExpectedCount),
    length(Normalized, ExpectedCount),
    Normalized == Registered.

aggregate_test_counts([], [], 0).
aggregate_test_counts([Suite|Suites], [Count|Counts], Total) :-
    findall(Test,
            plunit:current_test(Suite, Test, _, _, _),
            Tests),
    length(Tests, Count),
    aggregate_test_counts(Suites, Counts, Rest),
    Total is Count + Rest.

positive_count(Count) :-
    Count > 0.

summary_counts(Summary, Executed, Passed, Failed, Timeout, Blocked) :-
    get_dict(total, Summary, Executed),
    get_dict(passed, Summary, Passed),
    get_dict(failed, Summary, Failed),
    get_dict(timeout, Summary, Timeout),
    get_dict(blocked, Summary, Blocked).
