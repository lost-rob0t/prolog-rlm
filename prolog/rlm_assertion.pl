:- module(rlm_assertion,
          [ rlm_assertion_ready/0,
            assertion_normalize/2,
            assertion_registry_validate/2,
            assertion_registry_catalog/2,
            assertion_registry_resolve/4,
            assertion_validate/3,
            assertion_provider_latency/2
          ]).

/** <module> Trusted assertion registry boundary

Assertions are declarative model-facing data. Trusted host code supplies the
argument validator, pure evaluator and optional observation collector for each assertion kind.
There is intentionally no public mutation/registration predicate: model or
project data can select admitted kinds but cannot install executable authority.
*/

:- use_module(rlm_evidence).

rlm_assertion_ready.

assertion_normalize(Input, Outcome) :-
    catch(( require_acyclic(Input, assertion),
            normalize_assertion(Input, Assertion),
            Outcome = ok(Assertion)
          ),
          Exception,
          assertion_exception(normalize, Exception, Outcome)).

assertion_registry_validate(Registry, Outcome) :-
    catch(( require_acyclic(Registry, registry),
            normalize_registry(Registry, Normalized),
            Outcome = ok(Normalized)
          ),
          Exception,
          assertion_exception(registry_validate, Exception, Outcome)).

assertion_registry_catalog(Registry0, Outcome) :-
    catch(( normalize_registry(Registry0, Registry),
            maplist(catalog_entry, Registry, Catalog),
            Outcome = ok(Catalog)
          ),
          Exception,
          assertion_exception(catalog, Exception, Outcome)).

assertion_registry_resolve(Registry0, Kind0, Version, Outcome) :-
    catch(( normalize_registry(Registry0, Registry),
            require_name(Kind0, Kind),
            require_positive_integer(Version, schema_version),
            resolve_provider(Registry, Kind, Version, Provider),
            Outcome = ok(Provider)
          ),
          Exception,
          assertion_exception(resolve, Exception, Outcome)).

assertion_validate(Assertion0, Registry0, Outcome) :-
    catch(( normalize_assertion(Assertion0, Assertion),
            normalize_registry(Registry0, Registry),
            resolve_provider(Registry,
                             Assertion.kind,
                             Assertion.schema_version,
                             Provider),
            call_validator(Provider.validator, Assertion.args),
            Outcome = ok(validated_assertion{
                             assertion:Assertion,
                             verifier:Provider.verifier,
                             collector:Provider.collector,
                             evidence_policy:Provider.evidence_policy,
                             verify_time_limit:Provider.verify_time_limit,
                             latency:Provider.latency
                         })
          ),
          Exception,
          assertion_exception(validate, Exception, Outcome)).

assertion_provider_latency(Provider, Latency) :-
    is_dict(Provider),
    get_dict(latency, Provider, Latency),
    memberchk(Latency, [pure,blocking]).

/* Assertion data ------------------------------------------------------- */

normalize_assertion(assertion(Kind0, Args0), Assertion) :-
    !,
    normalize_assertion(assertion(Kind0, 1, Args0), Assertion).
normalize_assertion(assertion(Kind0, Version, Args0), Assertion) :-
    !,
    require_name(Kind0, Kind),
    require_positive_integer(Version, schema_version),
    canonical_data(Args0, Args),
    Assertion = rlm_assertion{kind:Kind,
                              schema_version:Version,
                              args:Args}.
normalize_assertion(Input, Assertion) :-
    is_dict(Input),
    !,
    allowed_keys(Input, [kind,schema_version,args], assertion),
    require_dict_key(Input, kind, Kind0),
    dict_default(Input, schema_version, 1, Version),
    require_dict_key(Input, args, Args0),
    normalize_assertion(assertion(Kind0, Version, Args0), Assertion).
normalize_assertion(Input, _) :-
    throw(assertion_fault(invalid_assertion(Input))).

/* Registry ------------------------------------------------------------- */

