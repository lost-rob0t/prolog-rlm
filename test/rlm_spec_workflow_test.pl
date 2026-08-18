:- begin_tests(rlm_spec_workflow).

:- use_module('../prolog/rlm_graph').
:- use_module('../prolog/rlm_spec').
:- use_module('../prolog/rlm_spec_workflow').
:- use_module('../prolog/rlm_verify').

:- dynamic workflow_execute_count/1.
:- dynamic workflow_planner_snapshot/1.

reset_workflow_state :-
    retractall(workflow_execute_count(_)),
    assertz(workflow_execute_count(0)),
    retractall(workflow_planner_snapshot(_)).

increment_workflow_execute_count(Count) :-
    retract(workflow_execute_count(N0)),
    Count is N0+1,
    assertz(workflow_execute_count(Count)).

workflow_registry([
    assertion_provider(module_exports,
                       1,
                       plunit_rlm_spec_workflow:validate_export_args,
                       plunit_rlm_spec_workflow:evaluate_export,
                       plunit_rlm_spec_workflow:observe_export,
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
                          description:"workflow project knowledge"
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

observe_export(Requirement, Sources, _, Raw) :-
    member(project_kb(Snapshot, Facts), Sources),
    Module = Requirement.assertion.args.module,
    Symbol = Requirement.assertion.args.symbol,
    ( memberchk(exports(Module, Symbol), Facts) -> Exists = true ; Exists = false ),
    StateRef = project_state(Snapshot.project, Snapshot.revision),
    Raw = _{ status:passed,
             value:export_state(Module, Symbol, Exists),
             evidence_refs:[project_fact(Module, Symbol)],
             source_class:project_kb,
             trust_class:observed,
             provenance:_{provider:fake_project_kb},
             snapshot:Snapshot,
             freshness:current,
             coherence:project,
             state_ref:StateRef
           }.

workflow_spec(Symbol, Input) :-
    Input = _{ schema_version:1,
               subject:_{project:demo},
               requirements:[
                   _{ id:api,
                      assertion:assertion(module_exports,
                                          _{module:foo,symbol:Symbol}),
                      severity:required,
                      provenance:_{source:test}
                    }
               ],
               provenance:_{source:test_suite}
             }.

freeze_workflow_spec(Symbol, Version, Frozen) :-
    workflow_registry(Registry),
    workflow_spec(Symbol, Input),
    spec_validate(Input, Registry, ok(Validated)),
    spec_freeze(Validated,
                [series(workflow),version(Version)],
                ok(Frozen)).

snapshot(Revision,
         project_snapshot{project:demo,
                          revision:Revision,
                          source_digest:Revision,
                          parser_set:[fixture-1],
                          created_at:fixture}).

/* Independent compositions -------------------------------------------- */

test(spec_plus_supplied_plan_binds_without_execution) :-
    reset_workflow_state,
    freeze_workflow_spec(foo/1, 1, Frozen),
    Plan = plan([final(ok)]),
    snapshot(r1, Snapshot),
    spec_plan_bind(Frozen, Plan, Snapshot, ok(SpecPlan)),
    assertion(SpecPlan.spec_ref == Frozen.ref),
    assertion(SpecPlan.project_state == Snapshot),
    workflow_execute_count(0).

test(spec_plus_supplied_plan_executes_through_existing_plan_runtime) :-
    freeze_workflow_spec(foo/1, 1, Frozen),
    Plan = plan([final(ok)]),
    spec_plan_bind(Frozen, Plan, none, ok(SpecPlan)),
    spec_plan_execute(SpecPlan, [], [], _{}, ok(Execution)),
    assertion(Execution.spec_ref == Frozen.ref),
    assertion(Execution.outcome.status == success).

test(changed_plan_preserves_frozen_spec_identity) :-
    freeze_workflow_spec(foo/1, 1, Frozen),
    spec_plan_bind(Frozen, plan([final(first)]), none, ok(First)),
    spec_plan_bind(Frozen, plan([final(second)]), none, ok(Second)),
    assertion(First.spec_ref == Second.spec_ref),
    assertion(First.plan \== Second.plan).

test(changed_spec_requires_new_identity) :-
    freeze_workflow_spec(foo/1, 1, First),
    freeze_workflow_spec(bar/1, 2, Second),
    assertion(First.ref \== Second.ref),
    assertion(First.ref.fingerprint \== Second.ref.fingerprint).

/* Full graph composition ---------------------------------------------- */

test(full_success_refreshes_project_snapshot_then_verifies) :-
    reset_workflow_state,
    workflow_registry(Registry),
    freeze_workflow_spec(foo/1, 1, Frozen),
    snapshot(r1, K1),
    Config = _{ plan:plan([final(applied)]),
                executor:plunit_rlm_spec_workflow:counting_executor,
                observation_sources:[project_kb(K1,[])],
                source_refresher:plunit_rlm_spec_workflow:refresh_to_exporting_snapshot,
                max_repairs:0
              },
    spec_workflow_compile(Frozen, Registry, Config, [], ok(Workflow)),
    spec_workflow_run(Workflow, [], ok(Result)),
    assertion(Result.status == completed),
    assertion(Result.state.status == passed),
    assertion(Result.state.verification.status == passed),
    workflow_execute_count(1).

test(verify_failure_replans_executes_and_then_passes_same_spec) :-
    reset_workflow_state,
    workflow_registry(Registry),
    freeze_workflow_spec(foo/1, 1, Frozen),
    snapshot(r1, K1),
    Config = _{ plan:plan([final(first_attempt)]),
                executor:plunit_rlm_spec_workflow:counting_executor,
                observation_sources:[project_kb(K1,[])],
                source_refresher:plunit_rlm_spec_workflow:refresh_after_second_execution,
                repair:plunit_rlm_spec_workflow:repair_plan,
                max_repairs:1
              },
    spec_workflow_compile(Frozen, Registry, Config, [], ok(Workflow)),
    spec_workflow_run(Workflow, [], ok(Result)),
    assertion(Result.state.status == passed),
    assertion(Result.state.repairs =:= 1),
    assertion(Result.state.spec_ref == Frozen.ref),
    assertion(Result.state.plan.spec_ref == Frozen.ref),
    workflow_execute_count(2).

test(planner_and_verifier_consume_same_project_state_abstraction) :-
    reset_workflow_state,
    workflow_registry(Registry),
    freeze_workflow_spec(foo/1, 1, Frozen),
    snapshot(r7, Snapshot),
    ProjectState = project_kb(Snapshot,[exports(foo,foo/1)]),
    Config = _{ planner:plunit_rlm_spec_workflow:planner_from_project_kb,
                planning_context:ProjectState,
                executor:plunit_rlm_spec_workflow:counting_executor,
                observation_sources:[ProjectState],
                max_repairs:0
              },
    spec_workflow_compile(Frozen, Registry, Config, [], ok(Workflow)),
    spec_workflow_run(Workflow, [], ok(Result)),
    assertion(Result.state.status == passed),
    workflow_planner_snapshot(Snapshot),
    Result.state.observations = [Observation],
    assertion(Observation.snapshot == Snapshot).

test(restart_cannot_resume_checkpoint_with_different_frozen_spec) :-
    reset_workflow_state,
    workflow_registry(Registry),
    freeze_workflow_spec(foo/1, 1, Frozen1),
    freeze_workflow_spec(bar/1, 2, Frozen2),
    snapshot(r1, Snapshot),
    Config1 = _{plan:plan([final(done)]),
                observation_sources:[project_kb(Snapshot,[exports(foo,foo/1)])],
                max_repairs:0},
    Config2 = _{plan:plan([final(done)]),
                observation_sources:[project_kb(Snapshot,[exports(foo,foo/1),
                                                         exports(foo,bar/1)])],
                max_repairs:0},
    spec_workflow_compile(Frozen1, Registry, Config1, [], ok(Workflow1)),
    spec_workflow_compile(Frozen2, Registry, Config2, [], ok(Workflow2)),
    setup_call_cleanup(
        graph_backend_open(memory, Backend),
        ( spec_workflow_run(Workflow1,
                            [backend(Backend),run_id(bound_run)],
                            ok(_)),
          spec_workflow_resume(Workflow2,
                               Backend,
                               bound_run,
                               ignored,
                               [],
                               error(Error)),
          assertion(Error.kind == graph_failure),
          assertion(Error.detail = graph_id_mismatch(_, _))
        ),
        graph_backend_close(Backend)).

/* Trusted workflow fixtures ------------------------------------------- */

counting_executor(Frozen, SpecPlan, _, Execution) :-
    increment_workflow_execute_count(Count),
    Execution = spec_execution{spec_ref:Frozen.ref,
                               plan:SpecPlan,
                               outcome:execution_outcome{
                                           status:success,
                                           kind:test,
                                           phase:execute,
                                           value:Count
                                       }}.

refresh_to_exporting_snapshot(_, _, _, _, Sources) :-
    snapshot(r2, K2),
    Sources = [project_kb(K2,[exports(foo,foo/1)])].

refresh_after_second_execution(_, _, _, Sources0, Sources) :-
    workflow_execute_count(Count),
    (   Count >= 2
    ->  snapshot(r2, K2),
        Sources = [project_kb(K2,[exports(foo,foo/1)])]
    ;   Sources = Sources0
    ).

repair_plan(Frozen, Report, _, OldSpecPlan, _, NewPlan) :-
    Frozen.ref == OldSpecPlan.spec_ref,
    Report.status == rejected,
    NewPlan = plan([final(repaired)]).

planner_from_project_kb(_, ProjectState, Plan, ProjectState) :-
    ProjectState = project_kb(Snapshot, Facts),
    assertz(workflow_planner_snapshot(Snapshot)),
    memberchk(exports(foo,foo/1), Facts),
    Plan = plan([final(already_satisfied)]).

:- end_tests(rlm_spec_workflow).
