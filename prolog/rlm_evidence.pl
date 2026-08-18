:- module(rlm_evidence,
          [ rlm_evidence_ready/0,
            evidence_policy_default/1,
            evidence_policy_normalize/2,
            evidence_policy_narrow/3,
            evidence_policy_accepts/3,
            observation_normalize/2,
            observation_status_success/1,
            observation_status_terminal/1,
            provenance_class/1,
            trust_class/1
          ]).

/** <module> Shared evidence and provenance substrate

This module defines the small, closed evidence vocabulary shared by specification
verification and future result-acceptance work. It deliberately does not store
facts and does not resolve or execute verifiers. Evidence is data; executable
observers remain behind trusted registries in higher layers.
*/

:- use_module(library(lists)).

rlm_evidence_ready.

evidence_policy_default(
    evidence_policy{required_evidence:false,
                    source_classes:all,
                    trust_classes:all,
                    freshness:any,
                    coherence:none,
                    state_ref:any}).

evidence_policy_normalize(Input, Outcome) :-
    catch(( require_acyclic(Input, evidence_policy),
            normalize_policy(Input, Policy),
            Outcome = ok(Policy)
          ),
          Exception,
          evidence_exception(normalize_policy, Exception, Outcome)).

evidence_policy_narrow(Parent0, Child0, Outcome) :-
    catch(( normalize_policy(Parent0, Parent),
            normalize_policy(Child0, Child),
            narrow_policy(Parent, Child, Policy),
            Outcome = ok(Policy)
          ),
          Exception,
          evidence_exception(narrow_policy, Exception, Outcome)).

evidence_policy_accepts(Policy0, Observation0, Outcome) :-
    catch(( normalize_policy(Policy0, Policy),
            normalize_observation(Observation0, Observation),
            policy_observation_result(Policy, Observation, Result),
            Outcome = ok(Result)
          ),
          Exception,
          evidence_exception(accepts, Exception, Outcome)).

normalize_policy(default, Policy) :-
    !,
    evidence_policy_default(Policy).
normalize_policy(Input, Policy) :-
    is_dict(Input),
    !,
    allowed_keys(Input,
                 [required_evidence, source_classes, trust_classes,
                  freshness, coherence, state_ref],
                 evidence_policy),
    evidence_policy_default(Default),
    dict_default(Input, required_evidence, Default.required_evidence, Required),
    dict_default(Input, source_classes, Default.source_classes, Source0),
    dict_default(Input, trust_classes, Default.trust_classes, Trust0),
    dict_default(Input, freshness, Default.freshness, Freshness),
    dict_default(Input, coherence, Default.coherence, Coherence0),
    dict_default(Input, state_ref, Default.state_ref, StateRef0),
    require_boolean(Required, required_evidence),
    normalize_source_classes(Source0, Sources),
    normalize_trust_classes(Trust0, Trusts),
    require_member(Freshness, [any,current], freshness),
    normalize_coherence(Coherence0, Coherence),
    normalize_state_ref(StateRef0, StateRef),
    coherence_state_contract(Coherence, StateRef),
    Policy = evidence_policy{required_evidence:Required,
                             source_classes:Sources,
                             trust_classes:Trusts,
                             freshness:Freshness,
                             coherence:Coherence,
                             state_ref:StateRef}.
normalize_policy(Input, _) :-
    throw(evidence_fault(invalid_policy(Input))).

narrow_policy(Parent, Child, Policy) :-
    bool_or(Parent.required_evidence, Child.required_evidence, Required),
    intersect_filter(Parent.source_classes, Child.source_classes, Sources),
    intersect_filter(Parent.trust_classes, Child.trust_classes, Trusts),
    narrow_freshness(Parent.freshness, Child.freshness, Freshness),
    narrow_coherence(Parent.coherence, Child.coherence, Coherence),
    narrow_state_ref(Parent.state_ref, Child.state_ref, StateRef),
    coherence_state_contract(Coherence, StateRef),
    Policy = evidence_policy{required_evidence:Required,
                             source_classes:Sources,
                             trust_classes:Trusts,
                             freshness:Freshness,
                             coherence:Coherence,
                             state_ref:StateRef}.

intersect_filter(all, all, all) :- !.
intersect_filter(all, Values, Values) :- !.
intersect_filter(Values, all, Values) :- !.
intersect_filter(Left, Right, Intersection) :-
    findall(Value,
            ( member(Value, Left), memberchk(Value, Right) ),
            Values0),
    sort(Values0, Intersection),
    (   Intersection == []
    ->  throw(evidence_fault(incompatible_policy(empty_intersection(Left, Right))))
    ;   true
    ).

