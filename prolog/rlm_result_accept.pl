:- module(rlm_result_accept,
          [ result_normalize/2,
            result_acceptance_policy_normalize/2,
            result_acceptance_policy_narrow/3,
            result_accept/4
          ]).

/** <module> Proof-carrying child result acceptance

Child completion and parent acceptance are deliberately different operations.
The child result is closed data. Artifact existence/freshness and required
verifier outcomes are supplied through trusted host runtime inputs; a child
cannot accept its own result by writing `verification:passed` into model data.
*/

:- use_module(library(lists)).
:- use_module(rlm_artifact, []).
:- use_module(rlm_closed_data, []).
:- use_module(rlm_evidence, []).

result_normalize(Input, Outcome) :-
    catch(( normalize_result(Input, Result),
            Outcome = ok(Result)
          ),
          Exception,
          result_exception(normalize, Exception, Outcome)).

result_acceptance_policy_normalize(Input, Outcome) :-
    catch(( normalize_policy(Input, Policy),
            Outcome = ok(Policy)
          ),
          Exception,
          result_exception(policy, Exception, Outcome)).

result_acceptance_policy_narrow(Parent0, Child0, Outcome) :-
    catch(( normalize_policy(Parent0, Parent),
            normalize_policy(Child0, Child),
            rlm_evidence:evidence_policy_narrow(Parent.evidence_policy,
                                                Child.evidence_policy,
                                                EvidenceOutcome),
            require_evidence_outcome(EvidenceOutcome, EvidencePolicy),
            bool_or(Parent.require_claim_evidence,
                    Child.require_claim_evidence,
                    RequireClaimEvidence),
            bool_or(Parent.require_current_evidence,
                    Child.require_current_evidence,
                    RequireCurrentEvidence),
            append(Parent.required_verifiers,
                   Child.required_verifiers,
                   Verifiers0),
            sort(Verifiers0, Verifiers),
            Policy = result_acceptance_policy{
                         evidence_policy:EvidencePolicy,
                         require_claim_evidence:RequireClaimEvidence,
                         require_current_evidence:RequireCurrentEvidence,
                         required_verifiers:Verifiers
                     },
            Outcome = ok(Policy)
          ),
          Exception,
          result_exception(policy_narrow, Exception, Outcome)).

result_accept(Result0, Policy0, Context0, Outcome) :-
    catch(( normalize_result(Result0, Result),
            normalize_policy(Policy0, Policy),
            normalize_context(Context0, Context),
            acceptance_reasons(Result, Policy, Context, Reasons),
            acceptance_outcome(Reasons, Result, Context, Outcome)
          ),
          Exception,
          result_exception(accept, Exception, Outcome)).

/* Result envelope ------------------------------------------------------ */

normalize_result(Input, Result) :-
    (   is_dict(Input)
    ->  allowed_keys(Input,
                     [task,status,value,claims,evidence_refs,provenance,
                      verification,usage,trace_ref],
                     result),
        require_key(Input, task, Task0),
        require_key(Input, status, Status),
        require_key(Input, value, Value0),
        require_key(Input, claims, Claims0),
        require_key(Input, evidence_refs, EvidenceRefs0),
        require_key(Input, provenance, Provenance0),
        require_key(Input, verification, Verification0),
        require_key(Input, usage, Usage0),
        require_key(Input, trace_ref, TraceRef0),
        require_result_status(Status),
        closed_value(Task0, Task),
        closed_value(Value0, Value),
        normalize_claims(Claims0, Claims),
        artifact_ref_list(EvidenceRefs0, evidence_refs, EvidenceRefs),
        require_unique_values(EvidenceRefs, duplicate_evidence_refs),
        closed_value(Provenance0, Provenance),
        closed_value(Verification0, Verification),
        closed_value(Usage0, Usage),
        closed_value(TraceRef0, TraceRef),
        Result = rrlm_result{
                     task:Task,
                     status:Status,
                     value:Value,
                     claims:Claims,
                     evidence_refs:EvidenceRefs,
                     provenance:Provenance,
                     verification:Verification,
                     usage:Usage,
                     trace_ref:TraceRef
                 }
    ;   throw(result_fault(invalid_result_shape(Input)))
    ).

