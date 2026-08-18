:- module(rlm_spec_lang,
          [ rlm_spec_lang_ready/0,
            spec_language_catalog/2,
            spec_source_normalize/2,
            spec_source_compile/4
          ]).

/** <module> Closed authoring language for first-class Specs

SPEC source is declarative input. It is parsed and desugared into the canonical
`rlm_spec` representation, then existing validation/freezing owns semantics.
Nothing on this path consults or executes model-produced Prolog.
*/

:- use_module(library(lists)).
:- use_module(rlm_assertion).
:- use_module(rlm_spec).

rlm_spec_lang_ready.

spec_language_catalog(Registry, Outcome) :-
    catch(( assertion_registry_catalog(Registry, AssertionOutcome),
            require_assertion_outcome(AssertionOutcome, Assertions),
            structural_catalog(Symbols),
            Outcome = ok(spec_language_catalog{
                             schema_version:1,
                             symbols:Symbols,
                             assertions:Assertions
                         })
          ),
          Exception,
          spec_lang_exception(catalog, Exception, Outcome)).

spec_source_normalize(Source, Outcome) :-
    catch(( source_term(Source, Term),
            require_acyclic(Term, source),
            require_ground(Term, source),
            normalize_source(Term, Spec0),
            spec_normalize(Spec0, SpecOutcome),
            require_spec_outcome(SpecOutcome, Spec),
            Outcome = ok(Spec)
          ),
          Exception,
          spec_lang_exception(normalize, Exception, Outcome)).

spec_source_compile(Source, Registry, FreezeOptions, Outcome) :-
    catch(( spec_source_normalize(Source, NormalizeOutcome),
            require_lang_outcome(NormalizeOutcome, Spec),
            spec_validate(Spec, Registry, ValidateOutcome),
            require_spec_outcome(ValidateOutcome, Validated),
            spec_freeze(Validated, FreezeOptions, FreezeOutcome),
            require_spec_outcome(FreezeOutcome, Frozen),
            Outcome = ok(Frozen)
          ),
          Exception,
          spec_lang_exception(compile, Exception, Outcome)).

/* Structural catalog --------------------------------------------------- */

structural_catalog([
    spec_symbol{name:spec,
                arities:[1],
                role:root,
                arguments:[forms],
                description:"root of one closed SPEC source"},
    spec_symbol{name:schema_version,
                arities:[1],
                role:metadata,
                arguments:[positive_integer],
                description:"declare the SPEC source schema version"},
    spec_symbol{name:subject,
                arities:[1],
                role:subject,
                arguments:[ground_data],
                description:"identify the domain-neutral subject being specified"},
    spec_symbol{name:require,
                arities:[2,3],
                role:requirement,
                arguments:[requirement_id,assertion,options],
                description:"declare a required assertion"},
    spec_symbol{name:optional,
                arities:[2,3],
                role:requirement,
                arguments:[requirement_id,assertion,options],
                description:"declare an inspectable assertion that does not reject the Spec by itself"},
    spec_symbol{name:invariant,
                arities:[1],
                role:invariant,
                arguments:[ground_data],
                description:"attach declarative invariant data; it is never executed"},
    spec_symbol{name:output_contract,
                arities:[1],
                role:output_contract,
                arguments:[ground_data],
                description:"describe required output/result shape as declarative data"},
    spec_symbol{name:provenance,
                arities:[1],
                role:provenance,
                arguments:[dict],
                description:"attach source provenance to the Spec"},
    spec_symbol{name:assertion,
                arities:[2,3],
                role:assertion,
                arguments:[kind,schema_version,args],
                description:"select a trusted registered assertion kind with declarative arguments"},
    spec_symbol{name:evidence_policy,
                arities:[1],
                role:requirement_option,
                arguments:[policy],
                description:"narrow evidence requirements for one requirement"}
]).

/* Source parsing ------------------------------------------------------- */

source_term(Source, Source) :-
    compound(Source),
    !.
source_term(Source, Term) :-
    string(Source),
    !,
    parse_source_text(Source, Term).
source_term(Source, Term) :-
    atom(Source),
    !,
    atom_string(Source, Text),
    parse_source_text(Text, Term).
source_term(Source, _) :-
    throw(spec_lang_fault(unsupported_source(Source))).

parse_source_text(Text, Term) :-
    catch(term_string(Term, Text, [syntax_errors(error)]),
          Exception,
          throw(spec_lang_fault(parse_error(Exception)))).

/* Desugaring ----------------------------------------------------------- */

normalize_source(spec(Forms), Spec) :-
    !,
    require_list(Forms, forms),
    initial_state(State0),
    foldl(apply_form, Forms, State0, State1),
    finalize_state(State1, Spec).
normalize_source(Term, _) :-
    throw(spec_lang_fault(expected_spec(Term))).

initial_state(source_state{
                  schema_version:none,
                  subject:none,
                  requirements:[],
                  invariants:[],
                  output_contract:none,
                  provenance:none
              }).

