:- begin_tests(rlm_project_source_native).

:- use_module('../prolog/rlm_tree_sitter').
:- use_module('../prolog/rlm_project_source').

:- dynamic project_source_test_directory/1.
:- prolog_load_context(directory, TestDirectory),
   assertz(project_source_test_directory(TestDirectory)).

fixture_path(Language, Path) :-
    project_source_test_directory(TestDirectory),
    current_prolog_flag(shared_object_extension, Extension),
    atomic_list_concat([Language, Extension], '.', FileName),
    directory_file_path(TestDirectory, 'fixtures/tree-sitter', FixtureDirectory),
    directory_file_path(FixtureDirectory, FileName, Path).

fixture_symbol(c, tree_sitter_c).
fixture_symbol(lua, tree_sitter_lua).
fixture_symbol(query, tree_sitter_query).

fixture_registry_language(c, c).
fixture_registry_language(lua, lua).
fixture_registry_language(query, tree_sitter_query).

with_native_registry(Goal) :-
    setup_call_cleanup(project_source_registry_create(Registry),
                       call(Goal, Registry),
                       project_source_registry_destroy(Registry)).

require_outcome(Outcome, Pattern, Context) :-
    (   Outcome = Pattern
    ->  true
    ;   throw(error(unexpected_outcome(Context, Outcome),
                    rlm_project_source_native_test))
    ).

register_fixture_grammar(Registry, Fixture, Language, Ref) :-
    fixture_path(Fixture, Path),
    fixture_symbol(Fixture, Symbol),
    fixture_registry_language(Fixture, Language),
    Spec = _{identity:ci_fixture(Fixture),
             library:Path,
             symbol:Symbol,
             abi:unknown,
             version:"fixture-v1",
             provenance:_{origin:ci_fixture}},
    ts_grammar_register(Registry, Language, Spec, Outcome),
    require_outcome(Outcome, ok(Ref), register(Fixture, Language)).

activate_grammar(Registry, Language, Activation) :-
    ts_grammar_activate(Registry, Language, Outcome),
    require_outcome(Outcome,
                    ok(activated(Activation)),
                    activate(Language)).

test(activates_three_grammars_through_one_registry_api) :-
    with_native_registry(activates_three_grammars_through_one_registry_api_).

activates_three_grammars_through_one_registry_api_(Registry) :-
    forall(member(Fixture, [c, lua, query]),
           ( register_fixture_grammar(Registry, Fixture, Language, Ref),
             activate_grammar(Registry, Language, Activation),
             assertion(Activation.grammar_ref == Ref),
             assertion(integer(Activation.abi)),
             ts_grammar(Registry, Language, Grammar),
             assertion(Grammar.state == active),
             assertion(Grammar.ref == Ref)
           )).

test(active_grammar_makes_parser_selection_ready) :-
    with_native_registry(active_grammar_makes_parser_selection_ready_).

active_grammar_makes_parser_selection_ready_(Registry) :-
    project_source_project_register(Registry,
                                    project(native_fixture),
                                    _{origin:test},
                                    ProjectOutcome),
    require_outcome(ProjectOutcome,
                    ok(project(project(native_fixture))),
                    register_project),
    project_source_file_register(Registry,
                                 project(native_fixture),
                                 _{id:main, path:"src/main.c", hash:"c1", generation:3},
                                 FileOutcome),
    require_outcome(FileOutcome, ok(File), register_file),
    register_fixture_grammar(Registry, c, c, Ref),
    activate_grammar(Registry, c, _),
    parser_for_file(Registry, File, ParserOutcome),
    require_outcome(ParserOutcome, ok(Parser), parser_for_file),
    assertion(Parser.status == ready),
    assertion(Parser.backend == tree_sitter),
    assertion(Parser.grammar_ref == Ref),
    assertion(Parser.grammar_state == active),
    grammar_for_file(Registry, File, GrammarOutcome),
    require_outcome(GrammarOutcome, ok(Selection), grammar_for_file),
    assertion(Selection.status == ready),
    assertion(Selection.grammar.state == active).

test(deactivate_and_reactivate_are_explicit) :-
    with_native_registry(deactivate_and_reactivate_are_explicit_).

deactivate_and_reactivate_are_explicit_(Registry) :-
    register_fixture_grammar(Registry, lua, lua, _),
    activate_grammar(Registry, lua, First),
    ts_grammar_deactivate(Registry, lua, DeactivateOutcome),
    require_outcome(DeactivateOutcome,
                    ok(deactivated(First)),
                    deactivate(lua)),
    ts_grammar(Registry, lua, Configured),
    assertion(Configured.state == configured),
    activate_grammar(Registry, lua, Second),
    assertion(Second.grammar_ref == First.grammar_ref).

test(unregister_active_grammar_releases_activation) :-
    with_native_registry(unregister_active_grammar_releases_activation_).

unregister_active_grammar_releases_activation_(Registry) :-
    register_fixture_grammar(Registry, query, tree_sitter_query, Ref),
    activate_grammar(Registry, tree_sitter_query, Activation),
    ts_grammar_unregister(Registry, tree_sitter_query, UnregisterOutcome),
    require_outcome(UnregisterOutcome,
                    ok(unregistered(Ref, Activation)),
                    unregister(tree_sitter_query)),
    \+ ts_grammar(Registry, tree_sitter_query, _).

test(incompatible_grammar_is_structured_before_use) :-
    with_native_registry(incompatible_grammar_is_structured_before_use_).

incompatible_grammar_is_structured_before_use_(Registry) :-
    fixture_path('c-incompatible', Path),
    Spec = _{identity:ci_fixture(c_incompatible),
             library:Path,
             symbol:tree_sitter_c,
             abi:unknown,
             version:"fixture-incompatible",
             provenance:_{origin:ci_fixture}},
    ts_grammar_register(Registry, c, Spec, RegisterOutcome),
    require_outcome(RegisterOutcome, ok(_), register(c_incompatible)),
    ts_grammar_activate(Registry, c, ActivateOutcome),
    require_outcome(ActivateOutcome, error(Error), activate(c_incompatible)),
    assertion(Error.kind == incompatible_grammar),
    ts_grammar(Registry, c, Grammar),
    assertion(Grammar.state == configured).

test(declared_abi_mismatch_is_structured) :-
    with_native_registry(declared_abi_mismatch_is_structured_).

declared_abi_mismatch_is_structured_(Registry) :-
    fixture_path(c, Path),
    Spec = _{identity:ci_fixture(c_wrong_declared_abi),
             library:Path,
             symbol:tree_sitter_c,
             abi:999999,
             version:"fixture-wrong-abi",
             provenance:_{origin:ci_fixture}},
    ts_grammar_register(Registry, c, Spec, RegisterOutcome),
    require_outcome(RegisterOutcome, ok(_), register(c_wrong_declared_abi)),
    ts_grammar_activate(Registry, c, ActivateOutcome),
    require_outcome(ActivateOutcome, error(Error), activate(c_wrong_declared_abi)),
    assertion(Error.kind == declared_abi_mismatch),
    ts_grammar(Registry, c, Grammar),
    assertion(Grammar.state == configured).

:- end_tests(rlm_project_source_native).
