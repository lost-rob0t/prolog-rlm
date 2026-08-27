:- begin_tests(rlm_result_accept).

:- use_module('../prolog/rlm_artifact').
:- use_module('../prolog/rlm_result_accept').

:- meta_predicate with_result_store(1).

with_result_store(Goal) :-
    setup_call_cleanup(
        artifact_store_open(memory, ok(Store)),
        call(Goal, Store),
        artifact_store_close(Store, _)).

put_evidence(Store, Key, ProvenanceClass, Artifact) :-
    artifact_put(Store,
                 [result, acceptance],
                 Key,
                 evidence,
                 _{fact:Key},
                 _{provenance_class:ProvenanceClass,
                   producer:test},
                 ok(Artifact)).

base_result(EvidenceRef, Result) :-
    Result = rrlm_result{
                 task:task_56,
                 status:completed,
                 value:_{answer:42},
                 claims:[rrlm_claim{
                             id:answer,
                             value:42,
                             provenance_class:derived_claim,
                             evidence_refs:[EvidenceRef]
                         }],
                 evidence_refs:[EvidenceRef],
                 provenance:_{producer:child_1,
                              provenance_class:model_claim},
                 verification:_{proposed:[solver_check]},
                 usage:_{model_calls:1,total_tokens:10},
                 trace_ref:trace(child_1, 1)
             }.

base_policy(Policy) :-
    Policy = result_acceptance_policy{
                 evidence_policy:_{required_evidence:true,
                                   source_classes:all,
                                   trust_classes:all,
                                   freshness:current,
                                   coherence:none,
                                   state_ref:any},
                 require_claim_evidence:true,
                 require_current_evidence:true,
                 required_verifiers:[solver_check]
             }.

trusted_context(Store, Verifiers, Context) :-
    Context = result_acceptance_context{
                  artifact_store:Store,
                  verifier_results:Verifiers
              }.

passed_verifier(Name,
                verifier_result{verifier:Name,
                                status:passed,
                                provenance_class:trusted_runtime,
                                report_ref:verifier_report(Name, 1)}).

failed_verifier(Name,
                verifier_result{verifier:Name,
                                status:failed,
                                provenance_class:trusted_runtime,
                                report_ref:verifier_report(Name, 1)}).

timeout_verifier(Name,
                 verifier_result{verifier:Name,
                                 status:timeout(deadline),
                                 provenance_class:trusted_runtime,
                                 report_ref:verifier_report(Name, 1)}).

error_verifier(Name,
               verifier_result{verifier:Name,
                               status:error(crashed),
                               provenance_class:trusted_runtime,
                               report_ref:verifier_report(Name, 1)}).

test(valid_result_accepts_with_current_artifact_and_host_verifier) :-
    with_result_store(valid_accept_case).

valid_accept_case(Store) :-
    put_evidence(Store, observed_fact, external_observation, Artifact),
    base_result(Artifact.ref, Result),
    base_policy(Policy),
    passed_verifier(solver_check, Verifier),
    trusted_context(Store, [Verifier], Context),
    result_accept(Result, Policy, Context, ok(Accepted)),
    assertion(Accepted.status == accepted),
    assertion(Accepted.result.task == task_56),
    assertion(Accepted.evidence_refs == [Artifact.ref]),
    assertion(Accepted.verifiers == [Verifier]).

test(noncompleted_child_can_never_be_accepted) :-
    with_result_store(noncompleted_case).

noncompleted_case(Store) :-
    put_evidence(Store, observed_fact, external_observation, Artifact),
    base_result(Artifact.ref, Result0),
    put_dict(status, Result0, failed, Result),
    base_policy(Policy),
    passed_verifier(solver_check, Verifier),
    trusted_context(Store, [Verifier], Context),
    result_accept(Result, Policy, Context, error(Error)),
    assertion(Error.kind == rejected),
    assertion(member(result_not_completed(failed), Error.reasons)).

test(missing_claim_evidence_rejects) :-
    with_result_store(missing_claim_evidence_case).

missing_claim_evidence_case(Store) :-
    put_evidence(Store, observed_fact, external_observation, Artifact),
    base_result(Artifact.ref, Result0),
    Result0.claims = [Claim0],
    put_dict(evidence_refs, Claim0, [], Claim),
    put_dict(claims, Result0, [Claim], Result),
    base_policy(Policy),
    passed_verifier(solver_check, Verifier),
    trusted_context(Store, [Verifier], Context),
    result_accept(Result, Policy, Context, error(Error)),
    assertion(Error.kind == rejected),
    assertion(member(missing_claim_evidence(answer), Error.reasons)).

test(claim_evidence_must_be_declared_in_result_envelope) :-
    with_result_store(undeclared_claim_ref_case).

undeclared_claim_ref_case(Store) :-
    put_evidence(Store, declared, external_observation, Declared),
    put_evidence(Store, undeclared, external_observation, Undeclared),
    base_result(Declared.ref, Result0),
    Result0.claims = [Claim0],
    put_dict(evidence_refs, Claim0, [Undeclared.ref], Claim),
    put_dict(claims, Result0, [Claim], Result),
    base_policy(Policy),
    passed_verifier(solver_check, Verifier),
    trusted_context(Store, [Verifier], Context),
    result_accept(Result, Policy, Context, error(Error)),
    assertion(Error.kind == rejected),
    assertion(member(claim_evidence_not_declared(answer, Undeclared.ref),
                     Error.reasons)).

