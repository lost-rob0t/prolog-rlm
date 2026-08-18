:- begin_tests(rlm_spec_verify).

:- use_module('../prolog/rlm_assertion').
:- use_module('../prolog/rlm_artifact').
:- use_module('../prolog/rlm_spec').
:- use_module('../prolog/rlm_verify').

:- dynamic observer_calls/1.

reset_observer_calls :-
    retractall(observer_calls(_)),
    assertz(observer_calls(0)).

increment_observer_calls :-
    retract(observer_calls(N0)),
    N is N0+1,
    assertz(observer_calls(N)).

/* Registry fixtures ---------------------------------------------------- */

project_registry([
    assertion_provider(module_exports,
                       1,
                       plunit_rlm_spec_verify:validate_module_export_args,
                       plunit_rlm_spec_verify:evaluate_module_export,
                       plunit_rlm_spec_verify:observe_module_export,
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
                          description:"query canonical project knowledge"
                        })
]).

project_registry_verifier_v2([
    assertion_provider(module_exports,
                       1,
                       plunit_rlm_spec_verify:validate_module_export_args,
                       plunit_rlm_spec_verify:evaluate_module_export,
                       plunit_rlm_spec_verify:observe_module_export,
                       _{ verifier:_{id:project_semantics,version:2},
                          collector:_{id:project_kb,version:1},
                          evidence_policy:_{ required_evidence:true,
                                             source_classes:[project_kb],
                                             trust_classes:[observed],
                                             freshness:current,
                                             coherence:project,
                                             state_ref:any
                                           },
                          latency:pure,
                          description:"new verifier version"
                        })
]).

dataset_registry([
    assertion_provider(record_count,
                       1,
                       plunit_rlm_spec_verify:validate_record_count_args,
                       plunit_rlm_spec_verify:evaluate_record_count,
                       plunit_rlm_spec_verify:observe_record_count,
                       _{ verifier:_{id:dataset_semantics,version:1},
                          collector:_{id:dataset_snapshot,version:1},
                          evidence_policy:_{ required_evidence:true,
                                             source_classes:[dataset],
                                             trust_classes:[observed],
                                             freshness:current
                                           },
                          latency:pure,
                          description:"compare structured dataset count"
                        })
]).

counting_registry([
    assertion_provider(always_true,
                       1,
                       plunit_rlm_spec_verify:validate_empty_args,
                       plunit_rlm_spec_verify:evaluate_always_true,
                       plunit_rlm_spec_verify:observe_counting,
                       _{ verifier:_{id:always_true,version:1},
                          collector:_{id:counting,version:1},
                          evidence_policy:_{ required_evidence:false,
                                             source_classes:[host],
                                             trust_classes:[trusted],
                                             freshness:any
                                           },
                          latency:pure,
                          description:"test collection separation"
                        })
]).

exception_registry([
    assertion_provider(always_true,
                       1,
                       plunit_rlm_spec_verify:validate_empty_args,
                       plunit_rlm_spec_verify:evaluate_always_true,
                       plunit_rlm_spec_verify:observe_exception,
                       _{ verifier:_{id:always_true,version:1},
                          collector:_{id:exception,version:1},
                          evidence_policy:_{ required_evidence:false,
                                             source_classes:[host],
                                             trust_classes:[trusted],
                                             freshness:any
                                           },
                          latency:pure,
                          description:"exception fixture"
                        })
]).

timeout_registry([
    assertion_provider(always_true,
                       1,
                       plunit_rlm_spec_verify:validate_empty_args,
                       plunit_rlm_spec_verify:evaluate_always_true,
                       plunit_rlm_spec_verify:observe_slow,
                       _{ verifier:_{id:always_true,version:1},
                          collector:_{id:slow,version:1},
                          evidence_policy:_{ required_evidence:false,
                                             source_classes:[host],
                                             trust_classes:[trusted],
                                             freshness:any
                                           },
                          latency:blocking,
                          description:"timeout fixture"
                        })
]).

cancel_registry([
    assertion_provider(always_true,
                       1,
                       plunit_rlm_spec_verify:validate_empty_args,
                       plunit_rlm_spec_verify:evaluate_always_true,
                       plunit_rlm_spec_verify:observe_cancelled,
                       _{ verifier:_{id:always_true,version:1},
                          collector:_{id:cancel,version:1},
                          evidence_policy:_{ required_evidence:false,
                                             source_classes:[host],
                                             trust_classes:[trusted],
                                             freshness:any
                                           },
                          latency:pure,
                          description:"cancellation fixture"
                        })
]).

