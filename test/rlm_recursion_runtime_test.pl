:- begin_tests(rlm_recursion_runtime).

:- use_module('../prolog/rlm_recursion_runtime').

:- dynamic route_call/2.

setup_calls :- retractall(route_call(_, _)).

base_request(Subject,
             _{subject:Subject,
               direct_continuation:plunit_rlm_recursion_runtime:direct_handler,
               deterministic_context:plunit_rlm_recursion_runtime:deterministic_handler,
               cheap_submodel:plunit_rlm_recursion_runtime:cheap_handler,
               recursive_rlm:plunit_rlm_recursion_runtime:recursive_handler,
               delegated_subagent:plunit_rlm_recursion_runtime:delegated_handler}).

budgeted(Signals0, Signals) :-
    put_dict(_{remaining_calls:4,
               remaining_tokens:8000,
               current_depth:0},
             Signals0,
             Signals).

test(easy_request_executes_direct_handler_only,
     [setup(setup_calls), cleanup(setup_calls)]) :-
    base_request(easy_lookup, Request),
    budgeted(_{task_complexity:0.1,
               context_chars:500,
               uncertainty:0.05,
               branch_diversity:0.0},
             Signals),
    recursion_execute(Signals, Request, [], ok(Execution)),
    assertion(Execution.selected_policy == direct_continuation),
    assertion(Execution.result == direct(easy_lookup)),
    assertion(Execution.next_depth =:= 0),
    assertion(Execution.actual_cost == unknown),
    assertion(Execution.actual_usage == unknown),
    assertion(Execution.parent_identity == root),
    assertion(atom(Execution.child_identity)),
    assertion(Execution.next_fingerprints == []),
    findall(Route, route_call(Route, _), Routes),
    assertion(Routes == [direct_continuation]).

test(long_context_executes_depth_one_recursive_handler,
     [setup(setup_calls), cleanup(setup_calls)]) :-
    base_request(hierarchical_long_context, Request),
    budgeted(_{task_complexity:0.9,
               context_chars:220000,
               uncertainty:0.8,
               branch_diversity:0.4},
             Signals),
    recursion_execute(Signals, Request, [], ok(Execution)),
    assertion(Execution.selected_policy == recursive_rlm),
    assertion(Execution.result == recursive(hierarchical_long_context)),
    assertion(Execution.next_depth =:= 1),
    assertion(Execution.next_fingerprints == [Execution.fingerprint]),
    findall(Route, route_call(Route, _), Routes),
    assertion(Routes == [recursive_rlm]).

test(recursive_trace_records_measured_usage_and_identities,
     [setup(setup_calls), cleanup(setup_calls)]) :-
    Request = _{subject:measured_recursive,
                parent_identity:parent_1,
                recursive_rlm:plunit_rlm_recursion_runtime:recursive_metadata_handler},
    budgeted(_{task_complexity:0.95,
               context_chars:220000,
               uncertainty:0.9,
               branch_diversity:0.5},
             Signals),
    recursion_execute(Signals, Request, [], ok(Execution)),
    assertion(Execution.selected_policy == recursive_rlm),
    assertion(Execution.parent_identity == parent_1),
    assertion(Execution.child_identity == child_1),
    assertion(Execution.actual_cost =:= 0.031),
    assertion(Execution.actual_usage == usage{tokens:321}),
    Execution.trace = [_, Trace],
    assertion(Trace.reason == long_context_recursive_decomposition),
    assertion(Trace.parent_identity == parent_1),
    assertion(Trace.child_identity == child_1),
    assertion(Trace.depth =:= 1),
    assertion(number(Trace.estimated_cost)),
    assertion(Trace.actual_cost =:= 0.031),
    assertion(Trace.actual_usage == usage{tokens:321}).

test(delegated_trace_records_measured_usage_and_parent,
     [setup(setup_calls), cleanup(setup_calls)]) :-
    Request = _{subject:branching_delegate,
                parent_identity:supervisor_7,
                delegated_subagent:plunit_rlm_recursion_runtime:delegated_metadata_handler},
    budgeted(_{task_complexity:1.0,
               context_chars:100,
               uncertainty:1.0,
               branch_diversity:1.0},
             Signals),
    recursion_execute(Signals, Request, [], ok(Execution)),
    assertion(Execution.selected_policy == delegated_subagent),
    assertion(Execution.parent_identity == supervisor_7),
    assertion(atom(Execution.child_identity)),
    assertion(Execution.actual_cost =:= 0.07),
    assertion(Execution.actual_usage == usage{tokens:88}),
    assertion(Execution.next_depth =:= 0),
    Execution.trace = [_, Trace],
    assertion(Trace.selected_policy == delegated_subagent),
    assertion(Trace.parent_identity == supervisor_7),
    assertion(Trace.recursive == false),
    assertion(Trace.depth =:= 0).

