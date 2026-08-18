:- module(rlm_verify,
          [ rlm_verify_ready/0,
            spec_verify/4,
            spec_observe_async/5,
            spec_observe/5,
            spec_observe_execute/5
          ]).

/** <module> Pure specification verification and separate observation collection

spec_verify/4 is deterministic reconciliation over already supplied evidence.
It may invoke the trusted pure evaluator bound by the assertion registry, but it
never collects evidence or calls assertion validators, observer closures, tools,
filesystems, processes, networks, or effectful providers. Evidence collection is
a separate operation. Blocking collectors use the shared rlm_async scheduler;
purely local collectors may execute directly through the same execute predicate.
*/

:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(time)).
:- use_module(rlm_async, []).
:- use_module(rlm_assertion).
:- use_module(rlm_evidence).
:- use_module(rlm_spec).

rlm_verify_ready.

spec_verify(Frozen0, Observations0, Registry, Outcome) :-
    catch(( validate_frozen(Frozen0, Frozen),
            require_observation_list(Observations0),
            maplist(normalize_observation_or_throw,
                    Observations0,
                    Observations),
            observation_ids(Observations, ObservationIds),
            require_unique(ObservationIds, observation_requirement_id),
            assertion_registry_validate(Registry, RegistryOutcome),
            require_assertion_outcome(RegistryOutcome, NormalizedRegistry),
            maplist(verify_requirement(Observations, NormalizedRegistry),
                    Frozen.requirements,
                    Results0),
            enforce_coherence(Results0, Results),
            report_status(Results, Status),
            report_evidence_refs(Results, EvidenceRefs),
            Report = verification_report{
                         spec_ref:Frozen.ref,
                         status:Status,
                         requirements:Results,
                         observations:Observations,
                         evidence_refs:EvidenceRefs,
                         provenance:verification_provenance{
                                        verifier:rlm_verify,
                                        version:1,
                                        mode:pure
                                    }
                     },
            Outcome = ok(Report)
          ),
          Exception,
          verify_exception(verify, Exception, Outcome)).

/* Collection ----------------------------------------------------------- */

spec_observe_async(Frozen0, Sources, Registry, Options, Future) :-
    validate_frozen(Frozen0, Frozen),
    require_ground(Sources, observation_sources),
    require_options(Options),
    Fingerprint = Frozen.ref.fingerprint,
    Metadata = async_metadata{operation:spec_observe,
                              spec_fingerprint:Fingerprint},
    rlm_async:rlm_async_submit(
        rlm_verify:spec_observe_execute(Frozen,
                                        Sources,
                                        Registry,
                                        Options),
        Metadata,
        Future).

spec_observe(Frozen0, Sources, Registry, Options, Outcome) :-
    catch(( validate_frozen(Frozen0, Frozen),
            require_ground(Sources, observation_sources),
            require_options(Options),
            (   all_collectors_pure(Frozen, Registry)
            ->  spec_observe_execute(Frozen,
                                     Sources,
                                     Registry,
                                     Options,
                                     Outcome)
            ;   spec_observe_async(Frozen,
                                   Sources,
                                   Registry,
                                   Options,
                                   Future),
                setup_call_cleanup(
                    true,
                    rlm_async:rlm_future_await(Future, Outcome),
                    rlm_async:rlm_future_destroy(Future))
            )
          ),
          Exception,
          verify_exception(observe, Exception, Outcome)).

spec_observe_execute(Frozen0, Sources, Registry, Options, Outcome) :-
    catch(( validate_frozen(Frozen0, Frozen),
            require_ground(Sources, observation_sources),
            require_options(Options),
            assertion_registry_validate(Registry, RegistryOutcome),
            require_assertion_outcome(RegistryOutcome, NormalizedRegistry),
            maplist(collect_requirement(Sources,
                                        NormalizedRegistry,
                                        Options),
                    Frozen.requirements,
                    Observations),
            Outcome = ok(Observations)
          ),
          Exception,
          verify_exception(observe_execute, Exception, Outcome)).