verifier_exception_registry([
    assertion_provider(always_true,
                       1,
                       plunit_rlm_spec_verify:validate_empty_args,
                       plunit_rlm_spec_verify:evaluate_throws,
                       none,
                       _{ verifier:_{id:throws,version:1},
                          collector:_{id:none,version:1},
                          evidence_policy:_{ required_evidence:false,
                                             source_classes:[host],
                                             trust_classes:[trusted],
                                             freshness:any
                                           },
                          latency:pure,
                          description:"verifier exception fixture"
                        })
]).

verifier_timeout_registry([
    assertion_provider(always_true,
                       1,
                       plunit_rlm_spec_verify:validate_empty_args,
                       plunit_rlm_spec_verify:evaluate_slow,
                       none,
                       _{ verifier:_{id:slow_verify,version:1},
                          collector:_{id:none,version:1},
                          evidence_policy:_{ required_evidence:false,
                                             source_classes:[host],
                                             trust_classes:[trusted],
                                             freshness:any
                                           },
                          verify_time_limit:0.001,
                          latency:pure,
                          description:"verifier timeout fixture"
                        })
]).

no_observer_registry([
    assertion_provider(always_true,
                       1,
                       plunit_rlm_spec_verify:validate_empty_args,
                       plunit_rlm_spec_verify:evaluate_always_true,
                       none,
                       _{ verifier:_{id:always_true,version:1},
                          collector:_{id:none,version:1},
                          evidence_policy:_{ required_evidence:false,
                                             source_classes:all,
                                             trust_classes:all,
                                             freshness:any
                                           },
                          latency:pure,
                          description:"supplied evidence only"
                        })
]).

validate_module_export_args(Args) :-
    is_dict(Args),
    dict_keys(Args, Keys),
    Keys == [module,symbol],
    atom(Args.module),
    callable(Args.symbol),
    functor(Args.symbol, '/', 2),
    Args.symbol = Name/Arity,
    atom(Name),
    integer(Arity),
    Arity >= 0.

validate_record_count_args(Args) :-
    is_dict(Args),
    dict_keys(Args, Keys),
    Keys == [dataset,minimum],
    atom(Args.dataset),
    integer(Args.minimum),
    Args.minimum >= 0.

validate_empty_args(Args) :-
    is_dict(Args),
    dict_keys(Args, Keys),
    Keys == [].

evaluate_module_export(Assertion, Observation, Status) :-
    Module = Assertion.args.module,
    Symbol = Assertion.args.symbol,
    (   Observation.value = export_state(Module, Symbol, true)
    ->  Status = passed
    ;   Observation.value = exports(Module, Symbol)
    ->  Status = passed
    ;   Status = failed
    ).

evaluate_record_count(Assertion, Observation, Status) :-
    Minimum = Assertion.args.minimum,
    Count = Observation.value,
    ( integer(Count), Count >= Minimum -> Status = passed ; Status = failed ).

evaluate_always_true(_, _, passed).
evaluate_throws(_, _, _) :- throw(test_verifier_exception).
evaluate_slow(_, _, passed) :- sleep(0.05).

observe_module_export(Requirement, Sources, _, Raw) :-
    increment_observer_if_initialized,
    member(project_kb(Snapshot, Facts), Sources),
    Module = Requirement.assertion.args.module,
    Symbol = Requirement.assertion.args.symbol,
    ( memberchk(exports(Module, Symbol), Facts) -> Exists = true ; Exists = false ),
    project_state_ref(Snapshot, StateRef),
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

observe_record_count(Requirement, Sources, _, Raw) :-
    member(dataset_snapshot(Name, Count, Snapshot), Sources),
    Requirement.assertion.args.dataset == Name,
    Raw = _{ status:passed,
             value:Count,
             evidence_refs:[dataset_count(Name, Count)],
             source_class:dataset,
             trust_class:observed,
             provenance:_{provider:fake_dataset},
             snapshot:Snapshot,
             freshness:current,
             coherence:none,
             state_ref:none
           }.