test(duplicate_recursive_subject_is_redirected,
     [setup(setup_calls), cleanup(setup_calls)]) :-
    base_request(repeated_subproblem, Request),
    recursion_execution_context(
        _{task_complexity:0.95,
          context_chars:220000,
          uncertainty:0.85,
          branch_diversity:0.3,
          remaining_calls:4,
          remaining_tokens:8000,
          current_depth:0},
        Request,
        [],
        ok(Context0)),
    Fingerprint = Context0.fingerprint,
    recursion_execute(
        _{task_complexity:0.95,
          context_chars:220000,
          uncertainty:0.85,
          branch_diversity:0.3,
          remaining_calls:4,
          remaining_tokens:8000,
          current_depth:0},
        Request,
        [previous_fingerprints([Fingerprint])],
        ok(Execution)),
    assertion(Execution.selected_policy \== recursive_rlm),
    assertion(Execution.next_fingerprints == [Fingerprint]),
    assertion(\+ route_call(recursive_rlm, _)).

test(no_progress_recursive_subject_is_redirected,
     [setup(setup_calls), cleanup(setup_calls)]) :-
    base_request(stalled_subproblem, Request),
    recursion_execute(
        _{task_complexity:0.95,
          context_chars:220000,
          uncertainty:0.85,
          branch_diversity:0.3,
          progress:0.01,
          remaining_calls:4,
          remaining_tokens:8000,
          current_depth:0},
        Request,
        [min_progress(0.05)],
        ok(Execution)),
    assertion(Execution.selected_policy \== recursive_rlm),
    assertion(\+ route_call(recursive_rlm, _)).

test(missing_direct_handler_redirects_to_available_candidate,
     [setup(setup_calls), cleanup(setup_calls)]) :-
    Request = _{subject:easy_without_direct,
                deterministic_context:plunit_rlm_recursion_runtime:deterministic_handler},
    budgeted(_{task_complexity:0.1,
               context_chars:500,
               uncertainty:0.05,
               branch_diversity:0.0},
             Signals),
    recursion_execute(Signals, Request, [], ok(Execution)),
    assertion(Execution.selected_policy == deterministic_context),
    assertion(Execution.decision.reason == selected_route_unavailable),
    assertion(Execution.result == deterministic(easy_without_direct)).

test(recursion_depth_above_one_requires_opt_in_and_capability,
     [setup(setup_calls), cleanup(setup_calls)]) :-
    base_request(deep_subject, Request),
    Signals = _{task_complexity:0.98,
                context_chars:250000,
                uncertainty:0.9,
                branch_diversity:0.5,
                remaining_calls:4,
                remaining_tokens:8000,
                current_depth:1},
    recursion_execute(Signals,
                      Request,
                      [max_recursion_depth(4)],
                      ok(DefaultExecution)),
    assertion(DefaultExecution.selected_policy \== recursive_rlm),
    retractall(route_call(_, _)),
    recursion_execute(Signals,
                      Request,
                      [max_recursion_depth(4),
                       allow_deep_recursion(true),
                       deep_recursion_capability(true),
                       candidate_selector(
                           plunit_rlm_recursion_runtime:prefer_recursive)],
                      ok(DeepExecution)),
    assertion(DeepExecution.selected_policy == recursive_rlm),
    assertion(DeepExecution.next_depth =:= 2).

test(handler_error_is_preserved,
     [setup(setup_calls), cleanup(setup_calls)]) :-
    Request = _{subject:failure,
                direct_continuation:plunit_rlm_recursion_runtime:error_handler},
    budgeted(_{task_complexity:0.05,
               context_chars:10,
               uncertainty:0.0},
             Signals),
    recursion_execute(Signals, Request, [], error(Error)),
    assertion(Error == route_error(expected_failure)).

test(time_limit_control_exception_propagates,
     [setup(setup_calls), cleanup(setup_calls)]) :-
    Request = _{subject:timeout,
                direct_continuation:plunit_rlm_recursion_runtime:timeout_handler},
    budgeted(_{task_complexity:0.05,
               context_chars:10,
               uncertainty:0.0},
             Signals),
    catch(recursion_execute(Signals, Request, [], _), Exception, true),
    assertion(Exception == time_limit_exceeded).

direct_handler(_, Subject, direct(Subject)) :-
    assertz(route_call(direct_continuation, Subject)).

deterministic_handler(_, Subject, deterministic(Subject)) :-
    assertz(route_call(deterministic_context, Subject)).

cheap_handler(_, Subject, cheap(Subject)) :-
    assertz(route_call(cheap_submodel, Subject)).

recursive_handler(_, Subject, recursive(Subject)) :-
    assertz(route_call(recursive_rlm, Subject)).

recursive_metadata_handler(_, Subject,
                           ok(recursive(Subject),
                              _{actual_cost:0.031,
                                usage:usage{tokens:321},
                                child_identity:child_1})) :-
    assertz(route_call(recursive_rlm, Subject)).

delegated_handler(_, Subject, delegated(Subject)) :-
    assertz(route_call(delegated_subagent, Subject)).

delegated_metadata_handler(_, Subject,
                           ok(delegated(Subject),
                              _{actual_cost:0.07,
                                usage:usage{tokens:88}})) :-
    assertz(route_call(delegated_subagent, Subject)).

prefer_recursive(_, Candidates, Selected) :-
    member(Selected, Candidates),
    Selected.route == recursive_rlm,
    !.

error_handler(_, _, error(route_error(expected_failure))).

timeout_handler(_, _, _) :- throw(time_limit_exceeded).

:- end_tests(rlm_recursion_runtime).