test(stale_artifact_ref_rejects) :-
    with_result_store(stale_ref_case).

stale_ref_case(Store) :-
    put_evidence(Store, observed_fact, external_observation, V1),
    put_evidence(Store, observed_fact, external_observation, _V2),
    base_result(V1.ref, Result),
    base_policy(Policy),
    passed_verifier(solver_check, Verifier),
    trusted_context(Store, [Verifier], Context),
    result_accept(Result, Policy, Context, error(Error)),
    assertion(Error.kind == rejected),
    assertion(member(stale_evidence_ref(V1.ref, _), Error.reasons)).

test(missing_artifact_ref_rejects) :-
    with_result_store(missing_ref_case).

missing_ref_case(Store) :-
    Missing = artifact_ref{namespace:[result, acceptance],
                           key:missing,
                           version:1},
    base_result(Missing, Result),
    base_policy(Policy),
    passed_verifier(solver_check, Verifier),
    trusted_context(Store, [Verifier], Context),
    result_accept(Result, Policy, Context, error(Error)),
    assertion(Error.kind == rejected),
    assertion(member(missing_evidence_ref(Missing), Error.reasons)).

test(model_claim_artifact_cannot_satisfy_observed_evidence_policy) :-
    with_result_store(proof_laundering_case).

proof_laundering_case(Store) :-
    put_evidence(Store, model_fact, model_claim, Artifact),
    base_result(Artifact.ref, Result),
    base_policy(Policy0),
    Evidence = _{required_evidence:true,
                 source_classes:all,
                 trust_classes:[observed],
                 freshness:current,
                 coherence:none,
                 state_ref:any},
    put_dict(evidence_policy, Policy0, Evidence, Policy),
    passed_verifier(solver_check, Verifier),
    trusted_context(Store, [Verifier], Context),
    result_accept(Result, Policy, Context, error(Error)),
    assertion(Error.kind == rejected),
    assertion(member(evidence_policy_rejected(Artifact.ref,
                                               [not_allowed(model_claim,
                                                            [observed])]),
                     Error.reasons)).

test(model_proposed_verification_cannot_replace_host_verifier_result) :-
    with_result_store(model_verifier_laundering_case).

model_verifier_laundering_case(Store) :-
    put_evidence(Store, observed_fact, external_observation, Artifact),
    base_result(Artifact.ref, Result),
    base_policy(Policy),
    trusted_context(Store, [], Context),
    result_accept(Result, Policy, Context, error(Error)),
    assertion(Error.kind == rejected),
    assertion(member(missing_required_verifier(solver_check), Error.reasons)).

test(verifier_failed_error_and_timeout_remain_distinct,
     [forall(member(Constructor-Expected,
                    [failed_verifier-failed,
                     error_verifier-error(crashed),
                     timeout_verifier-timeout(deadline)]))]) :-
    with_result_store(verifier_terminal_case(Constructor, Expected)).

verifier_terminal_case(Constructor, Expected, Store) :-
    put_evidence(Store, observed_fact, external_observation, Artifact),
    base_result(Artifact.ref, Result),
    base_policy(Policy),
    Goal =.. [Constructor, solver_check, Verifier],
    call(Goal),
    trusted_context(Store, [Verifier], Context),
    result_accept(Result, Policy, Context, error(Error)),
    assertion(Error.kind == rejected),
    assertion(member(verifier_not_passed(solver_check, Expected), Error.reasons)).

test(policy_narrowing_cannot_waive_parent_verifier_or_evidence) :-
    base_policy(Parent0),
    ParentEvidence = _{required_evidence:true,
                       source_classes:all,
                       trust_classes:[observed],
                       freshness:current,
                       coherence:none,
                       state_ref:any},
    put_dict(evidence_policy, Parent0, ParentEvidence, Parent),
    Child0 = result_acceptance_policy{
                 evidence_policy:default,
                 require_claim_evidence:false,
                 require_current_evidence:false,
                 required_verifiers:[]
             },
    result_acceptance_policy_narrow(Parent, Child0, ok(Child)),
    assertion(Child.require_claim_evidence == true),
    assertion(Child.require_current_evidence == true),
    assertion(Child.required_verifiers == [solver_check]),
    assertion(Child.evidence_policy.trust_classes == [observed]),
    assertion(Child.evidence_policy.freshness == current).

test(duplicate_claim_ids_are_structured_failure) :-
    Claim = rrlm_claim{id:duplicate,
                       value:1,
                       provenance_class:model_claim,
                       evidence_refs:[]},
    Result = rrlm_result{task:task_56,
                         status:completed,
                         value:none,
                         claims:[Claim, Claim],
                         evidence_refs:[],
                         provenance:_{},
                         verification:_{},
                         usage:_{},
                         trace_ref:none},
    result_normalize(Result, error(Error)),
    assertion(Error.kind == invalid_result),
    assertion(Error.detail == duplicate_claim_ids).

test(nonground_result_is_structured_failure) :-
    Result = rrlm_result{task:task_56,
                         status:completed,
                         value:_ModelVariable,
                         claims:[],
                         evidence_refs:[],
                         provenance:_{},
                         verification:_{},
                         usage:_{},
                         trace_ref:none},
    result_normalize(Result, error(Error)),
    assertion(Error.kind == invalid_result).

:- end_tests(rlm_result_accept).