observe_counting(_, _, _, Raw) :-
    increment_observer_calls,
    Raw = _{status:passed,
            value:true,
            evidence_refs:[],
            source_class:host,
            trust_class:trusted,
            provenance:_{fixture:counting},
            snapshot:none,
            freshness:current,
            coherence:none,
            state_ref:none}.

observe_exception(_, _, _, _) :-
    throw(test_observer_exception).

observe_slow(_, _, _, _) :-
    sleep(0.05),
    fail.

observe_cancelled(_, _, _, _) :-
    throw(rlm_cancelled(test_cancel)).

increment_observer_if_initialized :-
    ( observer_calls(_) -> increment_observer_calls ; true ).

project_state_ref(Snapshot, project_state(Project, Revision)) :-
    Project = Snapshot.project,
    Revision = Snapshot.revision.

project_snapshot(Revision,
                 project_snapshot{project:demo,
                                  revision:Revision,
                                  source_digest:Revision,
                                  parser_set:[prolog_parser-1],
                                  created_at:fixture}).

/* Spec fixtures -------------------------------------------------------- */

project_spec(Policy, Spec) :-
    Spec = _{ schema_version:1,
              subject:_{project:demo},
              requirements:[
                  _{ id:exports_api,
                     assertion:assertion(module_exports,
                                         _{module:foo,symbol:foo/1}),
                     evidence_policy:Policy,
                     severity:required,
                     provenance:_{source:test}
                   }
              ],
              invariants:[goal_must_not_change],
              output_contract:_{kind:verification_report},
              provenance:_{source:test_suite}
            }.

project_spec(Spec) :- project_spec(default, Spec).

dataset_spec(Spec) :-
    Spec = _{ schema_version:1,
              subject:_{dataset:people},
              requirements:[
                  _{ id:enough_records,
                     assertion:assertion(record_count,
                                         _{dataset:people,minimum:3}),
                     severity:required,
                     provenance:_{source:test}
                   }
              ],
              provenance:_{source:test_suite}
            }.

always_spec(Spec) :-
    Spec = _{schema_version:1,
             subject:generic,
             requirements:[_{id:always,
                             assertion:assertion(always_true,_{}),
                             severity:required,
                             provenance:_{source:test}}],
             provenance:_{source:test_suite}}.

freeze(Input, Registry, Series, Version, Frozen) :-
    spec_normalize(Input, ok(Normalized)),
    spec_validate(Normalized, Registry, ok(Validated)),
    spec_freeze(Validated,
                [series(Series),version(Version)],
                ok(Frozen)).

project_observation(Frozen, Revision, Status, Trust, Source, Freshness,
                    StateRef, Observation) :-
    Frozen.requirements = [Requirement],
    project_snapshot(Revision, Snapshot),
    Observation = _{ requirement_id:Requirement.id,
                     assertion:Requirement.assertion,
                     status:Status,
                     value:exports(foo,foo/1),
                     evidence_refs:[project_fact(foo,foo/1)],
                     source_class:Source,
                     trust_class:Trust,
                     provenance:_{source:test_observation},
                     verifier:Requirement.verifier,
                     collector:Requirement.collector,
                     snapshot:Snapshot,
                     freshness:Freshness,
                     coherence:project,
                     state_ref:StateRef
                   }.

/* Spec behavior -------------------------------------------------------- */

test(valid_generic_spec_normalizes_validates_and_freezes) :-
    project_registry(Registry),
    project_spec(Input),
    spec_normalize(Input, ok(Spec)),
    spec_validate(Spec, Registry, ok(Validated)),
    spec_freeze(Validated, [series(api),version(1)], ok(Frozen)),
    assertion(Frozen.ref.series == api),
    assertion(Frozen.ref.version =:= 1),
    spec_fingerprint(Frozen, Fingerprint),
    assertion(atom(Fingerprint)).

test(malformed_spec_fails_closed) :-
    spec_normalize(_{schema_version:1,subject:x}, error(Error)),
    assertion(Error.kind == spec_error).

test(non_ground_spec_fails_closed) :-
    project_spec(Input0),
    put_dict(subject, Input0, _{value:_Unbound}, Input),
    spec_normalize(Input, error(Error)),
    assertion(Error.kind == spec_error).