all_collectors_pure(Frozen, Registry) :-
    assertion_registry_validate(Registry, ok(Normalized)),
    forall(member(Requirement, Frozen.requirements),
           ( resolve_requirement_provider(Normalized, Requirement, Provider),
             Provider.latency == pure
           )).

collect_requirement(Sources, Registry, Options, Requirement, Observation) :-
    (   catch(resolve_requirement_provider(Registry, Requirement, Provider),
              Exception,
              provider_resolution_observation(Requirement,
                                              Exception,
                                              Observation))
    ->  (   var(Observation)
        ->  collect_with_provider(Provider,
                                  Requirement,
                                  Sources,
                                  Options,
                                  Observation)
        ;   true
        )
    ;   provider_resolution_observation(Requirement,
                                        provider_resolution_failed,
                                        Observation)
    ).

collect_with_provider(Provider, Requirement, _, _, Observation) :-
    Provider.observer == none,
    !,
    observation_from_status(Requirement,
                            Provider,
                            missing,
                            observer_unavailable,
                            Observation).
collect_with_provider(Provider, Requirement, Sources, Options, Observation) :-
    option(observer_time_limit(TimeLimit), Options, 5.0),
    require_positive_number(TimeLimit, observer_time_limit),
    catch(call_observer_bounded(TimeLimit,
                                Provider.observer,
                                Requirement,
                                Sources,
                                Options,
                                RawResult),
          Exception,
          observer_exception_result(Exception, RawResult)),
    observation_from_raw(RawResult, Provider, Requirement, Observation).

call_observer_bounded(TimeLimit,
                      Observer,
                      Requirement,
                      Sources,
                      Options,
                      RawResult) :-
    call_with_time_limit(
        TimeLimit,
        ( call(Observer, Requirement, Sources, Options, Raw)
        -> RawResult = returned(Raw)
        ;  RawResult = observer_failed
        )).

observer_exception_result(time_limit_exceeded, timeout) :- !.
observer_exception_result(time_limit_exceeded(_), timeout) :- !.
observer_exception_result(rlm_cancelled(Reason), cancelled(Reason)) :- !.
observer_exception_result(graph_cancelled(Reason), cancelled(Reason)) :- !.
observer_exception_result(Exception, error(Exception)).

observation_from_raw(returned(Raw0), Provider, Requirement, Observation) :-
    !,
    normalize_observer_payload(Raw0, Raw),
    Base = _{ requirement_id:Requirement.id,
              assertion:Requirement.assertion,
              verifier:Provider.verifier,
              collector:Provider.collector
            },
    put_dict(Raw, Base, Input),
    observation_normalize(Input, ObservationOutcome),
    require_evidence_outcome(ObservationOutcome, Observation).
observation_from_raw(observer_failed, Provider, Requirement, Observation) :-
    !,
    observation_from_status(Requirement,
                            Provider,
                            error(observer_failed),
                            observer_failed,
                            Observation).
observation_from_raw(timeout, Provider, Requirement, Observation) :-
    !,
    observation_from_status(Requirement,
                            Provider,
                            timeout(observer_time_limit),
                            observer_timeout,
                            Observation).
observation_from_raw(cancelled(Reason), Provider, Requirement, Observation) :-
    !,
    observation_from_status(Requirement,
                            Provider,
                            cancelled,
                            cancelled(Reason),
                            Observation).
observation_from_raw(error(Exception), Provider, Requirement, Observation) :-
    safe_term(Exception, Safe),
    observation_from_status(Requirement,
                            Provider,
                            error(Safe),
                            observer_exception,
                            Observation).

normalize_observer_payload(Input, Payload) :-
    is_dict(Input),
    !,
    allowed_observer_keys(Input),
    require_dict_key(Input, status, _),
    require_dict_key(Input, source_class, _),
    require_dict_key(Input, trust_class, _),
    Payload = Input.
normalize_observer_payload(Input, _) :-
    throw(verify_fault(invalid_observer_payload(Input))).

