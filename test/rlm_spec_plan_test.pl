:- begin_tests(rlm_spec_plan).

:- use_module('../prolog/rlm_spec').
:- use_module('../prolog/rlm_spec_plan').

spec_plan_registry([
    assertion_provider(module_exports,
                       1,
                       plunit_rlm_spec_plan:validate_export_args,
                       plunit_rlm_spec_plan:evaluate_export,
                       plunit_rlm_spec_plan:observe_export,
                       _{ verifier:_{id:project_semantics,version:1},
                          collector:_{id:project_kb,version:1},
                          evidence_policy:_{ required_evidence:true,
                                             source_classes:[project_kb],
                                             trust_classes:[observed],
                                             freshness:current,
                                             coherence:project,
                                             state_ref:any
                                           },
                          latency:pure,
                          description:"spec-plan fixture"
                        })
]).

validate_export_args(Args) :-
    is_dict(Args),
    atom(Args.module),
    Args.symbol = Name/Arity,
    atom(Name),
    integer(Arity),
    Arity >= 0.

evaluate_export(Assertion, Observation, Status) :-
    Module = Assertion.args.module,
    Symbol = Assertion.args.symbol,
    ( Observation.value = export_state(Module, Symbol, true)
    -> Status = passed
    ;  Status = failed
    ).

observe_export(_, _, _,
               _{ status:passed,
                  value:export_state(foo,foo/1,true),
                  evidence_refs:[project_fact(foo,foo/1)],
                  source_class:project_kb,
                  trust_class:observed,
                  provenance:_{provider:fixture},
                  snapshot:fixture,
                  freshness:current,
                  coherence:project,
                  state_ref:fixture
                }).

freeze_spec(Version, Frozen) :-
    spec_plan_registry(Registry),
    Input = _{ schema_version:1,
               subject:_{project:demo},
               requirements:[
                   _{ id:api,
                      assertion:assertion(module_exports,
                                          _{module:foo,symbol:foo/1}),
                      severity:required,
                      provenance:_{source:test}
                    }
               ],
               invariants:[no_unbounded_execution],
               output_contract:_{kind:text},
               provenance:_{source:test_suite}
             },
    spec_validate(Input, Registry, ok(Validated)),
    spec_freeze(Validated,
                [series(spec_plan_api),version(Version)],
                ok(Frozen)).

seed_refiner(Frozen, Seed, Candidate) :-
    Seed.spec_ref == Frozen.ref,
    Candidate = plan_candidate{
                    plan:plan([final(literal(done))]),
                    project_state:Seed.planning_context
                }.

replan_refiner(Frozen, Context, Candidate) :-
    Context.spec_ref == Frozen.ref,
    Context.execution_state.spec_ref == Frozen.ref,
    Candidate = plan_candidate{
                    plan:plan([final(literal(repaired))]),
                    project_state:Context.planner_input
                }.

test(seed_is_non_executable_spec_bound_planning_data) :-
    freeze_spec(1, Frozen),
    plan_seed_from_spec(Frozen,
                        project_state{revision:r1},
                        ok(Seed)),
    assertion(Seed.spec_ref == Frozen.ref),
    assertion(Seed.subject == Frozen.subject),
    assertion(Seed.planning_context == project_state{revision:r1}),
    assertion(Seed.goals = [Goal]),
    assertion(Goal.requirement_id == api),
    assertion(Goal.severity == required).

test(refine_binds_candidate_to_same_frozen_spec) :-
    freeze_spec(1, Frozen),
    plan_seed_from_spec(Frozen, project_state{revision:r1}, ok(Seed)),
    plan_refine(Frozen,
                Seed,
                plunit_rlm_spec_plan:seed_refiner,
                ok(SpecPlan)),
    assertion(SpecPlan.spec_ref == Frozen.ref),
    assertion(SpecPlan.project_state == project_state{revision:r1}),
    assertion(SpecPlan.plan == plan([final(literal(done))])).

test(validate_against_spec_uses_existing_closed_plan_gate) :-
    freeze_spec(1, Frozen),
    plan_seed_from_spec(Frozen, none, ok(Seed)),
    plan_refine(Frozen,
                Seed,
                plunit_rlm_spec_plan:seed_refiner,
                ok(SpecPlan)),
    plan_validate_against_spec(Frozen,
                               SpecPlan,
                               [],
                               default,
                               ok(Validated)),
    assertion(Validated.spec_ref == Frozen.ref),
    assertion(Validated.validation.plan == plan([final(literal(done))])).

test(prepare_runs_seed_refine_validate_without_execution) :-
    freeze_spec(1, Frozen),
    plan_prepare_from_spec(Frozen,
                           project_state{revision:r2},
                           plunit_rlm_spec_plan:seed_refiner,
                           [],
                           default,
                           ok(Preparation)),
    assertion(Preparation.spec_ref == Frozen.ref),
    assertion(Preparation.spec_plan.project_state == project_state{revision:r2}),
    assertion(Preparation.validation.validation.estimate.steps =:= 1).

test(replan_keeps_acceptance_authority_on_same_spec) :-
    freeze_spec(1, Frozen),
    ExecutionState = execution_state{spec_ref:Frozen.ref,
                                     status:failed},
    plan_replan(Frozen,
                ExecutionState,
                project_state{revision:r3},
                plunit_rlm_spec_plan:replan_refiner,
                ok(SpecPlan)),
    assertion(SpecPlan.spec_ref == Frozen.ref),
    assertion(SpecPlan.plan == plan([final(literal(repaired))])),
    assertion(SpecPlan.project_state == project_state{revision:r3}).

test(replan_rejects_execution_state_from_other_spec) :-
    freeze_spec(1, Frozen1),
    freeze_spec(2, Frozen2),
    ExecutionState = execution_state{spec_ref:Frozen2.ref,status:failed},
    plan_replan(Frozen1,
                ExecutionState,
                none,
                plunit_rlm_spec_plan:replan_refiner,
                error(Error)),
    assertion(Error.phase == replan),
    assertion(Error.kind == rejected),
    assertion(Error.detail = spec_ref_mismatch(_, _)).

:- end_tests(rlm_spec_plan).