narrow_freshness(current, _, current) :- !.
narrow_freshness(_, current, current) :- !.
narrow_freshness(any, any, any).

narrow_coherence(none, none, none) :- !.
narrow_coherence(none, Scope, Scope) :- Scope \== none, !.
narrow_coherence(Scope, none, Scope) :- Scope \== none, !.
narrow_coherence(Scope, Scope, Scope) :- !.
narrow_coherence(Left, Right, _) :-
    throw(evidence_fault(incompatible_policy(coherence(Left, Right)))).

narrow_state_ref(any, any, any) :- !.
narrow_state_ref(any, Ref, Ref) :- !.
narrow_state_ref(Ref, any, Ref) :- !.
narrow_state_ref(Ref, Ref, Ref) :- !.
narrow_state_ref(Left, Right, _) :-
    throw(evidence_fault(incompatible_policy(state_ref(Left, Right)))).

coherence_state_contract(none, _) :- !.
coherence_state_contract(_, _) :- true.

normalize_source_classes(all, all) :- !.
normalize_source_classes(Classes0, Classes) :-
    normalize_atom_set(Classes0, source_classes, Classes).

normalize_trust_classes(all, all) :- !.
normalize_trust_classes(Classes0, Classes) :-
    normalize_atom_set(Classes0, trust_classes, Classes),
    forall(member(Class, Classes), require_trust_class(Class)).

normalize_coherence(none, none) :- !.
normalize_coherence(Scope, Scope) :-
    atom(Scope),
    Scope \== '',
    !.
normalize_coherence(Value, _) :-
    throw(evidence_fault(invalid_coherence(Value))).

normalize_state_ref(any, any) :- !.
normalize_state_ref(Ref0, Ref) :-
    canonical_evidence_data(Ref0, Ref).

/* Observations --------------------------------------------------------- */

observation_normalize(Input, Outcome) :-
    catch(( require_acyclic(Input, observation),
            normalize_observation(Input, Observation),
            Outcome = ok(Observation)
          ),
          Exception,
          evidence_exception(normalize_observation, Exception, Outcome)).

normalize_observation(Input, Observation) :-
    is_dict(Input),
    !,
    allowed_keys(Input,
                 [requirement_id, assertion, status, value, evidence_refs,
                  source_class, trust_class, provenance, verifier, collector,
                  snapshot, freshness, coherence, state_ref],
                 observation),
    require_dict_key(Input, requirement_id, RequirementId),
    require_name(RequirementId, requirement_id),
    require_dict_key(Input, assertion, Assertion),
    require_ground(Assertion, assertion),
    require_dict_key(Input, status, Status0),
    normalize_status(Status0, Status),
    dict_default(Input, value, none, Value0),
    canonical_evidence_data(Value0, Value),
    dict_default(Input, evidence_refs, [], EvidenceRefs0),
    canonical_evidence_list(EvidenceRefs0, evidence_refs, EvidenceRefs),
    require_dict_key(Input, source_class, SourceClass),
    require_name(SourceClass, source_class),
    require_dict_key(Input, trust_class, TrustClass),
    require_trust_class(TrustClass),
    dict_default(Input, provenance, _{}, Provenance0),
    normalize_provenance(Provenance0, Provenance),
    require_dict_key(Input, verifier, Verifier0),
    normalize_identity(verifier, Verifier0, Verifier),
    require_dict_key(Input, collector, Collector0),
    normalize_identity(collector, Collector0, Collector),
    dict_default(Input, snapshot, none, Snapshot0),
    canonical_evidence_data(Snapshot0, Snapshot),
    dict_default(Input, freshness, unknown, Freshness),
    require_member(Freshness, [current,stale,unknown], freshness),
    dict_default(Input, coherence, none, Coherence0),
    normalize_coherence(Coherence0, Coherence),
    dict_default(Input, state_ref, none, StateRef0),
    canonical_evidence_data(StateRef0, StateRef),
    Observation = rlm_observation{
                      requirement_id:RequirementId,
                      assertion:Assertion,
                      status:Status,
                      value:Value,
                      evidence_refs:EvidenceRefs,
                      source_class:SourceClass,
                      trust_class:TrustClass,
                      provenance:Provenance,
                      verifier:Verifier,
                      collector:Collector,
                      snapshot:Snapshot,
                      freshness:Freshness,
                      coherence:Coherence,
                      state_ref:StateRef
                  }.
normalize_observation(Input, _) :-
    throw(evidence_fault(invalid_observation(Input))).