allowed_observer_keys(Input) :-
    dict_pairs(Input, _, Pairs),
    Allowed = [status,value,evidence_refs,source_class,trust_class,
               provenance,snapshot,freshness,coherence,state_ref],
    forall(member(Key-_, Pairs),
           ( memberchk(Key, Allowed)
           -> true
           ; throw(verify_fault(observer_identity_override(Key)))
           )).

observation_from_status(Requirement, Provider, Status, Reason, Observation) :-
    Input = _{ requirement_id:Requirement.id,
               assertion:Requirement.assertion,
               status:Status,
               value:none,
               evidence_refs:[],
               source_class:observer_control,
               trust_class:unresolved,
               provenance:_{reason:Reason},
               verifier:Provider.verifier,
               collector:Provider.collector,
               snapshot:none,
               freshness:unknown,
               coherence:none,
               state_ref:none
             },
    observation_normalize(Input, ObservationOutcome),
    require_evidence_outcome(ObservationOutcome, Observation).

provider_resolution_observation(Requirement, Exception, Observation) :-
    fallback_provider(Provider),
    safe_term(Exception, Safe),
    observation_from_status(Requirement,
                            Provider,
                            error(provider_resolution(Safe)),
                            provider_resolution,
                            Observation).

fallback_provider(assertion_provider{
                      verifier:verifier{id:unresolved,version:0},
                      collector:collector{id:unresolved,version:0},
                      observer:none,
                      latency:pure}).

/* Pure reconciliation -------------------------------------------------- */

verify_requirement(Observations, Registry, Requirement, Result) :-
    provider_compatibility(Registry, Requirement, ProviderCheck),
    observation_for_requirement(Observations,
                                Requirement.id,
                                ObservationOutcome),
    requirement_result(ProviderCheck,
                       ObservationOutcome,
                       Requirement,
                       Result).

provider_compatibility(Registry, Requirement, Outcome) :-
    catch(( resolve_requirement_provider(Registry, Requirement, Provider),
            (   Provider.verifier == Requirement.verifier,
                Provider.collector == Requirement.collector,
                Provider.verify_time_limit =:= Requirement.verify_time_limit
            ->  Outcome = ok(Provider)
            ;   Outcome = mismatch(registry_identity{
                                       expected_verifier:Requirement.verifier,
                                       actual_verifier:Provider.verifier,
                                       expected_collector:Requirement.collector,
                                       actual_collector:Provider.collector,
                                       expected_verify_time_limit:Requirement.verify_time_limit,
                                       actual_verify_time_limit:Provider.verify_time_limit
                                   })
            )
          ),
          Exception,
          ( safe_term(Exception, Safe), Outcome = error(Safe) )).

observation_for_requirement(Observations, Id, found(Observation)) :-
    member(Observation, Observations),
    Observation.requirement_id == Id,
    !.
observation_for_requirement(_, _, missing).

requirement_result(mismatch(Detail), _, Requirement, Result) :-
    !,
    base_requirement_result(Requirement,
                            indeterminate(registry_verifier_mismatch(Detail)),
                            none,
                            Result).
requirement_result(error(Detail), _, Requirement, Result) :-
    !,
    base_requirement_result(Requirement,
                            error(registry_resolution(Detail)),
                            none,
                            Result).
requirement_result(ok(_), missing, Requirement, Result) :-
    !,
    base_requirement_result(Requirement, missing, none, Result).
requirement_result(ok(Provider), found(Observation), Requirement, Result) :-
    (   Observation.assertion \== Requirement.assertion
    ->  Status = indeterminate(assertion_mismatch)
    ;   Observation.verifier \== Requirement.verifier
    ->  Status = indeterminate(verifier_mismatch(
                                    Requirement.verifier,
                                    Observation.verifier))
    ;   Observation.collector \== Requirement.collector
    ->  Status = indeterminate(collector_mismatch(
                                    Requirement.collector,
                                    Observation.collector))
    ;   Observation.status \== passed
    ->  Status = Observation.status
    ;   evidence_policy_accepts(Requirement.evidence_policy,
                                Observation,
                                PolicyOutcome),
        policy_evaluation_status(PolicyOutcome,
                                 Provider,
                                 Requirement,
                                 Observation,
                                 Status)
    ),
    base_requirement_result(Requirement, Status, Observation, Result).

