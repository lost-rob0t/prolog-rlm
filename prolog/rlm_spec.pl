:- module(rlm_spec,
          [ rlm_spec_ready/0,
            spec_normalize/2,
            spec_validate/3,
            spec_freeze/3,
            spec_inspect/2,
            spec_fingerprint/2,
            spec_publish/5,
            spec_resolve/3,
            spec_ref_status/3
          ]).

/** <module> Domain-neutral immutable specifications

A Spec describes desired state. It is declarative data, not executable Prolog.
Validation binds each requirement to one trusted assertion provider and narrows
the requested evidence policy against host policy. Freezing gives the validated
semantic content a stable SHA-256 identity. Persistence through rlm_artifact is
optional and preserves exact historical versions.
*/

:- use_module(library(crypto)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(rlm_assertion).
:- use_module(rlm_evidence).
:- use_module(rlm_artifact, []).

rlm_spec_ready.

spec_normalize(Input, Outcome) :-
    catch(( require_acyclic(Input, spec),
            normalize_spec(Input, Spec),
            Outcome = ok(Spec)
          ),
          Exception,
          spec_exception(normalize, Exception, Outcome)).

spec_validate(Spec0, Registry, Outcome) :-
    catch(( require_acyclic(Spec0, spec),
            normalize_spec(Spec0, Spec),
            assertion_registry_validate(Registry, RegistryOutcome),
            require_assertion_outcome(RegistryOutcome, NormalizedRegistry),
            maplist(validate_requirement(NormalizedRegistry),
                    Spec.requirements,
                    Requirements),
            Validated = validated_spec{
                            schema_version:Spec.schema_version,
                            subject:Spec.subject,
                            requirements:Requirements,
                            invariants:Spec.invariants,
                            output_contract:Spec.output_contract,
                            provenance:Spec.provenance
                        },
            Outcome = ok(Validated)
          ),
          Exception,
          spec_exception(validate, Exception, Outcome)).

spec_freeze(Validated0, Options, Outcome) :-
    catch(( require_acyclic(Validated0, validated_spec),
            require_options(Options),
            normalize_validated_spec(Validated0, Validated),
            option(series(Series0), Options, spec),
            require_name(Series0, Series),
            option(version(Version), Options, 1),
            require_positive_integer(Version, version),
            semantic_spec_content(Validated, Semantic),
            content_fingerprint(Semantic, Fingerprint),
            Ref = spec_ref{series:Series,
                           version:Version,
                           fingerprint:Fingerprint},
            Frozen = frozen_spec{
                         schema_version:Validated.schema_version,
                         ref:Ref,
                         subject:Validated.subject,
                         requirements:Validated.requirements,
                         invariants:Validated.invariants,
                         output_contract:Validated.output_contract,
                         provenance:Validated.provenance
                     },
            Outcome = ok(Frozen)
          ),
          Exception,
          spec_exception(freeze, Exception, Outcome)).

spec_inspect(Frozen0, Outcome) :-
    catch(( normalize_frozen_spec(Frozen0, Frozen),
            findall(Id,
                    ( member(Requirement, Frozen.requirements),
                      Id = Requirement.id ),
                    RequirementIds),
            length(RequirementIds, RequirementCount),
            findall(Id,
                    ( member(Requirement, Frozen.requirements),
                      Requirement.severity == required,
                      Id = Requirement.id ),
                    RequiredIds),
            Inspection = spec_inspection{
                             spec_ref:Frozen.ref,
                             subject:Frozen.subject,
                             requirement_count:RequirementCount,
                             requirement_ids:RequirementIds,
                             required_ids:RequiredIds,
                             invariants:Frozen.invariants,
                             output_contract:Frozen.output_contract,
                             provenance:Frozen.provenance
                         },
            Outcome = ok(Inspection)
          ),
          Exception,
          spec_exception(inspect, Exception, Outcome)).

spec_fingerprint(Frozen0, Fingerprint) :-
    normalize_frozen_spec(Frozen0, Frozen),
    Fingerprint = Frozen.ref.fingerprint.

spec_publish(Store, Namespace, Frozen0, Provenance0, Outcome) :-
    catch(( normalize_frozen_spec(Frozen0, Frozen),
            normalize_provenance(Provenance0, Provenance),
            Key = Frozen.ref.series,
            ensure_publish_version(Store, Namespace, Key, Frozen),
            rlm_artifact:artifact_put(Store,
                                      Namespace,
                                      Key,
                                      frozen_spec,
                                      frozen_spec_payload(Frozen),
                                      Provenance,
                                      ArtifactOutcome),
            require_artifact_outcome(ArtifactOutcome, Artifact),
            PublishedRef = published_spec_ref{
                               spec_ref:Frozen.ref,
                               artifact_ref:Artifact.ref
                           },
            Outcome = ok(spec_publication{
                             ref:PublishedRef,
                             artifact:Artifact
                         })
          ),
          Exception,
          spec_exception(publish, Exception, Outcome)).

spec_resolve(Store, Ref0, Outcome) :-
    catch(( normalize_published_ref(Ref0, Ref),
            rlm_artifact:artifact_get(Store, Ref.artifact_ref, ArtifactOutcome),
            require_artifact_outcome(ArtifactOutcome, Artifact),
            require_frozen_artifact(Artifact, Frozen),
            normalize_frozen_spec(Frozen, Normalized),
            (   Normalized.ref == Ref.spec_ref
            ->  true
            ;   throw(spec_fault(spec_ref_mismatch(Ref.spec_ref,
                                                    Normalized.ref)))
            ),
            Outcome = ok(Normalized)
          ),
          Exception,
          spec_exception(resolve, Exception, Outcome)).

spec_ref_status(Store, Ref0, Outcome) :-
    catch(( normalize_published_ref(Ref0, Ref),
            rlm_artifact:artifact_ref_status(Store,
                                             Ref.artifact_ref,
                                             ArtifactOutcome),
            require_artifact_outcome(ArtifactOutcome, Status),
            Outcome = ok(Status)
          ),
          Exception,
          spec_exception(ref_status, Exception, Outcome)).

/* Normalization -------------------------------------------------------- */

normalize_spec(Input, Spec) :-
    is_dict(Input),
    !,
    allowed_keys(Input,
                 [schema_version,subject,requirements,invariants,
                  output_contract,provenance],
                 spec),
    require_dict_key(Input, schema_version, SchemaVersion),
    require_schema_version(SchemaVersion),
    require_dict_key(Input, subject, Subject0),
    canonical_data(Subject0, Subject),
    require_dict_key(Input, requirements, Requirements0),
    require_nonempty_list(Requirements0, requirements),
    maplist(normalize_requirement, Requirements0, Requirements),
    requirement_ids(Requirements, Ids),
    require_unique(Ids, requirement_id),
    dict_default(Input, invariants, [], Invariants0),
    canonical_data(Invariants0, Invariants),
    dict_default(Input, output_contract, _{}, Output0),
    canonical_data(Output0, OutputContract),
    dict_default(Input, provenance, _{}, Provenance0),
    normalize_provenance(Provenance0, Provenance),
    Spec = rlm_spec{schema_version:SchemaVersion,
                    subject:Subject,
                    requirements:Requirements,
                    invariants:Invariants,
                    output_contract:OutputContract,
                    provenance:Provenance}.
normalize_spec(Input, _) :-
    throw(spec_fault(invalid_spec(Input))).

normalize_requirement(requirement(Id0, Assertion0, Policy0, Severity, Provenance0),
                      Requirement) :-
    !,
    require_name(Id0, Id),
    assertion_normalize(Assertion0, AssertionOutcome),
    require_assertion_outcome(AssertionOutcome, Assertion),
    evidence_policy_normalize(Policy0, PolicyOutcome),
    require_evidence_outcome(PolicyOutcome, Policy),
    require_member(Severity, [required,optional], severity),
    normalize_provenance(Provenance0, Provenance),
    Requirement = spec_requirement{id:Id,
                                   assertion:Assertion,
                                   evidence_policy:Policy,
                                   severity:Severity,
                                   provenance:Provenance}.
normalize_requirement(Input, Requirement) :-
    is_dict(Input),
    !,
    allowed_keys(Input,
                 [id,assertion,evidence_policy,severity,provenance],
                 requirement),
    require_dict_key(Input, id, Id),
    require_dict_key(Input, assertion, Assertion),
    dict_default(Input, evidence_policy, default, Policy),
    dict_default(Input, severity, required, Severity),
    dict_default(Input, provenance, _{}, Provenance),
    normalize_requirement(requirement(Id,
                                      Assertion,
                                      Policy,
                                      Severity,
                                      Provenance),
                          Requirement).
normalize_requirement(Input, _) :-
    throw(spec_fault(invalid_requirement(Input))).

validate_requirement(Registry, Requirement, Validated) :-
    assertion_validate(Requirement.assertion, Registry, AssertionOutcome),
    require_assertion_outcome(AssertionOutcome, AssertionValidation),
    evidence_policy_narrow(AssertionValidation.evidence_policy,
                           Requirement.evidence_policy,
                           PolicyOutcome),
    require_evidence_outcome(PolicyOutcome, EffectivePolicy),
    Validated = validated_requirement{
                    id:Requirement.id,
                    assertion:AssertionValidation.assertion,
                    evidence_policy:EffectivePolicy,
                    severity:Requirement.severity,
                    verifier:AssertionValidation.verifier,
                    collector:AssertionValidation.collector,
                    verify_time_limit:AssertionValidation.verify_time_limit,
                    latency:AssertionValidation.latency,
                    provenance:Requirement.provenance
                }.

normalize_validated_spec(Input, Validated) :-
    is_dict(Input),
    allowed_keys(Input,
                 [schema_version,subject,requirements,invariants,
                  output_contract,provenance],
                 validated_spec),
    require_dict_key(Input, schema_version, Version),
    require_schema_version(Version),
    require_dict_key(Input, subject, Subject),
    require_ground(Subject, subject),
    require_dict_key(Input, requirements, Requirements),
    require_nonempty_list(Requirements, requirements),
    maplist(normalize_validated_requirement, Requirements, NormalizedRequirements),
    requirement_ids(NormalizedRequirements, Ids),
    require_unique(Ids, requirement_id),
    require_dict_key(Input, invariants, Invariants),
    require_ground(Invariants, invariants),
    require_dict_key(Input, output_contract, Output),
    require_ground(Output, output_contract),
    require_dict_key(Input, provenance, Provenance),
    require_ground(Provenance, provenance),
    Validated = validated_spec{schema_version:Version,
                               subject:Subject,
                               requirements:NormalizedRequirements,
                               invariants:Invariants,
                               output_contract:Output,
                               provenance:Provenance}.

normalize_validated_requirement(Input, Requirement) :-
    is_dict(Input),
    allowed_keys(Input,
                 [id,assertion,evidence_policy,severity,verifier,
                  collector,verify_time_limit,latency,provenance],
                 validated_requirement),
    require_dict_key(Input, id, Id),
    require_name(Id, _),
    require_dict_key(Input, assertion, Assertion),
    assertion_normalize(Assertion, AssertionOutcome),
    require_assertion_outcome(AssertionOutcome, NormalizedAssertion),
    require_dict_key(Input, evidence_policy, Policy),
    evidence_policy_normalize(Policy, PolicyOutcome),
    require_evidence_outcome(PolicyOutcome, NormalizedPolicy),
    require_dict_key(Input, severity, Severity),
    require_member(Severity, [required,optional], severity),
    require_dict_key(Input, verifier, Verifier),
    normalize_identity(verifier, Verifier, NormalizedVerifier),
    require_dict_key(Input, collector, Collector),
    normalize_identity(collector, Collector, NormalizedCollector),
    require_dict_key(Input, verify_time_limit, VerifyTimeLimit),
    require_positive_number(VerifyTimeLimit, verify_time_limit),
    require_dict_key(Input, latency, Latency),
    require_member(Latency, [pure,blocking], latency),
    require_dict_key(Input, provenance, Provenance),
    require_ground(Provenance, provenance),
    Requirement = validated_requirement{id:Id,
                                        assertion:NormalizedAssertion,
                                        evidence_policy:NormalizedPolicy,
                                        severity:Severity,
                                        verifier:NormalizedVerifier,
                                        collector:NormalizedCollector,
                                        verify_time_limit:VerifyTimeLimit,
                                        latency:Latency,
                                        provenance:Provenance}.

normalize_frozen_spec(Input, Frozen) :-
    is_dict(Input),
    allowed_keys(Input,
                 [schema_version,ref,subject,requirements,invariants,
                  output_contract,provenance],
                 frozen_spec),
    require_dict_key(Input, schema_version, Version),
    require_schema_version(Version),
    require_dict_key(Input, ref, Ref0),
    normalize_spec_ref(Ref0, Ref),
    require_dict_key(Input, subject, Subject),
    require_ground(Subject, subject),
    require_dict_key(Input, requirements, Requirements0),
    require_nonempty_list(Requirements0, requirements),
    maplist(normalize_validated_requirement, Requirements0, Requirements),
    require_dict_key(Input, invariants, Invariants),
    require_ground(Invariants, invariants),
    require_dict_key(Input, output_contract, Output),
    require_ground(Output, output_contract),
    require_dict_key(Input, provenance, Provenance),
    require_ground(Provenance, provenance),
    Frozen0 = frozen_spec{schema_version:Version,
                          ref:Ref,
                          subject:Subject,
                          requirements:Requirements,
                          invariants:Invariants,
                          output_contract:Output,
                          provenance:Provenance},
    semantic_spec_content(Frozen0, Semantic),
    content_fingerprint(Semantic, Expected),
    (   Expected == Ref.fingerprint
    ->  Frozen = Frozen0
    ;   throw(spec_fault(fingerprint_mismatch(Ref.fingerprint, Expected)))
    ).

normalize_spec_ref(Input, Ref) :-
    is_dict(Input),
    allowed_keys(Input, [series,version,fingerprint], spec_ref),
    require_dict_key(Input, series, Series),
    require_name(Series, _),
    require_dict_key(Input, version, Version),
    require_positive_integer(Version, version),
    require_dict_key(Input, fingerprint, Fingerprint),
    require_hash(Fingerprint),
    Ref = spec_ref{series:Series, version:Version, fingerprint:Fingerprint}.

normalize_published_ref(Input, Ref) :-
    is_dict(Input),
    allowed_keys(Input, [spec_ref,artifact_ref], published_spec_ref),
    require_dict_key(Input, spec_ref, SpecRef0),
    normalize_spec_ref(SpecRef0, SpecRef),
    require_dict_key(Input, artifact_ref, ArtifactRef),
    require_ground(ArtifactRef, artifact_ref),
    Ref = published_spec_ref{spec_ref:SpecRef, artifact_ref:ArtifactRef}.

/* Content identity ----------------------------------------------------- */

semantic_spec_content(Spec, Semantic) :-
    maplist(semantic_requirement, Spec.requirements, Requirements),
    Semantic = spec_semantics{
                   schema_version:Spec.schema_version,
                   subject:Spec.subject,
                   requirements:Requirements,
                   invariants:Spec.invariants,
                   output_contract:Spec.output_contract
               }.

semantic_requirement(Requirement, Semantic) :-
    Semantic = spec_requirement_semantics{
                   id:Requirement.id,
                   assertion:Requirement.assertion,
                   evidence_policy:Requirement.evidence_policy,
                   severity:Requirement.severity,
                   verifier:Requirement.verifier,
                   collector:Requirement.collector,
                   verify_time_limit:Requirement.verify_time_limit
               }.

content_fingerprint(Content, Fingerprint) :-
    canonical_identity_term(Content, Canonical),
    with_output_to(codes(Codes),
                   write_term(Canonical,
                              [ quoted(true),
                                ignore_ops(true),
                                numbervars(true)
                              ])),
    crypto_data_hash(Codes, Hash, [algorithm(sha256), encoding(utf8)]),
    atom_concat('spec-sha256-', Hash, Fingerprint).

canonical_identity_term(Value, _) :-
    var(Value),
    !,
    throw(spec_fault(non_ground_fingerprint_input)).
canonical_identity_term(Value0, canonical_dict(Pairs)) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    keysort(Pairs0, Sorted),
    maplist(canonical_identity_pair, Sorted, Pairs).
canonical_identity_term(Values0, canonical_list(Values)) :-
    is_list(Values0),
    !,
    maplist(canonical_identity_term, Values0, Values).
canonical_identity_term(Value0, canonical_compound(Functor, Args)) :-
    compound(Value0),
    !,
    Value0 =.. [Functor|Args0],
    maplist(canonical_identity_term, Args0, Args).
canonical_identity_term(Value, canonical_atomic(Value)) :-
    atomic(Value),
    !.
canonical_identity_term(Value, _) :-
    throw(spec_fault(unsupported_fingerprint_value(Value))).

canonical_identity_pair(Key-Value0, Key-Value) :-
    canonical_identity_term(Value0, Value).

/* Artifact bridge ------------------------------------------------------ */

ensure_publish_version(Store, Namespace, Key, Frozen) :-
    rlm_artifact:artifact_latest(Store, Namespace, Key, LatestOutcome),
    ensure_publish_version_outcome(LatestOutcome, Frozen).

ensure_publish_version_outcome(error(Error), _) :-
    is_dict(Error),
    get_dict(detail, Error, Detail),
    Detail = not_found(_),
    !.
ensure_publish_version_outcome(error(Error), _) :-
    throw(spec_fault(artifact(Error))).
ensure_publish_version_outcome(ok(Artifact), Frozen) :-
    require_frozen_artifact(Artifact, Previous),
    (   Frozen.ref.version > Previous.ref.version
    ->  true
    ;   throw(spec_fault(non_monotonic_spec_version(
                              previous(Previous.ref),
                              requested(Frozen.ref))))
    ).

require_frozen_artifact(Artifact, Frozen) :-
    (   is_dict(Artifact),
        Artifact.kind == frozen_spec,
        Artifact.value = frozen_spec_payload(Frozen)
    ->  true
    ;   throw(spec_fault(not_frozen_spec_artifact(Artifact)))
    ).

/* Shared safe data ----------------------------------------------------- */

canonical_data(Value0, _) :-
    var(Value0),
    !,
    throw(spec_fault(non_ground_data)).
canonical_data(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_data_pair, Pairs0, Pairs),
    dict_pairs(Value, spec_data, Pairs).
canonical_data(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_data, Values0, Values).
canonical_data(Value0, Value) :-
    compound(Value0),
    !,
    Value0 =.. [Functor|Args0],
    maplist(canonical_data, Args0, Args),
    Value =.. [Functor|Args].
canonical_data(Value, Value) :- atomic(Value), !.

canonical_data_pair(Key-Value0, Key-Value) :-
    atom(Key),
    !,
    canonical_data(Value0, Value).
canonical_data_pair(Key-_, _) :- throw(spec_fault(invalid_dict_key(Key))).

normalize_provenance(Input, Provenance) :-
    is_dict(Input),
    !,
    dict_pairs(Input, _, Pairs0),
    maplist(canonical_provenance_pair, Pairs0, Pairs),
    dict_pairs(Provenance, spec_provenance, Pairs).
normalize_provenance(Input, _) :- throw(spec_fault(invalid_provenance(Input))).

canonical_provenance_pair(Key-Value0, Key-Value) :-
    atom(Key),
    !,
    canonical_data(Value0, Value).
canonical_provenance_pair(Key-_, _) :- throw(spec_fault(invalid_provenance_key(Key))).

normalize_identity(Tag, Input, Identity) :-
    is_dict(Input),
    allowed_keys(Input, [id,version], Tag),
    require_dict_key(Input, id, Id),
    require_name(Id, _),
    require_dict_key(Input, version, Version),
    require_ground(Version, version),
    dict_pairs(Identity, Tag, [id-Id,version-Version]).

/* Helpers -------------------------------------------------------------- */

require_schema_version(1) :- !.
require_schema_version(Version) :- throw(spec_fault(unknown_schema_version(Version))).

require_hash(Fingerprint) :-
    atom(Fingerprint),
    atom_concat('spec-sha256-', Hex, Fingerprint),
    atom_length(Hex, 64),
    !.
require_hash(Fingerprint) :- throw(spec_fault(invalid_fingerprint(Fingerprint))).

require_options(Options) :- is_list(Options), !.
require_options(Options) :- throw(spec_fault(invalid_options(Options))).

allowed_keys(Dict, Allowed, Name) :-
    dict_pairs(Dict, _, Pairs),
    forall(member(Key-_, Pairs),
           ( memberchk(Key, Allowed)
           -> true
           ; throw(spec_fault(unknown_key(Name, Key)))
           )).

require_dict_key(Dict, Key, Value) :-
    ( get_dict(Key, Dict, Value) -> true ; throw(spec_fault(missing_key(Key))) ).

dict_default(Dict, Key, Default, Value) :-
    ( get_dict(Key, Dict, Found) -> Value = Found ; Value = Default ).

require_name(Value, Value) :- atom(Value), Value \== '', !.
require_name(Value, _) :- throw(spec_fault(invalid_name(Value))).

require_positive_integer(Value, _) :- integer(Value), Value > 0, !.
require_positive_integer(Value, Name) :-
    throw(spec_fault(invalid_positive_integer(Name, Value))).

require_positive_number(Value, _) :- number(Value), Value > 0, !.
require_positive_number(Value, Name) :-
    throw(spec_fault(invalid_positive_number(Name, Value))).

require_member(Value, Allowed, _) :- memberchk(Value, Allowed), !.
require_member(Value, _, Name) :- throw(spec_fault(invalid_value(Name, Value))).

require_acyclic(Value, _) :- acyclic_term(Value), !.
require_acyclic(_, Name) :- throw(spec_fault(cyclic(Name))).

require_ground(Value, _) :- ground(Value), !.
require_ground(Value, Name) :- throw(spec_fault(non_ground(Name, Value))).

require_nonempty_list(Value, _) :- is_list(Value), Value \== [], !.
require_nonempty_list(Value, Name) :- throw(spec_fault(invalid_nonempty_list(Name, Value))).

require_unique(Values, _) :-
    sort(Values, Unique),
    length(Values, Count),
    length(Unique, Count),
    !.
require_unique(Values, Kind) :- throw(spec_fault(duplicate(Kind, Values))).

requirement_ids(Requirements, Ids) :-
    findall(Id,
            ( member(Requirement, Requirements), Id = Requirement.id ),
            Ids).

require_assertion_outcome(ok(Value), Value) :- !.
require_assertion_outcome(error(Error), _) :- throw(spec_fault(assertion(Error))).

require_evidence_outcome(ok(Value), Value) :- !.
require_evidence_outcome(error(Error), _) :- throw(spec_fault(evidence(Error))).

require_artifact_outcome(ok(Value), Value) :- !.
require_artifact_outcome(error(Error), _) :- throw(spec_fault(artifact(Error))).

spec_exception(Phase, spec_fault(Detail), error(Error)) :-
    !,
    Error = spec_error{phase:Phase,
                       kind:spec_error,
                       detail:Detail,
                       message:"specification operation rejected input"}.
spec_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = spec_error{phase:Phase,
                       kind:exception,
                       exception:Safe,
                       message:"specification operation raised an exception"}.