normalize_status(passed, passed) :- !.
normalize_status(failed, failed) :- !.
normalize_status(missing, missing) :- !.
normalize_status(pending, pending) :- !.
normalize_status(skipped, skipped) :- !.
normalize_status(cancelled, cancelled) :- !.
normalize_status(error(Detail), error(Detail)) :- require_ground(Detail, error), !.
normalize_status(timeout(Detail), timeout(Detail)) :- require_ground(Detail, timeout), !.
normalize_status(indeterminate(Detail), indeterminate(Detail)) :- require_ground(Detail, indeterminate), !.
normalize_status(stale(Detail), stale(Detail)) :- require_ground(Detail, stale), !.
normalize_status(Status, _) :-
    throw(evidence_fault(invalid_observation_status(Status))).

observation_status_success(passed).

observation_status_terminal(passed).
observation_status_terminal(failed).
observation_status_terminal(missing).
observation_status_terminal(skipped).
observation_status_terminal(cancelled).
observation_status_terminal(error(_)).
observation_status_terminal(timeout(_)).
observation_status_terminal(indeterminate(_)).
observation_status_terminal(stale(_)).

policy_observation_result(Policy, Observation, Result) :-
    policy_checks(Policy, Observation, Checks),
    failed_checks(Checks, Failures),
    (   Failures == []
    ->  Result = accepted
    ;   Result = rejected(Failures)
    ).

policy_checks(Policy, Observation,
              [ source(SourceCheck),
                trust(TrustCheck),
                evidence(EvidenceCheck),
                freshness(FreshnessCheck),
                coherence(CoherenceCheck),
                state_ref(StateRefCheck)
              ]) :-
    filter_check(Policy.source_classes, Observation.source_class, SourceCheck),
    filter_check(Policy.trust_classes, Observation.trust_class, TrustCheck),
    required_evidence_check(Policy.required_evidence,
                            Observation.evidence_refs,
                            EvidenceCheck),
    freshness_check(Policy.freshness, Observation.freshness, FreshnessCheck),
    coherence_check(Policy.coherence, Observation.coherence, CoherenceCheck),
    state_ref_check(Policy.state_ref, Observation.state_ref, StateRefCheck).

filter_check(all, _, passed) :- !.
filter_check(Allowed, Value, passed) :- memberchk(Value, Allowed), !.
filter_check(Allowed, Value, failed(not_allowed(Value, Allowed))).

required_evidence_check(false, _, passed) :- !.
required_evidence_check(true, [_|_], passed) :- !.
required_evidence_check(true, [], failed(missing_evidence_refs)).

freshness_check(any, _, passed) :- !.
freshness_check(current, current, passed) :- !.
freshness_check(current, Found, failed(stale_or_unknown(Found))).

coherence_check(none, _, passed) :- !.
coherence_check(Expected, Expected, passed) :- !.
coherence_check(Expected, Found, failed(coherence_mismatch(Expected, Found))).

state_ref_check(any, _, passed) :- !.
state_ref_check(Expected, Expected, passed) :- !.
state_ref_check(Expected, Found, failed(state_ref_mismatch(Expected, Found))).

failed_checks(Checks, Failures) :-
    findall(Failure,
            ( member(Check, Checks),
              arg(1, Check, Result),
              Result = failed(Failure)
            ),
            Failures).

canonical_evidence_list(Value0, Name, Value) :-
    (   is_list(Value0)
    ->  maplist(canonical_evidence_data, Value0, Value)
    ;   throw(evidence_fault(invalid_list(Name, Value0)))
    ).

canonical_evidence_data(Value0, _) :-
    var(Value0),
    !,
    throw(evidence_fault(non_ground_evidence_data)).
canonical_evidence_data(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_evidence_pair, Pairs0, Pairs),
    dict_pairs(Value, evidence_data, Pairs).
canonical_evidence_data(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_evidence_data, Values0, Values).
canonical_evidence_data(Value0, Value) :-
    compound(Value0),
    !,
    Value0 =.. [Functor|Args0],
    maplist(canonical_evidence_data, Args0, Args),
    Value =.. [Functor|Args].
canonical_evidence_data(Value, Value) :-
    atomic(Value),
    !.
canonical_evidence_data(Value, _) :-
    throw(evidence_fault(unsupported_evidence_data(Value))).

canonical_evidence_pair(Key-Value0, Key-Value) :-
    atom(Key),
    !,
    canonical_evidence_data(Value0, Value).
canonical_evidence_pair(Key-_, _) :-
    throw(evidence_fault(invalid_evidence_dict_key(Key))).

/* Provenance ----------------------------------------------------------- */

provenance_class(trusted_runtime).
provenance_class(external_observation).
provenance_class(project_kb).
provenance_class(model_claim).
provenance_class(derived_claim).
provenance_class(research_source).
provenance_class(ci).
provenance_class(solver).
provenance_class(host_assertion).
provenance_class(unresolved).

