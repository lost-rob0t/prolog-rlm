:- module(outcome_test_support,
          [ fail_tool/2,
            ok_tool/2,
            slow_tool/2,
            boom_tool/2,
            repair_failed_tool/4,
            repair_to_literal/4,
            slow_repair/4,
            reset_repair_marker/0,
            repair_completed/0,
            deep/1
          ]).

:- dynamic repair_completed/0.

fail_tool(_, _) :-
    throw(error(test_tool_failure,
                context(outcome_test_support, fail_tool))).

ok_tool(Value, Value).

slow_tool(Value, Value) :-
    sleep(0.2).

boom_tool(_, _) :-
    throw(error(test_tool_boom,
                context(outcome_test_support, boom_tool))).

repair_failed_tool(Observation, Attempt, _, RepairedPlan) :-
    Observation.status == exception,
    Attempt =:= 1,
    RepairedPlan = plan([
        tool(ok_tool, literal("repaired-ok"), repaired),
        final(var(repaired))
    ]).

repair_to_literal(Observation, Attempt, _, RepairedPlan) :-
    memberchk(Observation.status,
              [validation_failure, capability_denied]),
    Attempt =:= 1,
    RepairedPlan = plan([final(literal("literal-repair-ok"))]).

slow_repair(_, 1, _, RepairedPlan) :-
    sleep(0.2),
    assertz(repair_completed),
    RepairedPlan = plan([final(literal("too-late"))]).

reset_repair_marker :-
    retractall(repair_completed).

deep(0) :- !.
deep(N) :-
    N > 0,
    Next is N-1,
    deep(Next).
