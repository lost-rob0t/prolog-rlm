:- begin_tests(rlm_outcome).

:- use_module(library(clpfd)).
:- use_module('../prolog/rlm_outcome').
:- use_module('support/outcome_test_support').

plan_runtime(Tools, Budget, Options) :-
    Options = [ tools(Tools),
                budget(Budget)
              ].

test(plan_success_is_canonical) :-
    Plan = plan([final(literal("ok"))]),
    plan_outcome(Plan, [], [], _{}, Outcome),
    assertion(Outcome.status == success),
    assertion(Outcome.kind == plan),
    assertion(Outcome.value == "ok"),
    assertion(Outcome.error == none).

test(plan_capability_denial_is_distinct) :-
    Plan = plan([tool(ok_tool, literal(1), value),
                 final(var(value))]),
    plan_outcome(Plan, [], [], _{}, Outcome),
    assertion(Outcome.status == capability_denied),
    assertion(Outcome.error.kind == capability_denied).

test(plan_validation_failure_is_distinct) :-
    Plan = plan([final(var(unbound))]),
    plan_outcome(Plan, [], [], _{}, Outcome),
    assertion(Outcome.status == validation_failure),
    assertion(Outcome.phase == validate).

test(plan_depth_exhaustion_is_distinct) :-
    Child = plan([final(literal(child))]),
    Plan = plan([rlm(Child, child), final(var(child))]),
    Options = [budget(_{max_depth:1})],
    plan_outcome(Plan, [rlm], Options, _{}, Outcome),
    assertion(Outcome.status == depth_exhausted),
    assertion(Outcome.error.budget == depth).

test(plan_resource_exhaustion_is_distinct) :-
    Plan = plan([checkpoint(one), final(literal(ok))]),
    Options = [budget(_{max_steps:1})],
    plan_outcome(Plan, [checkpoint], Options, _{}, Outcome),
    assertion(Outcome.status == resource_exhausted),
    assertion(Outcome.error.budget == steps).

test(plan_timeout_is_distinct) :-
    Plan = plan([tool(slow_tool, literal(ok), value),
                 final(var(value))]),
    plan_runtime([tool(slow_tool, outcome_test_support:slow_tool)],
                 _{time_limit:0.02},
                 Options),
    plan_outcome(Plan, [tool(slow_tool)], Options, _{}, Outcome),
    assertion(Outcome.status == timeout),
    assertion(Outcome.error.kind == time_limit_exceeded).

test(plan_exception_is_distinct) :-
    Plan = plan([tool(boom_tool, literal(ok), value),
                 final(var(value))]),
    plan_runtime([tool(boom_tool, outcome_test_support:boom_tool)],
                 _{},
                 Options),
    plan_outcome(Plan, [tool(boom_tool)], Options, _{}, Outcome),
    assertion(Outcome.status == exception),
    assertion(Outcome.error.kind == tool_error).

test(goal_logical_failure_is_not_exception) :-
    goal_outcome(fail, [], Outcome),
    assertion(Outcome.status == logical_failure),
    assertion(Outcome.error == none).

test(goal_exception_is_distinct) :-
    goal_outcome(throw(error(test_goal_boom, _)), [], Outcome),
    assertion(Outcome.status == exception),
    assertion(Outcome.error.kind == exception).

test(goal_timeout_is_distinct) :-
    goal_outcome(sleep(0.2),
                 [outcome_limits(_{goal_time_limit:0.02})],
                 Outcome),
    assertion(Outcome.status == timeout).

test(goal_depth_exhaustion_is_distinct) :-
    goal_outcome(outcome_test_support:deep(100),
                 [outcome_limits(_{goal_depth_limit:5})],
                 Outcome),
    assertion(Outcome.status == depth_exhausted).