normalize_registry(Registry0, Registry) :-
    (   is_list(Registry0)
    ->  maplist(normalize_provider, Registry0, Registry),
        provider_keys(Registry, Keys),
        require_unique(Keys, assertion_provider)
    ;   throw(assertion_fault(invalid_registry(Registry0)))
    ).

normalize_provider(assertion_provider(Kind0,
                                      SchemaVersion,
                                      Validator,
                                      Evaluator,
                                      Observer,
                                      Metadata0),
                   Provider) :-
    !,
    require_name(Kind0, Kind),
    require_positive_integer(SchemaVersion, schema_version),
    require_callable(Validator, validator),
    require_callable(Evaluator, evaluator),
    require_observer(Observer),
    normalize_metadata(Metadata0, Metadata),
    collector_observer_contract(Metadata.collector, Observer),
    Provider = assertion_provider{
                   kind:Kind,
                   schema_version:SchemaVersion,
                   validator:Validator,
                   evaluator:Evaluator,
                   observer:Observer,
                   verifier:Metadata.verifier,
                   collector:Metadata.collector,
                   evidence_policy:Metadata.evidence_policy,
                   verify_time_limit:Metadata.verify_time_limit,
                   latency:Metadata.latency,
                   description:Metadata.description
               }.
normalize_provider(Input, _) :-
    throw(assertion_fault(invalid_registry_entry(Input))).

normalize_metadata(Input, Metadata) :-
    is_dict(Input),
    !,
    allowed_keys(Input,
                 [verifier,collector,evidence_policy,verify_time_limit,latency,description],
                 assertion_metadata),
    require_dict_key(Input, verifier, Verifier0),
    normalize_identity(verifier, Verifier0, Verifier),
    require_dict_key(Input, collector, Collector0),
    normalize_identity(collector, Collector0, Collector),
    require_dict_key(Input, evidence_policy, Policy0),
    evidence_policy_normalize(Policy0, PolicyOutcome),
    require_evidence_outcome(PolicyOutcome, Policy),
    dict_default(Input, verify_time_limit, 1.0, VerifyTimeLimit),
    require_positive_number(VerifyTimeLimit, verify_time_limit),
    dict_default(Input, latency, pure, Latency),
    require_member(Latency, [pure,blocking], latency),
    dict_default(Input, description, "", Description),
    require_text(Description, description),
    Metadata = assertion_metadata{verifier:Verifier,
                                  collector:Collector,
                                  evidence_policy:Policy,
                                  verify_time_limit:VerifyTimeLimit,
                                  latency:Latency,
                                  description:Description}.
normalize_metadata(Input, _) :-
    throw(assertion_fault(invalid_registry_metadata(Input))).

collector_observer_contract(Collector, none) :-
    Collector.id == none,
    !.
collector_observer_contract(Collector, Observer) :-
    Collector.id \== none,
    Observer \== none,
    !.
collector_observer_contract(Collector, Observer) :-
    throw(assertion_fault(collector_observer_mismatch(Collector, Observer))).

require_observer(none) :- !.
require_observer(Observer) :- require_callable(Observer, observer).

resolve_provider(Registry, Kind, Version, Provider) :-
    member(Provider, Registry),
    Provider.kind == Kind,
    Provider.schema_version =:= Version,
    !.
resolve_provider(_, Kind, Version, _) :-
    throw(assertion_fault(unknown_assertion_kind(Kind, Version))).

provider_keys(Registry, Keys) :-
    findall(Kind-Version,
            ( member(Provider, Registry),
              Kind = Provider.kind,
              Version = Provider.schema_version ),
            Keys).

catalog_entry(Provider,
              assertion_catalog_entry{
                  kind:Provider.kind,
                  schema_version:Provider.schema_version,
                  verifier:Provider.verifier,
                  collector:Provider.collector,
                  evidence_policy:Provider.evidence_policy,
                  verify_time_limit:Provider.verify_time_limit,
                  latency:Provider.latency,
                  description:Provider.description
              }).

call_validator(Validator, Args) :-
    catch(( call(Validator, Args)
          -> true
          ;  throw(assertion_fault(invalid_assertion_arguments(Args)))
          ),
          assertion_fault(Detail),
          throw(assertion_fault(Detail))),
    !.
