:- begin_tests(rlm_deep_experiment).

:- use_module('../prolog/rlm').
:- use_module('../prolog/rlm_deep_experiment').

:- dynamic planner_call_count/1.

reset_planner_calls :-
    retractall(planner_call_count(_)),
    assertz(planner_call_count(0)).

bump_planner_calls :-
    retract(planner_call_count(N0)),
    N is N0+1,
    assertz(planner_call_count(N)).

planner_calls(N) :- planner_call_count(N).

planner_output(Plan,
               planner_output{plan:Plan,
                              usage:_{prompt_tokens:1,
                                      completion_tokens:1,
                                      total_tokens:2,
                                      cost:0.0}}).

depth_two_planner(_, ok(Output)) :-
    bump_planner_calls,
    Grandchild = plan([final(literal("grandchild-ok"))]),
    Child = plan([rlm(Grandchild, grandchild),
                  final(var(grandchild))]),
    Plan = plan([rlm(Child, child),
                 final(var(child))]),
    planner_output(Plan, Output).

grandchild_tool_planner(_, ok(Output)) :-
    bump_planner_calls,
    Grandchild = plan([tool(secret_tool,
                            literal(_{secret:true}),
                            secret),
                       final(var(secret))]),
    Child = plan([rlm(Grandchild, grandchild),
                  final(var(grandchild))]),
    Plan = plan([rlm(Child, child),
                 final(var(child))]),
    planner_output(Plan, Output).

grandchild_slow_tool_planner(_, ok(Output)) :-
    bump_planner_calls,
    Grandchild = plan([tool(slow_tool,
                            literal(start),
                            slow_result),
                       final(var(slow_result))]),
    Child = plan([rlm(Grandchild, grandchild),
                  final(var(grandchild))]),
    Plan = plan([rlm(Child, child),
                 final(var(child))]),
    planner_output(Plan, Output).

slow_tool(Queue, _, completed) :-
    thread_send_message(Queue, started),
    sleep(5).

expect_error(error(Error), Error) :- !.
expect_error(Outcome, _) :-
    throw(error(expected_error(Outcome),
                context(rlm_deep_experiment_test, expected_error))).

expect_ok(ok(Value), Value) :- !.
expect_ok(Outcome, _) :-
    throw(error(expected_ok(Outcome),
                context(rlm_deep_experiment_test, expected_ok))).

depth_two_options(Extra, Options) :-
    Base = [ planner_handler(plunit_rlm_deep_experiment:depth_two_planner),
             capabilities([rlm]),
             child_capabilities([rlm]),
             budget(_{max_recursion_depth:2,
                      max_iterations:8,
                      time_limit:5.0})
           ],
    append(Extra, Base, Options).

test(public_completion_depth_two_requires_explicit_experimental_flag,
     [setup(reset_planner_calls)]) :-
    depth_two_options([], Options),
    rlm:rlm_completion("depth two",
                       text("ctx"),
                       Options,
                       Outcome),
    expect_error(Outcome, Error),
    assertion(Error.phase == validate),
    assertion(Error.kind == experimental_deep_recursion_required),
    assertion(Error.requested_depth =:= 2),
    planner_calls(Calls),
    assertion(Calls =:= 0).

test(public_completion_depth_two_runs_only_with_explicit_flag,
     [setup(reset_planner_calls)]) :-
    depth_two_options([experimental_deep_recursion(true)], Options),
    rlm:rlm_completion("depth two",
                       text("ctx"),
                       Options,
                       Outcome),
    expect_ok(Outcome, Result),
    assertion(Result.value == "grandchild-ok"),
    assertion(Result.recursion.max_depth =:= 2),
    assertion(Result.recursion.recursive_calls =:= 2),
    planner_calls(Calls),
    assertion(Calls =:= 1).

test(public_rlm_query_depth_two_requires_explicit_flag) :-
    rlm:rlm_query("child",
                  text("ctx"),
                  [ depth(2),
                    budget(_{max_recursion_depth:2})
                  ],
                  Outcome),
    expect_error(Outcome, Error),
    assertion(Error.kind == experimental_deep_recursion_required),
    assertion(Error.requested_depth =:= 2).