trust_class(trusted).
trust_class(observed).
trust_class(model_claim).
trust_class(derived).
trust_class(unresolved).

require_trust_class(Class) :-
    trust_class(Class),
    !.
require_trust_class(Class) :-
    throw(evidence_fault(invalid_trust_class(Class))).

normalize_provenance(Input, Provenance) :-
    is_dict(Input),
    !,
    dict_pairs(Input, _, Pairs0),
    maplist(canonical_provenance_pair, Pairs0, Pairs),
    dict_pairs(Provenance, evidence_provenance, Pairs).
normalize_provenance(Input, _) :-
    throw(evidence_fault(invalid_provenance(Input))).

canonical_provenance_pair(Key-Value0, Key-Value) :-
    atom(Key),
    !,
    canonical_provenance_value(Value0, Value).
canonical_provenance_pair(Key-_, _) :-
    throw(evidence_fault(invalid_provenance_key(Key))).

canonical_provenance_value(Value0, _) :-
    var(Value0),
    !,
    throw(evidence_fault(non_ground_provenance)).
canonical_provenance_value(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_provenance_pair, Pairs0, Pairs),
    dict_pairs(Value, evidence_provenance_data, Pairs).
canonical_provenance_value(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_provenance_value, Values0, Values).
canonical_provenance_value(Value0, Value) :-
    compound(Value0),
    !,
    Value0 =.. [Functor|Args0],
    maplist(canonical_provenance_value, Args0, Args),
    Value =.. [Functor|Args].
canonical_provenance_value(Value, Value) :- atomic(Value), !.

normalize_identity(Tag, Input, Identity) :-
    is_dict(Input),
    allowed_keys(Input, [id,version], Tag),
    require_dict_key(Input, id, Id),
    require_name(Id, id),
    require_dict_key(Input, version, Version),
    require_ground(Version, version),
    dict_pairs(Identity, Tag, [id-Id,version-Version]).

/* Helpers -------------------------------------------------------------- */

normalize_atom_set(Values0, Name, Values) :-
    (   is_list(Values0), Values0 \== []
    ->  maplist(require_name_for(Name), Values0, Names),
        sort(Names, Values),
        length(Names, Count0),
        length(Values, Count),
        ( Count0 =:= Count -> true ; throw(evidence_fault(duplicate_values(Name))) )
    ;   throw(evidence_fault(invalid_nonempty_list(Name, Values0)))
    ).

require_name_for(Name, Value, Atom) :- require_name(Value, Name), Atom = Value.

allowed_keys(Dict, Allowed, Name) :-
    dict_pairs(Dict, _, Pairs),
    findall(Key, member(Key-_, Pairs), Keys),
    forall(member(Key, Keys),
           ( memberchk(Key, Allowed)
           -> true
           ; throw(evidence_fault(unknown_key(Name, Key)))
           )).

require_dict_key(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(evidence_fault(missing_key(Key)))
    ).

dict_default(Dict, Key, Default, Value) :-
    ( get_dict(Key, Dict, Found) -> Value = Found ; Value = Default ).

require_name(Value, _) :- atom(Value), Value \== '', !.
require_name(Value, Name) :- throw(evidence_fault(invalid_name(Name, Value))).

require_boolean(Value, _) :- memberchk(Value, [true,false]), !.
require_boolean(Value, Name) :- throw(evidence_fault(invalid_boolean(Name, Value))).

require_member(Value, Allowed, _) :- memberchk(Value, Allowed), !.
require_member(Value, _, Name) :- throw(evidence_fault(invalid_value(Name, Value))).

require_acyclic(Value, _) :- acyclic_term(Value), !.
require_acyclic(_, Name) :- throw(evidence_fault(cyclic(Name))).

require_ground(Value, _) :- ground(Value), !.
require_ground(Value, Name) :- throw(evidence_fault(non_ground(Name, Value))).

require_ground_list(Value, _) :-
    is_list(Value),
    ground(Value),
    !.
require_ground_list(Value, Name) :-
    throw(evidence_fault(invalid_ground_list(Name, Value))).

bool_or(true, _, true) :- !.
bool_or(_, true, true) :- !.
bool_or(false, false, false).

evidence_exception(Phase, evidence_fault(Detail), error(Error)) :-
    !,
    Error = evidence_error{phase:Phase,
                           kind:evidence_error,
                           detail:Detail,
                           message:"evidence contract rejected input"}.
evidence_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = evidence_error{phase:Phase,
                           kind:exception,
                           exception:Safe,
                           message:"evidence operation raised an exception"}.