call_validator(Validator, _) :-
    throw(assertion_fault(validator_failed(Validator))).

/* Closed safe data ----------------------------------------------------- */

canonical_data(Value0, Value) :-
    var(Value0),
    !,
    throw(assertion_fault(non_ground_assertion_arguments)).
canonical_data(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_pair, Pairs0, Pairs),
    dict_pairs(Value, assertion_args, Pairs).
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
canonical_data(Value, Value) :-
    atomic(Value),
    !.
canonical_data(Value, _) :-
    throw(assertion_fault(unsupported_assertion_data(Value))).

canonical_pair(Key-Value0, Key-Value) :-
    atom(Key),
    !,
    canonical_data(Value0, Value).
canonical_pair(Key-_, _) :-
    throw(assertion_fault(invalid_dict_key(Key))).

/* Helpers -------------------------------------------------------------- */

normalize_identity(Tag, Input, Identity) :-
    is_dict(Input),
    allowed_keys(Input, [id,version], Tag),
    require_dict_key(Input, id, Id0),
    require_name(Id0, Id),
    require_dict_key(Input, version, Version),
    require_ground(Version, version),
    dict_pairs(Identity, Tag, [id-Id,version-Version]).

allowed_keys(Dict, Allowed, Name) :-
    dict_pairs(Dict, _, Pairs),
    forall(member(Key-_, Pairs),
           ( memberchk(Key, Allowed)
           -> true
           ; throw(assertion_fault(unknown_key(Name, Key)))
           )).

require_dict_key(Dict, Key, Value) :-
    ( get_dict(Key, Dict, Value) -> true ; throw(assertion_fault(missing_key(Key))) ).

dict_default(Dict, Key, Default, Value) :-
    ( get_dict(Key, Dict, Found) -> Value = Found ; Value = Default ).

require_name(Value, Value) :- atom(Value), Value \== '', !.
require_name(Value, Name) :- throw(assertion_fault(invalid_name(Name, Value))).

require_positive_integer(Value, _) :- integer(Value), Value > 0, !.
require_positive_integer(Value, Name) :-
    throw(assertion_fault(invalid_positive_integer(Name, Value))).

require_positive_number(Value, _) :- number(Value), Value > 0, !.
require_positive_number(Value, Name) :-
    throw(assertion_fault(invalid_positive_number(Name, Value))).

require_callable(Value, _) :- callable(Value), !.
require_callable(Value, Name) :- throw(assertion_fault(invalid_callable(Name, Value))).

require_acyclic(Value, _) :- acyclic_term(Value), !.
require_acyclic(_, Name) :- throw(assertion_fault(cyclic(Name))).

require_ground(Value, _) :- ground(Value), !.
require_ground(Value, Name) :- throw(assertion_fault(non_ground(Name, Value))).

require_member(Value, Allowed, _) :- memberchk(Value, Allowed), !.
require_member(Value, _, Name) :- throw(assertion_fault(invalid_value(Name, Value))).

require_text(Value, _) :- string(Value), !.
require_text(Value, _) :- atom(Value), !.
require_text(Value, Name) :- throw(assertion_fault(invalid_text(Name, Value))).

require_unique(Values, Kind) :-
    sort(Values, Unique),
    length(Values, Count),
    length(Unique, Count),
    !.
require_unique(Values, Kind) :-
    throw(assertion_fault(duplicate(Kind, Values))).

require_evidence_outcome(ok(Value), Value) :- !.
require_evidence_outcome(error(Error), _) :- throw(assertion_fault(evidence_policy(Error))).

assertion_exception(Phase, assertion_fault(Detail), error(Error)) :-
    !,
    Error = assertion_error{phase:Phase,
                            kind:assertion_error,
                            detail:Detail,
                            message:"assertion registry rejected input"}.
assertion_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = assertion_error{phase:Phase,
                            kind:exception,
                            exception:Safe,
                            message:"assertion operation raised an exception"}.