test(unknown_schema_version_rejected) :-
    project_spec(Input0),
    put_dict(schema_version, Input0, 99, Input),
    spec_normalize(Input, error(Error)),
    assertion(Error.detail == unknown_schema_version(99)).

test(duplicate_requirement_id_rejected) :-
    project_spec(Input0),
    Input0.requirements = [Requirement],
    put_dict(requirements, Input0, [Requirement,Requirement], Input),
    spec_normalize(Input, error(Error)),
    assertion(Error.kind == spec_error).

test(unknown_assertion_kind_rejected) :-
    project_registry(Registry),
    project_spec(Input0),
    Input0.requirements = [Requirement0],
    put_dict(assertion, Requirement0, assertion(no_such_kind,_{}), Requirement),
    put_dict(requirements, Input0, [Requirement], Input),
    spec_validate(Input, Registry, error(Error)),
    assertion(Error.kind == spec_error).

test(invalid_assertion_arguments_rejected) :-
    project_registry(Registry),
    project_spec(Input0),
    Input0.requirements = [Requirement0],
    put_dict(assertion,
             Requirement0,
             assertion(module_exports,_{module:foo,symbol:"not-a-predicate"}),
             Requirement),
    put_dict(requirements, Input0, [Requirement], Input),
    spec_validate(Input, Registry, error(Error)),
    assertion(Error.kind == spec_error).

test(normalization_and_identity_are_deterministic_across_dict_tags) :-
    project_registry(Registry),
    project_spec(Input1),
    Input2 = rlm_spec{provenance:_{source:test_suite},
                      output_contract:_{kind:verification_report},
                      invariants:[goal_must_not_change],
                      requirements:Input1.requirements,
                      subject:_{project:demo},
                      schema_version:1},
    freeze(Input1, Registry, deterministic, 1, Frozen1),
    freeze(Input2, Registry, deterministic, 1, Frozen2),
    assertion(Frozen1.ref.fingerprint == Frozen2.ref.fingerprint).

test(changed_requirement_produces_new_identity_and_version) :-
    project_registry(Registry),
    project_spec(Input1),
    Input1.requirements = [Requirement1],
    put_dict(assertion,
             Requirement1,
             assertion(module_exports,_{module:foo,symbol:bar/1}),
             Requirement2),
    put_dict(requirements, Input1, [Requirement2], Input2),
    freeze(Input1, Registry, api, 1, Frozen1),
    freeze(Input2, Registry, api, 2, Frozen2),
    assertion(Frozen1.ref.version =:= 1),
    assertion(Frozen2.ref.version =:= 2),
    assertion(Frozen1.ref.fingerprint \== Frozen2.ref.fingerprint).

test(frozen_requirement_tamper_is_detected_by_content_identity) :-
    project_registry(Registry),
    project_spec(Input),
    freeze(Input, Registry, api, 1, Frozen),
    Frozen.requirements = [Requirement0],
    put_dict(assertion,
             Requirement0,
             rlm_assertion{kind:module_exports,
                           schema_version:1,
                           args:assertion_args{module:foo,symbol:bar/1}},
             Requirement),
    put_dict(requirements, Frozen, [Requirement], Tampered),
    spec_inspect(Tampered, error(Error)),
    assertion(Error.detail = fingerprint_mismatch(_, _)).

test(artifact_persistence_preserves_exact_historical_spec_and_stale_ref) :-
    project_registry(Registry),
    project_spec(Input1),
    Input1.requirements = [Requirement1],
    put_dict(assertion,
             Requirement1,
             assertion(module_exports,_{module:foo,symbol:bar/1}),
             Requirement2),
    put_dict(requirements, Input1, [Requirement2], Input2),
    freeze(Input1, Registry, api, 1, Frozen1),
    freeze(Input2, Registry, api, 2, Frozen2),
    setup_call_cleanup(
        artifact_store_open(memory, ok(Store)),
        ( spec_publish(Store, [spec,test], Frozen1, _{run:first}, ok(Pub1)),
          spec_publish(Store, [spec,test], Frozen2, _{run:second}, ok(Pub2)),
          spec_resolve(Store, Pub1.ref, ok(Resolved1)),
          assertion(Resolved1.ref == Frozen1.ref),
          spec_resolve(Store, Pub2.ref, ok(Resolved2)),
          assertion(Resolved2.ref == Frozen2.ref),
          spec_ref_status(Store, Pub1.ref, ok(Status)),
          Status = stale(Pub1.ref.artifact_ref, Pub2.ref.artifact_ref)
        ),
        artifact_store_close(Store, _)).