apply_form(schema_version(Version), State0, State) :-
    !,
    require_positive_integer(Version, schema_version),
    set_singleton(schema_version, Version, State0, State).
apply_form(subject(Subject), State0, State) :-
    !,
    safe_source_data(Subject),
    set_singleton(subject, Subject, State0, State).
apply_form(require(Id, Assertion), State0, State) :-
    !,
    add_requirement(required, Id, Assertion, [], State0, State).
apply_form(require(Id, Assertion, Options), State0, State) :-
    !,
    add_requirement(required, Id, Assertion, Options, State0, State).
apply_form(optional(Id, Assertion), State0, State) :-
    !,
    add_requirement(optional, Id, Assertion, [], State0, State).
apply_form(optional(Id, Assertion, Options), State0, State) :-
    !,
    add_requirement(optional, Id, Assertion, Options, State0, State).
apply_form(invariant(Invariant), State0, State) :-
    !,
    safe_source_data(Invariant),
    get_dict(invariants, State0, Invariants0),
    put_dict(invariants, State0, [Invariant|Invariants0], State).
apply_form(output_contract(Contract), State0, State) :-
    !,
    safe_source_data(Contract),
    set_singleton(output_contract, Contract, State0, State).
apply_form(provenance(Provenance), State0, State) :-
    !,
    require_dict(Provenance, provenance),
    safe_source_data(Provenance),
    set_singleton(provenance, Provenance, State0, State).
apply_form(Form, _, _) :-
    compound(Form),
    !,
    functor(Form, Name, Arity),
    throw(spec_lang_fault(unknown_structural_symbol(Name/Arity))).
apply_form(Form, _, _) :-
    throw(spec_lang_fault(invalid_form(Form))).

add_requirement(Severity, Id, Assertion0, Options, State0, State) :-
    require_name(Id, requirement_id),
    normalize_source_assertion(Assertion0, Assertion),
    normalize_requirement_options(Options, Policy, Provenance),
    Requirement = _{ id:Id,
                     assertion:Assertion,
                     evidence_policy:Policy,
                     severity:Severity,
                     provenance:Provenance
                   },
    get_dict(requirements, State0, Requirements0),
    put_dict(requirements, State0, [Requirement|Requirements0], State).

normalize_source_assertion(assertion(Kind, Args), assertion(Kind, Args)) :-
    !,
    require_name(Kind, assertion_kind),
    safe_source_data(Args).
normalize_source_assertion(assertion(Kind, Version, Args),
                           assertion(Kind, Version, Args)) :-
    !,
    require_name(Kind, assertion_kind),
    require_positive_integer(Version, assertion_schema_version),
    safe_source_data(Args).
normalize_source_assertion(Assertion, _) :-
    throw(spec_lang_fault(invalid_assertion_form(Assertion))).

normalize_requirement_options(Options, Policy, Provenance) :-
    require_list(Options, requirement_options),
    foldl(apply_requirement_option,
          Options,
          requirement_options{evidence_policy:none,provenance:none},
          State),
    option_value(evidence_policy, State, default, Policy),
    option_value(provenance, State, _{}, Provenance).

apply_requirement_option(evidence_policy(Policy), State0, State) :-
    !,
    safe_source_data(Policy),
    set_singleton(evidence_policy, Policy, State0, State).
apply_requirement_option(provenance(Provenance), State0, State) :-
    !,
    require_dict(Provenance, provenance),
    safe_source_data(Provenance),
    set_singleton(provenance, Provenance, State0, State).
apply_requirement_option(Option, _, _) :-
    compound(Option),
    !,
    functor(Option, Name, Arity),
    throw(spec_lang_fault(unknown_requirement_option(Name/Arity))).
apply_requirement_option(Option, _, _) :-
    throw(spec_lang_fault(invalid_requirement_option(Option))).

finalize_state(State, Spec) :-
    state_value(schema_version, State, 1, SchemaVersion),
    require_state_value(subject, State, Subject),
    get_dict(requirements, State, Requirements0),
    reverse(Requirements0, Requirements),
    (   Requirements == []
    ->  throw(spec_lang_fault(missing_requirements))
    ;   true
    ),
    requirement_ids(Requirements, RequirementIds),
    require_unique(RequirementIds, requirement_id),
    get_dict(invariants, State, Invariants0),
    reverse(Invariants0, Invariants),
    state_value(output_contract, State, _{}, OutputContract),
    state_value(provenance, State, _{}, Provenance),
    Spec = _{ schema_version:SchemaVersion,
              subject:Subject,
              requirements:Requirements,
              invariants:Invariants,
              output_contract:OutputContract,
              provenance:Provenance
            }.

/* Inert-data safety ---------------------------------------------------- */

safe_source_data(Value) :-
    require_acyclic(Value, data),
    require_ground(Value, data),
    safe_source_data_(Value).