require_result_status(Status) :-
    memberchk(Status, [completed,failed,cancelled]),
    !.
require_result_status(error(Detail)) :-
    closed_value(Detail, _),
    !.
require_result_status(timeout(Detail)) :-
    closed_value(Detail, _),
    !.
require_result_status(Status) :-
    throw(result_fault(invalid_result_status(Status))).

normalize_claims(Claims0, Claims) :-
    (   is_list(Claims0)
    ->  maplist(normalize_claim, Claims0, Claims),
        maplist(claim_id, Claims, Ids),
        require_unique_values(Ids, duplicate_claim_ids)
    ;   throw(result_fault(invalid_claims(Claims0)))
    ).

normalize_claim(Input, Claim) :-
    (   is_dict(Input)
    ->  allowed_keys(Input,
                     [id,value,provenance_class,evidence_refs],
                     claim),
        require_key(Input, id, Id),
        require_key(Input, value, Value0),
        require_key(Input, provenance_class, ProvenanceClass),
        require_key(Input, evidence_refs, EvidenceRefs0),
        require_name(Id, claim_id),
        require_provenance_class(ProvenanceClass),
        closed_value(Value0, Value),
        artifact_ref_list(EvidenceRefs0,
                          claim_evidence_refs,
                          EvidenceRefs),
        require_unique_values(EvidenceRefs,
                              duplicate_claim_evidence_refs(Id)),
        Claim = rrlm_claim{id:Id,
                           value:Value,
                           provenance_class:ProvenanceClass,
                           evidence_refs:EvidenceRefs}
    ;   throw(result_fault(invalid_claim(Input)))
    ).

claim_id(Claim, Claim.id).

artifact_ref_list(Input, Name, Refs) :-
    (   is_list(Input)
    ->  maplist(artifact_ref_value, Input, Refs)
    ;   throw(result_fault(invalid_list(Name, Input)))
    ).

artifact_ref_value(Ref, Ref) :-
    is_dict(Ref),
    ground(Ref),
    get_dict(namespace, Ref, Namespace),
    get_dict(key, Ref, Key),
    get_dict(version, Ref, Version),
    is_list(Namespace),
    ground(Namespace),
    atom(Key),
    Key \== '',
    integer(Version),
    Version > 0,
    !.
artifact_ref_value(Ref, _) :-
    throw(result_fault(invalid_artifact_ref(Ref))).

/* Host policy ---------------------------------------------------------- */

normalize_policy(default, Policy) :-
    !,
    rlm_evidence:evidence_policy_default(EvidencePolicy),
    Policy = result_acceptance_policy{
                 evidence_policy:EvidencePolicy,
                 require_claim_evidence:false,
                 require_current_evidence:false,
                 required_verifiers:[]
             }.
normalize_policy(Input, Policy) :-
    is_dict(Input),
    !,
    allowed_keys(Input,
                 [evidence_policy,require_claim_evidence,
                  require_current_evidence,required_verifiers],
                 result_acceptance_policy),
    dict_default(Input, evidence_policy, default, Evidence0),
    rlm_evidence:evidence_policy_normalize(Evidence0, EvidenceOutcome),
    require_evidence_outcome(EvidenceOutcome, Evidence),
    dict_default(Input, require_claim_evidence, false, RequireClaims),
    dict_default(Input, require_current_evidence, false, RequireCurrent),
    dict_default(Input, required_verifiers, [], Verifiers0),
    require_boolean(RequireClaims, require_claim_evidence),
    require_boolean(RequireCurrent, require_current_evidence),
    normalize_verifier_names(Verifiers0, Verifiers),
    Policy = result_acceptance_policy{
                 evidence_policy:Evidence,
                 require_claim_evidence:RequireClaims,
                 require_current_evidence:RequireCurrent,
                 required_verifiers:Verifiers
             }.