test(publishing_changed_spec_without_new_logical_version_is_rejected) :-
    project_registry(Registry),
    project_spec(Input1),
    Input1.requirements = [Requirement1],
    put_dict(assertion,
             Requirement1,
             assertion(module_exports,_{module:foo,symbol:bar/1}),
             Requirement2),
    put_dict(requirements, Input1, [Requirement2], Input2),
    freeze(Input1, Registry, api, 1, Frozen1),
    freeze(Input2, Registry, api, 1, Frozen2),
    setup_call_cleanup(
        artifact_store_open(memory, ok(Store)),
        ( spec_publish(Store, [spec,test], Frozen1, _{run:first}, ok(_)),
          spec_publish(Store, [spec,test], Frozen2, _{run:second}, error(Error)),
          assertion(Error.detail = non_monotonic_spec_version(_, _))
        ),
        artifact_store_close(Store, _)).

/* Security ------------------------------------------------------------- */

test(arbitrary_callable_assertion_is_rejected) :-
    assertion_normalize(call(system:halt), error(Error)),
    assertion(Error.kind == assertion_error).

test(no_arbitrary_consult_path_from_model_assertion) :-
    assertion_normalize(consult('/tmp/model.pl'), error(Error)),
    assertion(Error.kind == assertion_error).

test(assertion_arguments_do_not_bypass_schema_validator) :-
    project_registry(Registry),
    project_spec(Input0),
    Input0.requirements = [Requirement0],
    put_dict(assertion,
             Requirement0,
             assertion(module_exports,_{module:foo,symbol:call(halt)}),
             Requirement),
    put_dict(requirements, Input0, [Requirement], Input),
    spec_validate(Input, Registry, error(Error)),
    assertion(Error.kind == spec_error).

test(model_data_cannot_install_registry_callable) :-
    project_registry(Registry),
    project_spec(Input0),
    put_dict(registry, Input0, [assertion_provider(pwn,1,halt,halt,halt,_{})], Input),
    spec_validate(Input, Registry, error(Error)),
    assertion(Error.kind == spec_error).

test(project_kb_data_cannot_register_a_trusted_verifier) :-
    project_registry(Registry),
    project_spec(Input),
    freeze(Input, Registry, api, 1, Frozen),
    project_snapshot(r1, Snapshot),
    Sources = [project_kb(Snapshot,
                          [assertion_provider(module_exports,1,halt,halt,halt,_{} )])],
    spec_observe(Frozen, Sources, Registry, [], ok(Observations)),
    spec_verify(Frozen, Observations, Registry, ok(Report)),
    assertion(Report.status == rejected),
    Report.requirements = [Result],
    assertion(Result.status == failed).

test(sanitized_catalog_exposes_no_trusted_closures) :-
    project_registry(Registry),
    assertion_registry_catalog(Registry, ok([Entry])),
    assertion(\+ get_dict(validator, Entry, _)),
    assertion(\+ get_dict(observer, Entry, _)),
    assertion(\+ get_dict(evaluator, Entry, _)),
    assertion(Entry.verifier.id == project_semantics).

test(malformed_registry_metadata_fails_closed) :-
    Bad = [assertion_provider(x,
                              1,
                              plunit_rlm_spec_verify:validate_empty_args,
                              plunit_rlm_spec_verify:evaluate_always_true,
                              none,
                              _{collector:_{id:none,version:1},
                                evidence_policy:default})],
    assertion_registry_validate(Bad, error(Error)),
    assertion(Error.kind == assertion_error).

test(host_required_evidence_policy_cannot_be_weakened_by_spec) :-
    project_registry(Registry),
    Weak = _{required_evidence:false,
             source_classes:all,
             trust_classes:all,
             freshness:any,
             coherence:none,
             state_ref:any},
    project_spec(Weak, Input),
    freeze(Input, Registry, api, 1, Frozen),
    Frozen.requirements = [Requirement],
    assertion(Requirement.evidence_policy.required_evidence == true),
    assertion(Requirement.evidence_policy.source_classes == [project_kb]),
    assertion(Requirement.evidence_policy.trust_classes == [observed]),
    assertion(Requirement.evidence_policy.freshness == current),
    assertion(Requirement.evidence_policy.coherence == project).