test(goal_preserves_residual_constraints) :-
    goal_outcome((X #> 3), [], Outcome),
    assertion(Outcome.status == success),
    assertion(Outcome.residual_constraints \== []),
    assertion(var(X)).

test(plan_inspection_reports_required_capabilities) :-
    Plan = plan([tool(ok_tool, literal(1), value),
                 final(var(value))]),
    plan_inspect(Plan, [], default, Inspection),
    assertion(Inspection.status == capability_denied),
    assertion(Inspection.required_capabilities == [tool(ok_tool)]).

test(predicate_inspection_is_structured) :-
    predicate_inspect(outcome_test_support:deep(_), Inspection),
    assertion(Inspection.module == outcome_test_support),
    assertion(Inspection.name == deep),
    assertion(Inspection.arity =:= 1),
    assertion(is_list(Inspection.properties)).

test(trace_node_limit_includes_root) :-
    Plan = plan([checkpoint(one), checkpoint(two), final(literal(ok))]),
    Options = [ outcome_limits(_{trace_max_nodes:2}),
                budget(_{max_steps:4})
              ],
    plan_outcome(Plan, [checkpoint], Options, _{}, Outcome),
    outcome_trace(Outcome, Options, Trace),
    assertion(Trace.nodes =< 2),
    assertion(Trace.truncated == true).

test(trace_byte_limit_returns_bounded_summary) :-
    Long = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz",
    Plan = plan([final(literal(Long))]),
    Options = [outcome_limits(_{trace_max_bytes:128})],
    plan_outcome(Plan, [], Options, _{}, Outcome),
    outcome_trace(Outcome, Options, Trace),
    assertion(Trace.truncated == true),
    assertion(Trace.byte_limit =:= 128).

test(repair_failed_execution_then_succeeds_without_resetting_budget) :-
    Plan = plan([tool(fail_tool, literal(start), failed),
                 final(var(failed))]),
    Tools = [ tool(fail_tool, outcome_test_support:fail_tool),
              tool(ok_tool, outcome_test_support:ok_tool)
            ],
    Options = [ tools(Tools),
                budget(_{max_steps:4,
                         max_tool_calls:2,
                         time_limit:1.0}),
                outcome_limits(_{max_repairs:1})
              ],
    plan_repair(Plan,
                [tool(fail_tool), tool(ok_tool)],
                Options,
                _{},
                outcome_test_support:repair_failed_tool,
                Outcome),
    assertion(Outcome.status == success),
    assertion(Outcome.value == "repaired-ok"),
    assertion(Outcome.repair.attempts =:= 1),
    assertion(Outcome.budget_remaining.tool_calls =:= 0),
    assertion(Outcome.budget_remaining.steps =:= 1).

test(repair_cannot_reset_exhausted_tool_budget) :-
    Plan = plan([tool(fail_tool, literal(start), failed),
                 final(var(failed))]),
    Tools = [ tool(fail_tool, outcome_test_support:fail_tool),
              tool(ok_tool, outcome_test_support:ok_tool)
            ],
    Options = [ tools(Tools),
                budget(_{max_steps:4,
                         max_tool_calls:1,
                         time_limit:1.0}),
                outcome_limits(_{max_repairs:1})
              ],
    plan_repair(Plan,
                [tool(fail_tool), tool(ok_tool)],
                Options,
                _{},
                outcome_test_support:repair_failed_tool,
                Outcome),
    assertion(Outcome.status \== success).

test(validation_failure_can_be_repaired_without_spending_execution_budget) :-
    Plan = plan([final(var(missing))]),
    Options = [ budget(_{max_steps:2, time_limit:1.0}),
                outcome_limits(_{max_repairs:1})
              ],
    plan_repair(Plan,
                [],
                Options,
                _{},
                outcome_test_support:repair_to_literal,
                Outcome),
    assertion(Outcome.status == success),
    assertion(Outcome.value == "literal-repair-ok"),
    assertion(Outcome.budget_remaining.steps =:= 1).

:- end_tests(rlm_outcome).