safe_source_data_(Value) :-
    atomic(Value),
    !.
safe_source_data_(Value) :-
    is_dict(Value),
    !,
    dict_pairs(Value, _, Pairs),
    forall(member(Key-Item, Pairs),
           ( atom(Key),
             safe_source_data_(Item)
           )).
safe_source_data_(Values) :-
    is_list(Values),
    !,
    maplist(safe_source_data_, Values).
safe_source_data_(Value) :-
    compound(Value),
    !,
    functor(Value, Name, _),
    (   forbidden_source_functor(Name)
    ->  throw(spec_lang_fault(executable_shaped_data(Name)))
    ;   Value =.. [_|Args],
        maplist(safe_source_data_, Args)
    ).
safe_source_data_(Value) :-
    throw(spec_lang_fault(unsupported_data(Value))).

forbidden_source_functor((:-)).
forbidden_source_functor((?-)).
forbidden_source_functor((:)).
forbidden_source_functor(call).
forbidden_source_functor(once).
forbidden_source_functor(ignore).
forbidden_source_functor(catch).
forbidden_source_functor(consult).
forbidden_source_functor(asserta).
forbidden_source_functor(assertz).
forbidden_source_functor(retract).
forbidden_source_functor(retractall).
forbidden_source_functor(abolish).
forbidden_source_functor(shell).
forbidden_source_functor(process_create).
forbidden_source_functor(open).
forbidden_source_functor(close).
forbidden_source_functor(use_module).
forbidden_source_functor(ensure_loaded).
forbidden_source_functor(load_files).
forbidden_source_functor(initialization).
forbidden_source_functor(halt).
forbidden_source_functor(working_directory).
forbidden_source_functor(set_prolog_flag).
forbidden_source_functor((,)).
forbidden_source_functor((;)).
forbidden_source_functor((->)).
forbidden_source_functor((*->)).
forbidden_source_functor((\+)).

/* Helpers -------------------------------------------------------------- */

set_singleton(Key, Value, State0, State) :-
    get_dict(Key, State0, Current),
    (   Current == none
    ->  put_dict(Key, State0, Value, State)
    ;   throw(spec_lang_fault(duplicate_singleton(Key)))
    ).

state_value(Key, State, Default, Value) :-
    get_dict(Key, State, Current),
    ( Current == none -> Value = Default ; Value = Current ).

require_state_value(Key, State, Value) :-
    get_dict(Key, State, Current),
    (   Current == none
    ->  throw(spec_lang_fault(missing_form(Key)))
    ;   Value = Current
    ).

option_value(Key, State, Default, Value) :-
    state_value(Key, State, Default, Value).

require_name(Value, _) :- atom(Value), Value \== '', !.
require_name(Value, Name) :- throw(spec_lang_fault(invalid_name(Name, Value))).

require_positive_integer(Value, _) :- integer(Value), Value > 0, !.
require_positive_integer(Value, Name) :-
    throw(spec_lang_fault(invalid_positive_integer(Name, Value))).

require_list(Value, _) :- is_list(Value), !.
require_list(Value, Name) :- throw(spec_lang_fault(invalid_list(Name, Value))).

require_dict(Value, _) :- is_dict(Value), !.
require_dict(Value, Name) :- throw(spec_lang_fault(invalid_dict(Name, Value))).

require_acyclic(Value, _) :- acyclic_term(Value), !.
require_acyclic(_, Name) :- throw(spec_lang_fault(cyclic(Name))).

require_ground(Value, _) :- ground(Value), !.
require_ground(Value, Name) :- throw(spec_lang_fault(non_ground(Name, Value))).

requirement_ids(Requirements, Ids) :-
    findall(Id,
            ( member(Requirement, Requirements), Id = Requirement.id ),
            Ids).

require_unique(Values, _) :-
    sort(Values, Unique),
    length(Values, Count),
    length(Unique, Count),
    !.
require_unique(Values, Kind) :-
    throw(spec_lang_fault(duplicate(Kind, Values))).

require_assertion_outcome(ok(Value), Value) :- !.
require_assertion_outcome(error(Error), _) :-
    throw(spec_lang_fault(assertion_catalog(Error))).

require_spec_outcome(ok(Value), Value) :- !.
require_spec_outcome(error(Error), _) :- throw(spec_lang_fault(spec(Error))).

require_lang_outcome(ok(Value), Value) :- !.
require_lang_outcome(error(Error), _) :- throw(spec_lang_fault(source(Error))).

spec_lang_exception(Phase, spec_lang_fault(Detail), error(Error)) :-
    !,
    Error = spec_lang_error{phase:Phase,
                            kind:spec_language_error,
                            detail:Detail,
                            message:"SPEC authoring input was rejected"}.
spec_lang_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = spec_lang_error{phase:Phase,
                            kind:exception,
                            exception:Safe,
                            message:"SPEC authoring operation raised an exception"}.
