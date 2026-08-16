:- initialization(main, main).

:- use_module(library(plunit)).
:- use_module(library(time)).
:- consult(rlm_tool_mcp_async_test).

case(tool_async_submits_canonical_execute_predicate).
case(tool_sync_starts_async_operation).
case(tool_plan_adapter_uses_execute_abi_not_sync_wrapper).
case(tool_wrappers_do_not_duplicate_capability_or_schema_checks).
case(tool_compat_async_never_calls_sync_wrapper).
case(mcp_async_submits_only_execute_predicates).
case(mcp_sync_surfaces_start_async_surfaces).
case(mcp_compat_async_never_calls_sync_wrappers).
case(mcp_lifecycle_async_submits_execute_predicates).
case(mcp_lifecycle_sync_starts_async_operations).
case(sync_tool_executes_handler_once).
case(async_tool_executes_handler_once_and_has_metadata).
case(sync_async_tool_trace_and_outcome_semantics_match).
case(tool_wait_timeout_does_not_restart_and_cancel_cleans_up).
case(mcp_definition_is_queryable_and_inert).
case(mcp_definition_does_not_auto_install_or_run).
case(mcp_install_none_is_explicit_and_canonical).
case(mcp_run_connect_stop_are_explicit_and_borrowed).
case(mcp_restart_uses_execute_abis_without_nested_future).
case(async_mcp_command_returns_updated_client_and_metadata).
case(sync_async_mcp_command_outcome_and_trace_match).
case(async_mcp_server_handle_matches_sync).
case(mcp_cancellation_propagates_through_command).
case(imported_mcp_tool_flows_through_tool_contract_once).
case(imported_mcp_tool_schema_rejects_before_remote_call).
case(imported_mcp_tool_capability_denial_precedes_remote_call).

main(_) :-
    (   forall(case(Name), run_case(Name))
    ->  halt(0)
    ;   halt(1)
    ).

run_case(Name) :-
    format(user_error, 'canonical_async_case=~w~n', [Name]),
    catch(call_with_time_limit(8,
                               run_tests(rlm_tool_mcp_async:Name)),
          Exception,
          case_exception(Name, Exception)),
    !.
run_case(Name) :-
    format(user_error, 'canonical_async_case_failed=~w~n', [Name]),
    fail.

case_exception(Name, Exception) :-
    format(user_error,
           'canonical_async_case_exception=~w exception=~q~n',
           [Name, Exception]),
    fail.
