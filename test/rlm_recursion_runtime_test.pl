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
                       deep_recursion_capability(true)],
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
     [setup(setup_calls), cleanup(setup_calls), throws(time_limit_exceeded)]) :-
    Request = _{subject:timeout,
                direct_continuation:plunit_rlm_recursion_runtime:timeout_handler},
    budgeted(_{task_complexity:0.05,
               context_chars:10,
               uncertainty:0.0},
             Signals),
    recursion_execute(Signals, Request, [], _).

direct_handler(_, Subject, direct(Subject)) :-
    assertz(route_call(direct_continuation, Subject)).

deterministic_handler(_, Subject, deterministic(Subject)) :-
    assertz(route_call(deterministic_context, Subject)).

cheap_handler(_, Subject, cheap(Subject)) :-
    assertz(route_call(cheap_submodel, Subject)).

recursive_handler(_, Subject, recursive(Subject)) :-
    assertz(route_call(recursive_rlm, Subject)).

delegated_handler(_, Subject, delegated(Subject)) :-
    assertz(route_call(delegated_subagent, Subject)).

error_handler(_, _, error(route_error(expected_failure))).

timeout_handler(_, _, _) :- throw(time_limit_exceeded).

:- end_tests(rlm_recursion_runtime).