test(grandchild_cannot_exceed_narrowed_child_capabilities,
     [setup(reset_planner_calls)]) :-
    Options = [ experimental_deep_recursion(true),
                planner_handler(
                    plunit_rlm_deep_experiment:grandchild_tool_planner),
                capabilities([rlm, tool(secret_tool)]),
                child_capabilities([rlm]),
                budget(_{max_recursion_depth:2,
                         max_iterations:8,
                         time_limit:5.0})
              ],
    rlm:rlm_completion("forbidden grandchild tool",
                       text("ctx"),
                       Options,
                       Outcome),
    expect_error(Outcome, Error),
    assertion(Error.phase == validate),
    assertion(Error.kind == recursive_plan_rejected),
    assertion(Error.detail == child_capability_denied(tool(secret_tool))).

test(grandchild_work_is_cancelled_by_parent_completion_token,
     [setup(reset_planner_calls)]) :-
    rlm:rlm_cancellation_token(Token),
    message_queue_create(Queue),
    setup_call_cleanup(
        true,
        ( thread_create(run_slow_depth_two(Token, Queue), Thread, []),
          thread_get_message(Queue, started, [timeout(2)]),
          rlm:rlm_cancel(Token),
          thread_get_message(Queue, outcome(Outcome), [timeout(2)]),
          thread_join(Thread, _),
          expect_error(Outcome, Error),
          assertion(Error.kind == cancelled)
        ),
        message_queue_destroy(Queue)).

run_slow_depth_two(Token, Queue) :-
    Options = [ experimental_deep_recursion(true),
                cancel_token(Token),
                planner_handler(
                    plunit_rlm_deep_experiment:grandchild_slow_tool_planner),
                capabilities([rlm, tool(slow_tool)]),
                child_capabilities([rlm, tool(slow_tool)]),
                tools([tool(slow_tool,
                            plunit_rlm_deep_experiment:slow_tool(Queue))]),
                budget(_{max_recursion_depth:2,
                         max_iterations:8,
                         max_tool_calls:1,
                         time_limit:5.0})
              ],
    rlm:rlm_completion("cancel grandchild",
                       text("ctx"),
                       Options,
                       Outcome),
    thread_send_message(Queue, outcome(Outcome)).

test(experiment_harness_refuses_implicit_enablement) :-
    deep_experiment_run([], Outcome),
    expect_error(Outcome, Error),
    assertion(Error.kind == invalid_experiment),
    assertion(Error.detail == experimental_flag_required).

test(experiment_harness_compares_depth_and_alternative_harnesses) :-
    deep_experiment_run([experimental_deep_recursion(true)], Outcome),
    expect_ok(Outcome, Result),
    assertion(Result.status == pass),
    assertion(Result.experimental == true),
    assertion(Result.report.status == pass),
    assertion(Result.report.case_count =:= 15),
    assertion(Result.report.maxima.recursion_depth =:= 2),
    assertion(Result.classification_summary.helps > 0),
    assertion(Result.classification_summary.hurts > 0),
    assertion(Result.classification_summary.neutral > 0),
    assertion(Result.promotion.status == hold),
    assertion(member(insufficient_live_trials(0, 20),
                     Result.promotion.reasons)),
    member(AgentCase, Result.report.cases),
    AgentCase.name == delegated_subagent,
    assertion(AgentCase.details.capability_narrowing == true),
    assertion(AgentCase.details.cancellation_propagated == true),
    member(ArtifactCase, Result.report.cases),
    ArtifactCase.name == fresh_root_artifact,
    assertion(ArtifactCase.details.transcript_inherited == false),
    member(BudgetCase, Result.report.cases),
    BudgetCase.name == global_recursive_budget,
    assertion(BudgetCase.details.shared_tree_budget == true).

test(promotion_rule_cannot_promote_without_live_evidence) :-
    Evidence = promotion_evidence{
                   live_trials:0,
                   independent_fixtures:4,
                   quality_delta:0.20,
                   cost_ratio:1.10,
                   latency_ratio:1.20,
                   budget_violations:0,
                   capability_violations:0,
                   cancellation_failures:0
               },
    deep_experiment_promotion(Evidence, Decision),
    assertion(Decision.status == hold),
    assertion(member(insufficient_live_trials(0, 20), Decision.reasons)).

test(promotion_rule_accepts_only_bounded_positive_live_evidence) :-
    Evidence = promotion_evidence{
                   live_trials:24,
                   independent_fixtures:4,
                   quality_delta:0.08,
                   cost_ratio:1.30,
                   latency_ratio:1.60,
                   budget_violations:0,
                   capability_violations:0,
                   cancellation_failures:0
               },
    deep_experiment_promotion(Evidence, Decision),
    assertion(Decision.status == promote),
    assertion(Decision.reasons == []).

:- initialization(reset_planner_calls).

:- end_tests(rlm_deep_experiment).
