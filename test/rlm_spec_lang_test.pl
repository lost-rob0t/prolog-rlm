:- begin_tests(rlm_spec_lang).

:- use_module('../prolog/rlm_spec_lang').

/* Trusted registry fixtures ------------------------------------------- */

project_registry([
    assertion_provider(project_symbol_exported,
                       1,
                       plunit_rlm_spec_lang:validate_project_symbol_args,
                       plunit_rlm_spec_lang:evaluate_fixture,
                       none,
                       _{ verifier:_{id:project_semantics,version:1},
                          collector:_{id:none,version:1},
                          evidence_policy:_{ required_evidence:false,
                                             source_classes:all,
                                             trust_classes:all,
                                             freshness:any
                                           },
                          latency:pure,
                          description:"require one exported project symbol"
                        })
]).

dataset_registry([
    assertion_provider(record_count,
                       1,
                       plunit_rlm_spec_lang:validate_record_count_args,
                       plunit_rlm_spec_lang:evaluate_fixture,
                       none,
                       _{ verifier:_{id:dataset_semantics,version:1},
                          collector:_{id:none,version:1},
                          evidence_policy:_{ required_evidence:false,
                                             source_classes:all,
                                             trust_classes:all,
                                             freshness:any
                                           },
                          latency:pure,
                          description:"require a minimum record count"
                        })
]).

combined_registry(Registry) :-
    project_registry(Project),
    dataset_registry(Dataset),
    append(Project, Dataset, Registry).

validate_project_symbol_args(Args) :-
    is_dict(Args),
    dict_keys(Args, [module,symbol]),
    atom(Args.module),
    Args.symbol = Name/Arity,
    atom(Name),
    integer(Arity),
    Arity >= 0.

validate_record_count_args(Args) :-
    is_dict(Args),
    dict_keys(Args, [dataset,minimum]),
    atom(Args.dataset),
    integer(Args.minimum),
    Args.minimum >= 0.

evaluate_fixture(_, _, passed).

/* Authoring ------------------------------------------------------------ */

test(normalizes_required_requirement) :-
    Source = spec([
                 subject(dataset(people)),
                 require(minimum_people,
                         assertion(record_count,
                                   _{dataset:people,minimum:3}))
             ]),
    spec_source_normalize(Source, ok(Spec)),
    Spec.subject == dataset(people),
    Spec.requirements = [Requirement],
    Requirement.id == minimum_people,
    Requirement.severity == required,
    Requirement.assertion.kind == record_count.

test(normalizes_optional_requirement) :-
    Source = spec([
                 subject(dataset(people)),
                 optional(minimum_people,
                          assertion(record_count,
                                    _{dataset:people,minimum:3}))
             ]),
    spec_source_normalize(Source, ok(Spec)),
    Spec.requirements = [Requirement],
    Requirement.severity == optional.

test(requirement_options_survive_normalization) :-
    Policy = _{required_evidence:false,
               source_classes:all,
               trust_classes:all,
               freshness:any},
    Provenance = _{source:operator},
    Source = spec([
                 subject(dataset(people)),
                 require(minimum_people,
                         assertion(record_count,
                                   _{dataset:people,minimum:3}),
                         [evidence_policy(Policy),
                          provenance(Provenance)]),
                 invariant(no_silent_requirement_rewrite),
                 output_contract(_{kind:verification_report}),
                 provenance(_{source:operator})
             ]),
    spec_source_normalize(Source, ok(Spec)),
    Spec.requirements = [Requirement],
    Requirement.provenance.source == operator,
    Spec.invariants == [no_silent_requirement_rewrite],
    Spec.output_contract.kind == verification_report,
    Spec.provenance.source == operator.

test(parses_text_source) :-
    Text = "spec([subject(dataset(people)),require(minimum_people,assertion(record_count,_{dataset:people,minimum:3}))])",
    spec_source_normalize(Text, ok(Spec)),
    Spec.subject == dataset(people).

test(duplicate_requirement_ids_are_rejected) :-
    Source = spec([
                 subject(dataset(people)),
                 require(same,
                         assertion(record_count,
                                   _{dataset:people,minimum:1})),
                 require(same,
                         assertion(record_count,
                                   _{dataset:people,minimum:2}))
             ]),
    spec_source_normalize(Source, error(Error)),
    Error.detail = duplicate(requirement_id, _).

test(unknown_structural_symbol_is_rejected) :-
    Source = spec([
                 subject(dataset(people)),
                 plan(do_something),
                 require(minimum_people,
                         assertion(record_count,
                                   _{dataset:people,minimum:3}))
             ]),
    spec_source_normalize(Source, error(Error)),
    Error.detail == unknown_structural_symbol(plan/1).

test(duplicate_singleton_is_rejected) :-
    Source = spec([
                 subject(dataset(people)),
                 subject(dataset(other)),
                 require(minimum_people,
                         assertion(record_count,
                                   _{dataset:people,minimum:3}))
             ]),
    spec_source_normalize(Source, error(Error)),
    Error.detail == duplicate_singleton(subject).

