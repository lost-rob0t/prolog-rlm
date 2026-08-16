:- initialization(focused_main, main).

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

focused_main :-
    (   run_tool_mcp_async_cases
    ->  halt(0)
    ;   halt(1)
    ).

run_tool_mcp_async_cases :-
    forall(case(Name), run_case(Name)).

run_case(Name) :-
    format(user_error, 'canonical_async_case=~w~n', [Name]),
    diagnostic_before_case(Name),
    catch(call_with_time_limit(8,
                               run_tests(rlm_tool_mcp_async:Name)),
          Exception,
          case_exception(Name, Exception)),
    !.
run_case(Name) :-
    format(user_error, 'canonical_async_case_failed=~w~n', [Name]),
    fail.

diagnostic_before_case(sync_tool_executes_handler_once) :-
    !,
    setup_call_cleanup(
        rlm_tool:tool_registry_create(Registry),
        ( plunit_rlm_tool_mcp_async:counting_schema(Schema),
          rlm_tool:tool_register(
              Registry,
              Schema,
              plunit_rlm_tool_mcp_async:counted_tool,
              Register),
          format(user_error, 'authority_probe_register=~q~n', [Register]),
          rlm_tool:tool_invoke(
              Registry,
              [tool(async_counting)],
              async_counting,
              _{value:7},
              [],
              Outcome,
              Trace),
          format(user_error,
                 'authority_probe_outcome=~q trace=~q~n',
                 [Outcome, Trace])
        ),
        rlm_tool:tool_registry_destroy(Registry)).
diagnostic_before_case(mcp_run_connect_stop_are_explicit_and_borrowed) :-
    !,
    (   catch(diagnostic_mcp_borrowed_sequence,
              Exception,
              ( format(user_error,
                       'mcp_borrowed_diagnostic_exception=~q~n',
                       [Exception]),
                fail ))
    ->  true
    ;   format(user_error, 'mcp_borrowed_diagnostic_failed~n', [])
    ).
diagnostic_before_case(_).

diagnostic_mcp_borrowed_sequence :-
    plunit_rlm_tool_mcp_async:reset_mcp_fixture,
    diagnostic_mcp_step(
        run,
        rlm_mcp_server:rlm_run_mcp_server(async_fixture, ok(Handle0))),
    diagnostic_mcp_step(
        client_info,
        plunit_rlm_tool_mcp_async:client_info(Info)),
    diagnostic_mcp_step(
        client_caps,
        plunit_rlm_tool_mcp_async:client_caps(Caps)),
    diagnostic_mcp_step(
        connect,
        rlm_mcp_server:rlm_connect_mcp_server(
            Handle0, Info, Caps, [], ok(Client0))),
    diagnostic_mcp_step(
        command,
        rlm_mcp:mcp_client_command(Client0, list_tools, Client1, ok(_Page))),
    diagnostic_mcp_step(
        close,
        rlm_mcp:mcp_client_close(Client1, ok(closed))),
    diagnostic_mcp_step(
        stop,
        rlm_mcp_server:rlm_stop_mcp_server(Handle0, ok(_Handle1))).

diagnostic_mcp_step(Label, Goal) :-
    format(user_error, 'mcp_borrowed_step_start=~w~n', [Label]),
    catch(call_with_time_limit(2, Goal),
          Exception,
          ( format(user_error,
                   'mcp_borrowed_step_exception=~w exception=~q~n',
                   [Label, Exception]),
            fail )),
    format(user_error, 'mcp_borrowed_step_done=~w~n', [Label]).

case_exception(Name, Exception) :-
    format(user_error,
           'canonical_async_case_exception=~w exception=~q~n',
           [Name, Exception]),
    fail.