/* Verify --------------------------------------------------------------- */

test(all_required_checks_pass) :-
    project_registry(Registry),
    project_spec(Input),
    freeze(Input, Registry, api, 1, Frozen),
    project_state_ref(project_snapshot{project:demo,revision:r1}, StateRef),
    project_observation(Frozen, r1, passed, observed, project_kb, current,
                        StateRef, Observation),
    spec_verify(Frozen, [Observation], Registry, ok(Report)),
    assertion(Report.status == passed),
    Report.requirements = [Result],
    assertion(Result.status == passed).

test(required_failure_rejects) :-
    project_registry(Registry),
    project_spec(Input),
    freeze(Input, Registry, api, 1, Frozen),
    project_state_ref(project_snapshot{project:demo,revision:r1}, StateRef),
    project_observation(Frozen, r1, failed, observed, project_kb, current,
                        StateRef, Observation),
    spec_verify(Frozen, [Observation], Registry, ok(Report)),
    assertion(Report.status == rejected),
    Report.requirements = [Result],
    assertion(Result.status == failed).

test(optional_failure_does_not_reject) :-
    project_registry(Registry),
    project_spec(Input0),
    Input0.requirements = [Required],
    put_dict(_{id:optional_api,severity:optional}, Required, Optional),
    put_dict(requirements, Input0, [Required,Optional], Input),
    freeze(Input, Registry, api, 1, Frozen),
    Frozen.requirements = [Req1,Req2],
    project_snapshot(r1, Snapshot),
    project_state_ref(Snapshot, StateRef),
    project_observation_for_requirement(Req1, Snapshot, passed, StateRef, Obs1),
    project_observation_for_requirement(Req2, Snapshot, failed, StateRef, Obs2),
    spec_verify(Frozen, [Obs1,Obs2], Registry, ok(Report)),
    assertion(Report.status == passed).

test(missing_required_evidence_rejects) :-
    project_registry(Registry),
    project_spec(Input),
    freeze(Input, Registry, api, 1, Frozen),
    spec_verify(Frozen, [], Registry, ok(Report)),
    Report.requirements = [Result],
    assertion(Result.status == missing),
    assertion(Report.status == rejected).

test(pending_required_evidence_rejects_without_boolean_collapse) :-
    project_registry(Registry),
    project_spec(Input),
    freeze(Input, Registry, api, 1, Frozen),
    project_snapshot(r1, Snapshot),
    project_state_ref(Snapshot, StateRef),
    project_observation(Frozen, r1, pending, observed, project_kb, current,
                        StateRef, Observation),
    spec_verify(Frozen, [Observation], Registry, ok(Report)),
    Report.requirements = [Result],
    assertion(Result.status == pending),
    assertion(Report.status == rejected).

test(stale_evidence_rejects) :-
    project_registry(Registry),
    project_spec(Input),
    freeze(Input, Registry, api, 1, Frozen),
    project_snapshot(r1, Snapshot),
    project_state_ref(Snapshot, StateRef),
    project_observation(Frozen, r1, passed, observed, project_kb, stale,
                        StateRef, Observation),
    spec_verify(Frozen, [Observation], Registry, ok(Report)),
    Report.requirements = [Result],
    assertion(Result.status = stale(_)),
    assertion(Report.status == rejected).

test(wrong_snapshot_revision_rejects_as_stale) :-
    project_registry(Registry),
    Policy = _{state_ref:project_state(demo,r2)},
    project_spec(Policy, Input),
    freeze(Input, Registry, api, 1, Frozen),
    project_snapshot(r1, Snapshot),
    project_state_ref(Snapshot, StateRef),
    project_observation(Frozen, r1, passed, observed, project_kb, current,
                        StateRef, Observation),
    spec_verify(Frozen, [Observation], Registry, ok(Report)),
    Report.requirements = [Result],
    assertion(Result.status = stale(_)).