normalize_policy(Input, _) :-
    throw(result_fault(invalid_policy(Input))).

normalize_verifier_names(Names0, Names) :-
    (   is_list(Names0)
    ->  maplist(require_verifier_name, Names0, Checked),
        require_unique_values(Checked, duplicate_required_verifiers),
        sort(Checked, Names)
    ;   throw(result_fault(invalid_required_verifiers(Names0)))
    ).

require_verifier_name(Name, Name) :-
    require_name(Name, verifier).

/* Trusted acceptance context ----------------------------------------- */

normalize_context(Input, Context) :-
    (   is_dict(Input)
    ->  allowed_keys(Input,
                     [artifact_store,verifier_results],
                     result_acceptance_context),
        require_key(Input, artifact_store, Store),
        require_key(Input, verifier_results, Verifiers0),
        normalize_verifier_results(Verifiers0, Verifiers),
        Context = result_acceptance_context{
                      artifact_store:Store,
                      verifier_results:Verifiers
                  }
    ;   throw(result_fault(invalid_acceptance_context(Input)))
    ).

normalize_verifier_results(Results0, Results) :-
    (   is_list(Results0)
    ->  maplist(normalize_verifier_result, Results0, Results),
        maplist(verifier_name, Results, Names),
        require_unique_values(Names, duplicate_verifier_results)
    ;   throw(result_fault(invalid_verifier_results(Results0)))
    ).

normalize_verifier_result(Input, Result) :-
    (   is_dict(Input)
    ->  allowed_keys(Input,
                     [verifier,status,provenance_class,report_ref],
                     verifier_result),
        require_key(Input, verifier, Verifier),
        require_key(Input, status, Status),
        require_key(Input, provenance_class, ProvenanceClass),
        require_key(Input, report_ref, ReportRef0),
        require_name(Verifier, verifier),
        require_verifier_status(Status),
        require_trusted_verifier_provenance(ProvenanceClass),
        closed_value(ReportRef0, ReportRef),
        Result = verifier_result{verifier:Verifier,
                                 status:Status,
                                 provenance_class:ProvenanceClass,
                                 report_ref:ReportRef}
    ;   throw(result_fault(invalid_verifier_result(Input)))
    ).

verifier_name(Result, Result.verifier).

require_verifier_status(passed) :- !.
require_verifier_status(failed) :- !.
require_verifier_status(error(Detail)) :- closed_value(Detail, _), !.
require_verifier_status(timeout(Detail)) :- closed_value(Detail, _), !.
require_verifier_status(Status) :-
    throw(result_fault(invalid_verifier_status(Status))).

require_trusted_verifier_provenance(Class) :-
    memberchk(Class, [trusted_runtime,host_assertion,ci,solver]),
    !.
require_trusted_verifier_provenance(Class) :-
    throw(result_fault(untrusted_verifier_provenance(Class))).

/* Acceptance ----------------------------------------------------------- */

acceptance_reasons(Result, Policy, Context, Reasons) :-
    completion_reasons(Result.status, CompletionReasons),
    result_evidence_presence_reasons(Result.evidence_refs,
                                     Policy,
                                     PresenceReasons),
    claim_reasons(Result.claims,
                  Result.evidence_refs,
                  Policy,
                  ClaimReasons),
    evidence_reasons(Result.evidence_refs,
                     Policy,
                     Context.artifact_store,
                     EvidenceReasons),
    verifier_reasons(Policy.required_verifiers,
                     Context.verifier_results,
                     VerifierReasons),
    append([CompletionReasons,
            PresenceReasons,
            ClaimReasons,
            EvidenceReasons,
            VerifierReasons],
           Reasons0),
    sort(Reasons0, Reasons).

completion_reasons(completed, []) :- !.
completion_reasons(Status, [result_not_completed(Status)]).