policy_evaluation_status(ok(accepted), Provider, Requirement, Observation, Status) :-
    !,
    run_trusted_evaluator(Provider, Requirement, Observation, Status).
policy_evaluation_status(ok(rejected(Failures)), _, _, _, Status) :-
    !,
    policy_failure_status(Failures, Status).
policy_evaluation_status(error(Error), _, _, _, error(evidence_policy(Error))).

run_trusted_evaluator(Provider, Requirement, Observation, Status) :-
    TimeLimit = Requirement.verify_time_limit,
    catch(call_evaluator_bounded(TimeLimit,
                                 Provider.evaluator,
                                 Requirement.assertion,
                                 Observation,
                                 Status0),
          Exception,
          evaluator_exception_status(Exception, Status0)),
    normalize_evaluation_status(Status0, Status).

call_evaluator_bounded(TimeLimit, Evaluator, Assertion, Observation, Status) :-
    call_with_time_limit(
        TimeLimit,
        ( call(Evaluator, Assertion, Observation, Raw)
        -> Status = Raw
        ;  Status = error(verifier_failed)
        )).

evaluator_exception_status(time_limit_exceeded, timeout(verifier_time_limit)) :- !.
evaluator_exception_status(time_limit_exceeded(_), timeout(verifier_time_limit)) :- !.
evaluator_exception_status(rlm_cancelled(Reason), cancelled(Reason)) :- !.
evaluator_exception_status(graph_cancelled(Reason), cancelled(Reason)) :- !.
evaluator_exception_status(Exception, error(Safe)) :- safe_term(Exception, Safe).

normalize_evaluation_status(passed, passed) :- !.
normalize_evaluation_status(failed, failed) :- !.
normalize_evaluation_status(cancelled(Reason), cancelled) :-
    ground(Reason),
    !.
normalize_evaluation_status(timeout(Detail), timeout(Detail)) :- ground(Detail), !.
normalize_evaluation_status(error(Detail), error(Detail)) :- ground(Detail), !.
normalize_evaluation_status(indeterminate(Detail), indeterminate(Detail)) :-
    ground(Detail),
    !.
normalize_evaluation_status(Status, error(invalid_verifier_result(Status))).

policy_failure_status(Failures, stale(policy_rejected(Failures))) :-
    member(Failure, Failures),
    policy_staleness_failure(Failure),
    !.
policy_failure_status(Failures, indeterminate(policy_rejected(Failures))).

policy_staleness_failure(stale_or_unknown(_)).
policy_staleness_failure(state_ref_mismatch(_, _)).
policy_staleness_failure(coherence_mismatch(_, _)).

base_requirement_result(Requirement, Status, Observation,
                        verification_requirement{
                            id:Requirement.id,
                            assertion:Requirement.assertion,
                            severity:Requirement.severity,
                            evidence_policy:Requirement.evidence_policy,
                            verifier:Requirement.verifier,
                            collector:Requirement.collector,
                            status:Status,
                            observation:Observation,
                            evidence_refs:EvidenceRefs,
                            provenance:Requirement.provenance
                        }) :-
    observation_evidence_refs(Observation, EvidenceRefs).

observation_evidence_refs(none, []) :- !.
observation_evidence_refs(Observation, Refs) :-
    Refs = Observation.evidence_refs.

/* Coherence ------------------------------------------------------------ */

enforce_coherence(Results0, Results) :-
    coherence_conflicts(Results0, Conflicts),
    maplist(apply_coherence_conflicts(Conflicts), Results0, Results).

coherence_conflicts(Results, Conflicts) :-
    findall(Scope,
            ( member(Result, Results),
              Scope = Result.evidence_policy.coherence,
              Scope \== none ),
            Scopes0),
    sort(Scopes0, Scopes),
    findall(conflict(Scope, Refs),
            ( member(Scope, Scopes),
              coherence_refs(Results, Scope, Refs0),
              sort(Refs0, Refs),
              ( memberchk(none, Refs) ; length(Refs, Count), Count > 1 )
            ),
            Conflicts).