test(wrong_observation_verifier_version_rejects) :-
    project_registry(Registry),
    project_spec(Input),
    freeze(Input, Registry, api, 1, Frozen),
    project_snapshot(r1, Snapshot),
    project_state_ref(Snapshot, StateRef),
    project_observation(Frozen, r1, passed, observed, project_kb, current,
                        StateRef, Observation0),
    put_dict(verifier, Observation0, _{id:project_semantics,version:99}, Observation),
    spec_verify(Frozen, [Observation], Registry, ok(Report)),
    Report.requirements = [Result],
    assertion(Result.status = indeterminate(verifier_mismatch(_, _))).

test(current_registry_verifier_change_cannot_silently_accept_old_spec) :-
    project_registry(Registry1),
    project_registry_verifier_v2(Registry2),
    project_spec(Input),
    freeze(Input, Registry1, api, 1, Frozen),
    project_snapshot(r1, Snapshot),
    project_state_ref(Snapshot, StateRef),
    project_observation(Frozen, r1, passed, observed, project_kb, current,
                        StateRef, Observation),
    spec_verify(Frozen, [Observation], Registry2, ok(Report)),
    Report.requirements = [Result],
    assertion(Result.status = indeterminate(registry_verifier_mismatch(_))).

test(untrusted_model_claim_cannot_satisfy_observed_policy) :-
    project_registry(Registry),
    project_spec(Input),
    freeze(Input, Registry, api, 1, Frozen),
    project_snapshot(r1, Snapshot),
    project_state_ref(Snapshot, StateRef),
    project_observation(Frozen, r1, passed, model_claim, model_claim, current,
                        StateRef, Observation),
    spec_verify(Frozen, [Observation], Registry, ok(Report)),
    Report.requirements = [Result],
    assertion(Result.status = indeterminate(policy_rejected(_))),
    assertion(Report.status == rejected).

test(pure_verify_does_not_collect_evidence) :-
    reset_observer_calls,
    counting_registry(Registry),
    always_spec(Input),
    freeze(Input, Registry, generic, 1, Frozen),
    Frozen.requirements = [Requirement],
    Observation = _{ requirement_id:Requirement.id,
                     assertion:Requirement.assertion,
                     status:passed,
                     value:true,
                     evidence_refs:[],
                     source_class:host,
                     trust_class:trusted,
                     provenance:_{source:supplied},
                     verifier:Requirement.verifier,
                     collector:Requirement.collector,
                     snapshot:none,
                     freshness:current,
                     coherence:none,
                     state_ref:none
                   },
    spec_verify(Frozen, [Observation], Registry, ok(Report)),
    assertion(Report.status == passed),
    observer_calls(0).

test(trusted_verifier_exception_is_structured_and_not_success) :-
    verifier_exception_registry(Registry),
    always_spec(Input),
    freeze(Input, Registry, generic, 1, Frozen),
    supplied_host_observation(Frozen, Observation),
    spec_verify(Frozen, [Observation], Registry, ok(Report)),
    Report.requirements = [Result],
    assertion(Result.status = error(_)),
    assertion(Report.status == rejected).

test(trusted_verifier_timeout_is_structured_and_not_success) :-
    verifier_timeout_registry(Registry),
    always_spec(Input),
    freeze(Input, Registry, generic, 1, Frozen),
    supplied_host_observation(Frozen, Observation),
    spec_verify(Frozen, [Observation], Registry, ok(Report)),
    Report.requirements = [Result],
    assertion(Result.status = timeout(_)),
    assertion(Report.status == rejected).

/* Observe + Verify ----------------------------------------------------- */

test(project_kb_snapshot_k1_passes_without_source_parsing) :-
    project_registry(Registry),
    project_spec(Input),
    freeze(Input, Registry, api, 1, Frozen),
    project_snapshot(r1, K1),
    Sources = [project_kb(K1,[exports(foo,foo/1)])],
    spec_observe(Frozen, Sources, Registry, [], ok(Observations)),
    spec_verify(Frozen, Observations, Registry, ok(Report)),
    assertion(Report.status == passed).

test(project_kb_snapshot_k2_fails_same_frozen_spec) :-
    project_registry(Registry),
    project_spec(Input),
    freeze(Input, Registry, api, 1, Frozen),
    project_snapshot(r2, K2),
    Sources = [project_kb(K2,[])],
    spec_observe(Frozen, Sources, Registry, [], ok(Observations)),
    spec_verify(Frozen, Observations, Registry, ok(Report)),
    assertion(Report.status == rejected),
    Report.requirements = [Result],
    assertion(Result.status == failed).