result_evidence_presence_reasons([], Policy, [missing_result_evidence]) :-
    Policy.evidence_policy.required_evidence == true,
    !.
result_evidence_presence_reasons(_, _, []).

claim_reasons(Claims, DeclaredRefs, Policy, Reasons) :-
    findall(Reason,
            ( member(Claim, Claims),
              claim_reason(Claim, DeclaredRefs, Policy, Reason) ),
            Reasons0),
    sort(Reasons0, Reasons).

claim_reason(Claim, _, Policy, missing_claim_evidence(Claim.id)) :-
    Policy.require_claim_evidence == true,
    Claim.evidence_refs == [].
claim_reason(Claim, DeclaredRefs, _,
             claim_evidence_not_declared(Claim.id, Ref)) :-
    member(Ref, Claim.evidence_refs),
    \+ memberchk(Ref, DeclaredRefs).

evidence_reasons(Refs, Policy, Store, Reasons) :-
    findall(Reason,
            ( member(Ref, Refs),
              evidence_ref_reason(Store, Ref, Policy, Reason) ),
            Reasons0),
    sort(Reasons0, Reasons).

evidence_ref_reason(Store, Ref, Policy, Reason) :-
    rlm_artifact:artifact_ref_status(Store, Ref, StatusOutcome),
    evidence_status_reason(StatusOutcome,
                           Store,
                           Ref,
                           Policy,
                           Reason).

evidence_status_reason(error(_), _, Ref, _, missing_evidence_ref(Ref)) :- !.
evidence_status_reason(ok(missing(Ref)), _, Ref, _, missing_evidence_ref(Ref)) :- !.
evidence_status_reason(ok(missing_version(Ref, _)), _, Ref, _,
                       missing_evidence_ref(Ref)) :- !.
evidence_status_reason(ok(stale(Ref, Current)), _, Ref, Policy,
                       stale_evidence_ref(Ref, Current)) :-
    Policy.require_current_evidence == true,
    !.
evidence_status_reason(ok(Status), Store, Ref, Policy, Reason) :-
    artifact_freshness(Status, Freshness),
    rlm_artifact:artifact_get(Store, Ref, GetOutcome),
    artifact_observation(GetOutcome, Ref, Freshness, Observation),
    rlm_evidence:evidence_policy_accepts(Policy.evidence_policy,
                                         Observation,
                                         PolicyOutcome),
    evidence_policy_reason(PolicyOutcome, Ref, Reason).

artifact_freshness(current(_), current) :- !.
artifact_freshness(stale(_, _), stale) :- !.
artifact_freshness(_, unknown).

artifact_observation(ok(Artifact), Ref, Freshness, Observation) :-
    !,
    artifact_provenance_class(Artifact, ProvenanceClass),
    provenance_trust_class(ProvenanceClass, TrustClass),
    Observation = rlm_observation{
                      requirement_id:result_evidence,
                      assertion:artifact_ref(Ref),
                      status:passed,
                      value:Ref,
                      evidence_refs:[Ref],
                      source_class:ProvenanceClass,
                      trust_class:TrustClass,
                      provenance:Artifact.provenance,
                      verifier:verifier{id:result_acceptance,version:1},
                      collector:collector{id:artifact_store,version:1},
                      snapshot:none,
                      freshness:Freshness,
                      coherence:none,
                      state_ref:none
                  }.
artifact_observation(error(_), Ref, _, _) :-
    throw(result_fault(evidence_resolution_failed(Ref))).

artifact_provenance_class(Artifact, Class) :-
    (   is_dict(Artifact.provenance),
        get_dict(provenance_class, Artifact.provenance, Found),
        rlm_evidence:provenance_class(Found)
    ->  Class = Found
    ;   Class = unresolved
    ).

