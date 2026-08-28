:- begin_tests(rlm_spec_strategy).

:- use_module('../prolog/rlm_spec').
:- use_module('../prolog/rlm_spec_strategy').

:- dynamic strategy_runs/1.

reset_strategy_runs :-
    retractall(strategy_runs(_)),
    assertz(strategy_runs(0)).

increment_strategy_runs(Count) :-
    retract(strategy_runs(N0)),
    Count is N0+1,
    assertz(strategy_runs(Count)).

strategy_registry([
    assertion_provider(strategy_true,
                       1,
                       plunit_rlm_spec_strategy:validate_strategy_args,
                       plunit_rlm_spec_strategy:evaluate_strategy,
                       plunit_rlm_spec_strategy:observe_strategy,
                       _{verifier:_{id:strategy_verifier,version:1},
                         collector:_{id:strategy_collector,version:1},
                         evidence_policy:_{required_evidence:true,
                                           source_classes:[strategy_state],
                                           trust_classes:[observed],
                                           freshness:current,
                                           coherence:none,
                                           state_ref:any},
                         latency:pure,
                         description:"strategy workflow fixture"})
]).

validate_strategy_args(Args) :- is_dict(Args).

evaluate_strategy(_, Observation, Status) :-
    ( Observation.value == true -> Status=passed ; Status=failed ).

observe_strategy(_, Sources, _, Raw) :-
    ( memberchk(strategy_state(true), Sources) -> Value=true ; Value=false ),
    Raw = _{status:passed,value:Value,
            evidence_refs:[strategy_fixture],
            source_class:strategy_state,trust_class:observed,
            provenance:_{provider:strategy_fixture},
            freshness:current,coherence:none,state_ref:none}.

strategy_frozen(Frozen) :-
    strategy_registry(Registry),
    Input = _{schema_version:1,subject:strategy_test,
              requirements:[_{id:accepted,
                              assertion:assertion(strategy_true,_{}),
                              severity:required}]},
    spec_validate(Input, Registry, ok(Validated)),
    spec_freeze(Validated, [series(strategy_test),version(1)], ok(Frozen)).

direct_runner(Frozen, Payload, ProjectState, _, Outcome) :-
    increment_strategy_runs(Count),
    Outcome = direct_fixture{spec_ref:Frozen.ref,payload:Payload,
                             project_state:ProjectState,attempt:Count}.

refresh_to_pass(_, _, _, _, [strategy_state(true)]).
refresh_to_fail(_, _, _, _, [strategy_state(false)]).

repair_direct(Frozen, Report, Execution, OldStrategy, _, Candidate) :-
    Frozen.ref == OldStrategy.spec_ref,
    Report.status == rejected,
    Execution.mode == direct,
    Candidate = strategy(direct, repaired_payload).

test(binds_direct_and_typed_strategies_to_same_frozen_spec) :-
    strategy_frozen(Frozen),
    spec_strategy_bind(Frozen, direct, request_payload, project_state,
                       ok(Direct)),
    spec_strategy_bind(Frozen, typed_plan,
                       plan([final(literal(done))]), project_state,
                       ok(Typed)),
    assertion(Direct.spec_ref == Frozen.ref),
    assertion(Typed.spec_ref == Frozen.ref),
    assertion(Direct.mode == direct),
    assertion(Typed.mode == typed_plan).

test(direct_strategy_refreshes_observes_and_verifies) :-
    reset_strategy_runs,
    strategy_frozen(Frozen),
    strategy_registry(Registry),
    Config = _{strategy:strategy(direct,initial_payload),
               project_state:project_state,
               direct_runner:plunit_rlm_spec_strategy:direct_runner,
               observation_sources:[strategy_state(false)],
               source_refresher:plunit_rlm_spec_strategy:refresh_to_pass,
               max_repairs:0},
    spec_strategy_workflow_compile(Frozen, Registry, Config, [], ok(Workflow)),
    spec_strategy_workflow_run(Workflow, [], ok(Result)),
    assertion(Result.state.status == passed),
    assertion(Result.state.strategy.mode == direct),
    assertion(Result.state.verification.status == passed),
    strategy_runs(1).

test(typed_strategy_uses_existing_plan_execution) :-
    strategy_frozen(Frozen),
    strategy_registry(Registry),
    Config = _{strategy:strategy(typed_plan,
                                 plan([final(literal(plan_ok))])),
               observation_sources:[strategy_state(true)],
               max_repairs:0},
    spec_strategy_workflow_compile(Frozen, Registry, Config, [], ok(Workflow)),
    spec_strategy_workflow_run(Workflow, [], ok(Result)),
    assertion(Result.state.status == passed),
    assertion(Result.state.execution.mode == typed_plan),
    assertion(Result.state.execution.outcome.outcome.status == success).

test(failed_verification_repairs_then_exhausts_without_changing_spec) :-
    reset_strategy_runs,
    strategy_frozen(Frozen),
    strategy_registry(Registry),
    Config = _{strategy:strategy(direct,initial_payload),
               direct_runner:plunit_rlm_spec_strategy:direct_runner,
               observation_sources:[strategy_state(false)],
               source_refresher:plunit_rlm_spec_strategy:refresh_to_fail,
               repair:plunit_rlm_spec_strategy:repair_direct,
               max_repairs:1},
    spec_strategy_workflow_compile(Frozen, Registry, Config, [], ok(Workflow)),
    spec_strategy_workflow_run(Workflow, [], ok(Result)),
    assertion(Result.state.status == rejected),
    assertion(Result.state.verification.status == rejected),
    assertion(Result.state.repairs =:= 1),
    assertion(Result.state.strategy.spec_ref == Frozen.ref),
    assertion(Result.state.strategy.payload == repaired_payload),
    strategy_runs(2).

:- end_tests(rlm_spec_strategy).