/* Compilation ---------------------------------------------------------- */

test(dataset_spec_compiles_to_frozen_spec) :-
    dataset_registry(Registry),
    Source = spec([
                 subject(dataset(people)),
                 require(minimum_people,
                         assertion(record_count,
                                   _{dataset:people,minimum:3}))
             ]),
    spec_source_compile(Source,
                        Registry,
                        [series(dataset_people),version(1)],
                        ok(Frozen)),
    Frozen.ref.series == dataset_people,
    Frozen.requirements = [Requirement],
    Requirement.assertion.kind == record_count.

test(project_spec_uses_same_grammar) :-
    project_registry(Registry),
    Source = spec([
                 subject(project(prolog_rlm)),
                 require(freeze_api_exists,
                         assertion(project_symbol_exported,
                                   _{module:rlm_spec,
                                     symbol:spec_freeze/3}))
             ]),
    spec_source_compile(Source,
                        Registry,
                        [series(project_api),version(1)],
                        ok(Frozen)),
    Frozen.subject == project(prolog_rlm),
    Frozen.requirements = [Requirement],
    Requirement.assertion.kind == project_symbol_exported.

test(unknown_assertion_kind_fails_registry_validation) :-
    dataset_registry(Registry),
    Source = spec([
                 subject(dataset(people)),
                 require(nope,
                         assertion(not_registered,
                                   _{dataset:people}))
             ]),
    spec_source_compile(Source,
                        Registry,
                        [series(unknown_kind),version(1)],
                        error(_)).

test(invalid_assertion_arguments_fail_provider_validation) :-
    dataset_registry(Registry),
    Source = spec([
                 subject(dataset(people)),
                 require(bad_count,
                         assertion(record_count,
                                   _{dataset:people,minimum:not_an_integer}))
             ]),
    spec_source_compile(Source,
                        Registry,
                        [series(bad_args),version(1)],
                        error(_)).

test(same_semantics_same_fingerprint) :-
    dataset_registry(Registry),
    Source = spec([
                 subject(dataset(people)),
                 require(minimum_people,
                         assertion(record_count,
                                   _{dataset:people,minimum:3}))
             ]),
    spec_source_compile(Source,
                        Registry,
                        [series(stable),version(1)],
                        ok(FrozenA)),
    spec_source_compile(Source,
                        Registry,
                        [series(stable),version(1)],
                        ok(FrozenB)),
    FrozenA.ref.fingerprint == FrozenB.ref.fingerprint.

test(semantic_change_changes_fingerprint) :-
    dataset_registry(Registry),
    SourceA = spec([
                  subject(dataset(people)),
                  require(minimum_people,
                          assertion(record_count,
                                    _{dataset:people,minimum:3}))
              ]),
    SourceB = spec([
                  subject(dataset(people)),
                  require(minimum_people,
                          assertion(record_count,
                                    _{dataset:people,minimum:4}))
              ]),
    spec_source_compile(SourceA,
                        Registry,
                        [series(stable),version(1)],
                        ok(FrozenA)),
    spec_source_compile(SourceB,
                        Registry,
                        [series(stable),version(2)],
                        ok(FrozenB)),
    FrozenA.ref.fingerprint \== FrozenB.ref.fingerprint.

/* Discovery ------------------------------------------------------------ */

test(catalog_combines_structure_and_assertions) :-
    combined_registry(Registry),
    spec_language_catalog(Registry, ok(Catalog)),
    member(Symbol, Catalog.symbols),
    Symbol.name == require,
    member(Assertion, Catalog.assertions),
    Assertion.kind == record_count,
    \+ get_dict(validator, Assertion, _),
    \+ get_dict(evaluator, Assertion, _),
    \+ get_dict(observer, Assertion, _).

/* Adversarial source --------------------------------------------------- */

test(rejects_call_shaped_subject) :-
    Source = spec([
                 subject(call(system_goal)),
                 require(minimum_people,
                         assertion(record_count,
                                   _{dataset:people,minimum:3}))
             ]),
    spec_source_normalize(Source, error(Error)),
    Error.detail == executable_shaped_data(call).

test(rejects_call_shaped_assertion_argument) :-
    Source = spec([
                 subject(dataset(people)),
                 require(minimum_people,
                         assertion(record_count,
                                   _{dataset:people,
                                     minimum:call(3)}))
             ]),
    spec_source_normalize(Source, error(Error)),
    Error.detail == executable_shaped_data(call).

test(rejects_directive_shaped_source) :-
    spec_source_normalize((:- initialization(shell('nope'))), error(_)).

test(rejects_non_ground_source) :-
    Source = spec([
                 subject(dataset(_Name)),
                 require(minimum_people,
                         assertion(record_count,
                                   _{dataset:people,minimum:3}))
             ]),
    spec_source_normalize(Source, error(Error)),
    Error.detail = non_ground(source, _).

:- end_tests(rlm_spec_lang).