test(non_software_dataset_uses_same_spec_verify_core) :-
    dataset_registry(Registry),
    dataset_spec(Input),
    freeze(Input, Registry, dataset, 1, Frozen),
    Sources = [dataset_snapshot(people, 4, dataset_revision(7))],
    spec_observe(Frozen, Sources, Registry, [], ok(Observations)),
    spec_verify(Frozen, Observations, Registry, ok(Report)),
    assertion(Report.status == passed).

test(observer_exception_is_structured_and_not_success) :-
    exception_registry(Registry),
    always_spec(Input),
    freeze(Input, Registry, generic, 1, Frozen),
    spec_observe(Frozen, [], Registry, [], ok([Observation])),
    assertion(Observation.status = error(_)),
    spec_verify(Frozen, [Observation], Registry, ok(Report)),
    assertion(Report.status == rejected).

test(observer_timeout_is_structured_and_not_success) :-
    timeout_registry(Registry),
    always_spec(Input),
    freeze(Input, Registry, generic, 1, Frozen),
    spec_observe(Frozen,
                 [],
                 Registry,
                 [observer_time_limit(0.001)],
                 ok([Observation])),
    assertion(Observation.status = timeout(_)),
    spec_verify(Frozen, [Observation], Registry, ok(Report)),
    assertion(Report.status == rejected).

test(observer_cancellation_is_structured_and_not_success) :-
    cancel_registry(Registry),
    always_spec(Input),
    freeze(Input, Registry, generic, 1, Frozen),
    spec_observe(Frozen, [], Registry, [], ok([Observation])),
    assertion(Observation.status == cancelled),
    spec_verify(Frozen, [Observation], Registry, ok(Report)),
    assertion(Report.status == rejected).

test(supplied_only_provider_reports_missing_when_observe_requested) :-
    no_observer_registry(Registry),
    always_spec(Input),
    freeze(Input, Registry, generic, 1, Frozen),
    spec_observe(Frozen, [], Registry, [], ok([Observation])),
    assertion(Observation.status == missing).

/* Coherence ------------------------------------------------------------ */

test(mixed_project_revisions_cannot_masquerade_as_one_verified_state) :-
    project_registry(Registry),
    project_spec(Input0),
    Input0.requirements = [Required],
    put_dict(id, Required, second_api, Second),
    put_dict(requirements, Input0, [Required,Second], Input),
    freeze(Input, Registry, api, 1, Frozen),
    Frozen.requirements = [Req1,Req2],
    project_snapshot(r1, K1),
    project_snapshot(r2, K2),
    project_state_ref(K1, R1),
    project_state_ref(K2, R2),
    project_observation_for_requirement(Req1, K1, passed, R1, Obs1),
    project_observation_for_requirement(Req2, K2, passed, R2, Obs2),
    spec_verify(Frozen, [Obs1,Obs2], Registry, ok(Report)),
    assertion(Report.status == rejected),
    forall(member(Result, Report.requirements),
           assertion(Result.status = stale(coherence_conflict(project,_)))).

/* Helpers used by tests ------------------------------------------------ */

supplied_host_observation(Frozen, Observation) :-
    Frozen.requirements = [Requirement],
    Observation = _{ requirement_id:Requirement.id,
                     assertion:Requirement.assertion,
                     status:passed,
                     value:true,
                     evidence_refs:[],
                     source_class:host,
                     trust_class:trusted,
                     provenance:_{source:test_observation},
                     verifier:Requirement.verifier,
                     collector:Requirement.collector,
                     snapshot:none,
                     freshness:current,
                     coherence:none,
                     state_ref:none
                   }.

project_observation_for_requirement(Requirement, Snapshot, Status, StateRef,
                                    Observation) :-
    Observation = _{ requirement_id:Requirement.id,
                     assertion:Requirement.assertion,
                     status:Status,
                     value:exports(foo,foo/1),
                     evidence_refs:[project_fact(foo,foo/1)],
                     source_class:project_kb,
                     trust_class:observed,
                     provenance:_{source:test_observation},
                     verifier:Requirement.verifier,
                     collector:Requirement.collector,
                     snapshot:Snapshot,
                     freshness:current,
                     coherence:project,
                     state_ref:StateRef
                   }.

:- end_tests(rlm_spec_verify).