provenance_trust_class(trusted_runtime, trusted).
provenance_trust_class(host_assertion, trusted).
provenance_trust_class(ci, trusted).
provenance_trust_class(solver, trusted).
provenance_trust_class(external_observation, observed).
provenance_trust_class(research_source, observed).
provenance_trust_class(project_kb, observed).
provenance_trust_class(model_claim, model_claim).
provenance_trust_class(derived_claim, derived).
provenance_trust_class(unresolved, unresolved).

evidence_policy_reason(ok(accepted), _, _) :-
    !,
    fail.
evidence_policy_reason(ok(rejected(Failures)), Ref,
                       evidence_policy_rejected(Ref, Failures)) :- !.
evidence_policy_reason(error(Error), Ref,
                       evidence_policy_error(Ref, Error)).

verifier_reasons(Required, Results, Reasons) :-
    findall(Reason,
            ( member(Verifier, Required),
              verifier_reason(Verifier, Results, Reason) ),
            Reasons).

verifier_reason(Verifier, Results, missing_required_verifier(Verifier)) :-
    \+ ( member(Result, Results), Result.verifier == Verifier ),
    !.
verifier_reason(Verifier, Results, verifier_not_passed(Verifier, Status)) :-
    member(Result, Results),
    Result.verifier == Verifier,
    Status = Result.status,
    Status \== passed.

acceptance_outcome([], Result, Context,
                   ok(result_acceptance{
                          status:accepted,
                          result:Result,
                          evidence_refs:Result.evidence_refs,
                          verifiers:Context.verifier_results
                      })) :- !.
acceptance_outcome(Reasons, _, _,
                   error(result_acceptance_error{
                             phase:accept,
                             kind:rejected,
                             reasons:Reasons,
                             message:"child result did not satisfy host acceptance policy"
                         })).

/* Closed-data helpers -------------------------------------------------- */

closed_value(Input, Value) :-
    catch(rlm_closed_data:closed_data_normalize(Input, Value),
          Exception,
          throw(result_fault(closed_data(Exception)))).

require_unique_values(Values, _Fault) :-
    sort(Values, Unique),
    length(Values, Count),
    length(Unique, Count),
    !.
require_unique_values(_, Fault) :-
    throw(result_fault(Fault)).

allowed_keys(Dict, Allowed, Name) :-
    dict_pairs(Dict, _, Pairs),
    forall(member(Key-_, Pairs),
           ( memberchk(Key, Allowed)
           -> true
           ; throw(result_fault(unknown_key(Name, Key)))
           )).

require_key(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(result_fault(missing_key(Key)))
    ).

dict_default(Dict, Key, Default, Value) :-
    ( get_dict(Key, Dict, Found) -> Value = Found ; Value = Default ).

require_name(Value, _) :- atom(Value), Value \== '', !.
require_name(Value, Name) :- throw(result_fault(invalid_name(Name, Value))).

require_boolean(Value, _) :- memberchk(Value, [true,false]), !.
require_boolean(Value, Name) :-
    throw(result_fault(invalid_boolean(Name, Value))).

require_provenance_class(Class) :-
    rlm_evidence:provenance_class(Class),
    !.
require_provenance_class(Class) :-
    throw(result_fault(invalid_provenance_class(Class))).

require_evidence_outcome(ok(Value), Value) :- !.
require_evidence_outcome(error(Error), _) :-
    throw(result_fault(evidence_policy(Error))).

bool_or(true, _, true) :- !.
bool_or(_, true, true) :- !.
bool_or(false, false, false).

result_exception(Phase, result_fault(Detail), error(Error)) :-
    !,
    error_kind(Phase, Kind),
    Error = result_acceptance_error{phase:Phase,
                                    kind:Kind,
                                    detail:Detail,
                                    message:"result acceptance contract rejected input"}.
result_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = result_acceptance_error{phase:Phase,
                                    kind:exception,
                                    exception:Safe,
                                    message:"result acceptance operation raised an exception"}.

error_kind(normalize, invalid_result) :- !.
error_kind(_, invalid_input).