coherence_refs(Results, Scope, Refs) :-
    findall(Ref,
            ( member(Result, Results),
              Result.evidence_policy.coherence == Scope,
              Result.status == passed,
              Result.observation \== none,
              Ref = Result.observation.state_ref ),
            Refs).

apply_coherence_conflicts(Conflicts, Result0, Result) :-
    Scope = Result0.evidence_policy.coherence,
    member(conflict(Scope, Refs), Conflicts),
    Result0.status == passed,
    !,
    put_dict(status,
             Result0,
             stale(coherence_conflict(Scope, Refs)),
             Result).
apply_coherence_conflicts(_, Result, Result).

report_status(Results, passed) :-
    forall(( member(Result, Results), Result.severity == required ),
           Result.status == passed),
    !.
report_status(_, rejected).

report_evidence_refs(Results, Refs) :-
    findall(Ref,
            ( member(Result, Results),
              member(Ref, Result.evidence_refs) ),
            Refs0),
    sort(Refs0, Refs).

/* Registry helpers ----------------------------------------------------- */

resolve_requirement_provider(Registry, Requirement, Provider) :-
    Kind = Requirement.assertion.kind,
    Version = Requirement.assertion.schema_version,
    member(Provider, Registry),
    Provider.kind == Kind,
    Provider.schema_version =:= Version,
    !.
resolve_requirement_provider(_, Requirement, _) :-
    throw(verify_fault(unknown_provider(Requirement.assertion.kind,
                                       Requirement.assertion.schema_version))).

/* Validation ----------------------------------------------------------- */

validate_frozen(Frozen0, Frozen) :-
    spec_fingerprint(Frozen0, Fingerprint),
    require_hash(Fingerprint),
    Frozen = Frozen0.

normalize_observation_or_throw(Input, Observation) :-
    observation_normalize(Input, Outcome),
    require_evidence_outcome(Outcome, Observation).

require_observation_list(Observations) :- is_list(Observations), !.
require_observation_list(Value) :- throw(verify_fault(invalid_observations(Value))).

observation_ids(Observations, Ids) :-
    findall(Id,
            ( member(Observation, Observations), Id = Observation.requirement_id ),
            Ids).

require_unique(Values, _) :-
    sort(Values, Unique),
    length(Values, Count),
    length(Unique, Count),
    !.
require_unique(Values, Kind) :- throw(verify_fault(duplicate(Kind, Values))).

require_options(Options) :- is_list(Options), !.
require_options(Options) :- throw(verify_fault(invalid_options(Options))).

require_ground(Value, _) :- ground(Value), !.
require_ground(Value, Name) :- throw(verify_fault(non_ground(Name, Value))).

require_positive_number(Value, _) :- number(Value), Value > 0, !.
require_positive_number(Value, Name) :-
    throw(verify_fault(invalid_positive_number(Name, Value))).

require_hash(Hash) :- atom(Hash), !.
require_hash(Hash) :- throw(verify_fault(invalid_spec_fingerprint(Hash))).

require_dict_key(Dict, Key, Value) :-
    ( get_dict(Key, Dict, Value) -> true ; throw(verify_fault(missing_key(Key))) ).

require_assertion_outcome(ok(Value), Value) :- !.
require_assertion_outcome(error(Error), _) :- throw(verify_fault(assertion(Error))).

require_evidence_outcome(ok(Value), Value) :- !.
require_evidence_outcome(error(Error), _) :- throw(verify_fault(evidence(Error))).

safe_term(Term, Safe) :-
    term_string(Term, Safe, [quoted(true), numbervars(true)]).

verify_exception(Phase, verify_fault(Detail), error(Error)) :-
    !,
    Error = verification_error{phase:Phase,
                               kind:verification_error,
                               detail:Detail,
                               message:"verification operation rejected input"}.
verify_exception(Phase, Exception, error(Error)) :-
    safe_term(Exception, Safe),
    Error = verification_error{phase:Phase,
                               kind:exception,
                               exception:Safe,
                               message:"verification operation raised an exception"}.
