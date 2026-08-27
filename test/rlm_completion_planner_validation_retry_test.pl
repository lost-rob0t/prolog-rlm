:- begin_tests(rlm_completion_planner_validation_retry).

:- use_module('../prolog/rlm_completion').

:- dynamic planner_call_count/1.
:- dynamic model_call_count/1.

reset_retry_fixture :-
    retractall(planner_call_count(_)),
    retractall(model_call_count(_)),
    assertz(planner_call_count(0)),
    assertz(model_call_count(0)).

bump_count(Predicate, Count) :-
    Goal0 =.. [Predicate, Previous],
    retract(Goal0),
    Count is Previous+1,
    Goal =.. [Predicate, Count],
    assertz(Goal).

planner_output(Plan,
               planner_output{plan:Plan,
                              usage:_{prompt_tokens:1,
                                      completion_tokens:1,
                                      total_tokens:2,
                                      cost:0.0}}).

structurally_invalid_then_valid_planner(_, ok(Output)) :-
    bump_count(planner_call_count, Call),
    (   Call =:= 1
    ->  Plan = plan([model(openrouter,
                          literal("MUST_NOT_EXECUTE"),
                          _{},
                          forbidden),
                     final(literal("first-final")),
                     final(literal("second-final"))])
    ;   Plan = plan([final(literal("recovered"))])
    ),
    planner_output(Plan, Output).

always_structurally_invalid_planner(_, ok(Output)) :-
    bump_count(planner_call_count, _),
    Plan = plan([model(openrouter,
                       literal("MUST_NOT_EXECUTE"),
                       _{},
                       forbidden),
                  final(literal("first-final")),
                  final(literal("second-final"))]),
    planner_output(Plan, Output).

capability_denied_then_valid_planner(_, ok(Output)) :-
    bump_count(planner_call_count, Call),
    (   Call =:= 1
    ->  Plan = plan([model(openrouter,
                          literal("MUST_NOT_EXECUTE"),
                          _{},
                          forbidden),
                     final(literal("denied"))])
    ;   Plan = plan([final(literal("MUST_NOT_REPAIR_POLICY"))])
    ),
    planner_output(Plan, Output).

must_not_execute_model(_, ok(_)) :-
    bump_count(model_call_count, _),
    throw(error(invalid_candidate_executed,
                context(rlm_completion_planner_validation_retry_test,
                        'invalid planner candidate executed'))).

retry_options(Planner, Capabilities, Options) :-
    Options = [ planner_handler(Planner),
                model_handler(plunit_rlm_completion_planner_validation_retry:must_not_execute_model),
                planner_attempts(2),
                skill_mode(off),
                capabilities(Capabilities),
                child_capabilities([])
              ].

test(structural_validation_failure_uses_configured_retry,
     [setup(reset_retry_fixture)]) :-
    retry_options(
        plunit_rlm_completion_planner_validation_retry:structurally_invalid_then_valid_planner,
        [model(openrouter)],
        Options),
    rlm_completion("recover a structurally invalid planner candidate",
                   text("opaque context"),
                   Options,
                   Outcome),
    Outcome = ok(Completion),
    assertion(Completion.value == "recovered"),
    assertion(Completion.usage.model_calls =:= 2),
    assertion(Completion.usage.total_tokens =:= 4),
    planner_call_count(PlannerCalls),
    model_call_count(ModelCalls),
    assertion(PlannerCalls =:= 2),
    assertion(ModelCalls =:= 0).

test(structural_validation_retry_exhaustion_is_explicit_and_accounted,
     [setup(reset_retry_fixture)]) :-
    retry_options(
        plunit_rlm_completion_planner_validation_retry:always_structurally_invalid_planner,
        [model(openrouter)],
        Options),
    rlm_completion("exhaust structurally invalid planner candidates",
                   text("opaque context"),
                   Options,
                   Outcome),
    Outcome = error(Error),
    assertion(Error.phase == planner),
    assertion(Error.kind == plan_validation_failed),
    assertion(Error.attempts =:= 2),
    assertion(Error.usage.model_calls =:= 2),
    assertion(Error.usage.total_tokens =:= 4),
    assertion(Error.cause.phase == validate),
    assertion(Error.cause.kind == invalid_plan),
    assertion(Error.cause.detail == final_must_be_unique_and_last),
    planner_call_count(PlannerCalls),
    model_call_count(ModelCalls),
    assertion(PlannerCalls =:= 2),
    assertion(ModelCalls =:= 0).

test(capability_denial_is_not_a_planner_repair_signal,
     [setup(reset_retry_fixture)]) :-
    retry_options(
        plunit_rlm_completion_planner_validation_retry:capability_denied_then_valid_planner,
        [],
        Options),
    rlm_completion("do not repair around host capability denial",
                   text("opaque context"),
                   Options,
                   Outcome),
    Outcome = error(Error),
    assertion(Error.phase == validate),
    assertion(Error.kind == capability_denied),
    assertion(Error.capability == model(openrouter)),
    planner_call_count(PlannerCalls),
    model_call_count(ModelCalls),
    assertion(PlannerCalls =:= 1),
    assertion(ModelCalls =:= 0).

:- end_tests(rlm_completion_planner_validation_retry).
