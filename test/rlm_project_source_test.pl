:- begin_tests(rlm_project_source).

:- use_module('../prolog/rlm_project_source').

with_registry(Goal) :-
    setup_call_cleanup(project_source_registry_create(Registry),
                       call(Goal, Registry),
                       project_source_registry_destroy(Registry)).

register_project(Registry, Project) :-
    project_source_project_register(Registry,
                                    Project,
                                    _{origin:test},
                                    ok(project(Project))).

register_file(Registry, Project, Spec, File) :-
    project_source_file_register(Registry, Project, Spec, ok(File)).

fake_grammar(Symbol, Version, Spec) :-
    format(string(Path), '/trusted/grammars/~w.so', [Symbol]),
    Spec = _{identity:package(Symbol, Version),
             library:Path,
             symbol:Symbol,
             abi:unknown,
             version:Version,
             provenance:_{origin:test_fixture}}.

test(two_projects_same_path_do_not_leak) :-
    with_registry(two_projects_same_path_do_not_leak_).

two_projects_same_path_do_not_leak_(Registry) :-
    register_project(Registry, project(alpha)),
    register_project(Registry, project(beta)),
    register_file(Registry,
                  project(alpha),
                  _{id:main, path:"src/main.py", hash:"a1", generation:2},
                  AlphaFile),
    register_file(Registry,
                  project(beta),
                  _{id:main, path:"src/main.py", hash:"b1", generation:7},
                  BetaFile),
    assertion(AlphaFile \== BetaFile),
    assertion(AlphaFile \== "src/main.py"),
    project_source_project_file(Registry, project(alpha), AlphaFile),
    \+ project_source_project_file(Registry, project(alpha), BetaFile),
    project_source_file(Registry, AlphaFile, AlphaRecord),
    project_source_file(Registry, BetaFile, BetaRecord),
    assertion(AlphaRecord.hash == "a1"),
    assertion(AlphaRecord.generation == 2),
    assertion(BetaRecord.hash == "b1"),
    assertion(BetaRecord.generation == 7).

test(extension_detection_is_explicit_evidence) :-
    with_registry(extension_detection_is_explicit_evidence_).

extension_detection_is_explicit_evidence_(Registry) :-
    register_project(Registry, project(alpha)),
    register_file(Registry,
                  project(alpha),
                  _{path:"src/service.py"},
                  File),
    project_source_language_evidence(Registry,
                                     File,
                                     python,
                                     extension('.py'),
                                     0.75),
    project_source_file_language(Registry, File, ok(Resolution)),
    assertion(Resolution.status == known),
    assertion(Resolution.language == python),
    assertion(Resolution.backend == tree_sitter).

test(no_evidence_is_unknown) :-
    with_registry(no_evidence_is_unknown_).

no_evidence_is_unknown_(Registry) :-
    register_project(Registry, project(alpha)),
    register_file(Registry, project(alpha), _{path:"README.odd"}, File),
    project_source_file_language(Registry, File, ok(Resolution)),
    assertion(Resolution.status == unknown),
    assertion(Resolution.language == unknown).

test(conflicting_extension_and_shebang_are_ambiguous) :-
    with_registry(conflicting_extension_and_shebang_are_ambiguous_).

conflicting_extension_and_shebang_are_ambiguous_(Registry) :-
    register_project(Registry, project(alpha)),
    register_file(Registry,
                  project(alpha),
                  _{path:"bin/tool.py", shebang:"#!/usr/bin/env node"},
                  File),
    project_source_file_language(Registry, File, ok(Resolution)),
    assertion(Resolution.status == ambiguous),
    assertion(Resolution.candidates == [javascript, python]).

test(host_override_is_distinct_and_wins) :-
    with_registry(host_override_is_distinct_and_wins_).

host_override_is_distinct_and_wins_(Registry) :-
    register_project(Registry, project(alpha)),
    register_file(Registry,
                  project(alpha),
                  _{path:"bin/tool.py", shebang:"#!/usr/bin/env node"},
                  File),
    project_source_file_language_override(Registry,
                                          File,
                                          javascript,
                                          _{actor:operator},
                                          ok(_)),
    project_source_file_language(Registry, File, ok(Resolution)),
    assertion(Resolution.status == explicit_override),
    assertion(Resolution.language == javascript),
    assertion(Resolution.support == known(tree_sitter)).

test(explicit_override_can_name_unsupported_language) :-
    with_registry(explicit_override_can_name_unsupported_language_).

explicit_override_can_name_unsupported_language_(Registry) :-
    register_project(Registry, project(alpha)),
    register_file(Registry, project(alpha), _{path:"data/blob"}, File),
    project_source_file_language_override(Registry,
                                          File,
                                          mystery_language,
                                          _{actor:operator},
                                          ok(_)),
    project_source_file_language(Registry, File, ok(Resolution)),
    assertion(Resolution.status == explicit_override),
    assertion(Resolution.support == unsupported(no_parser_backend)),
    parser_for_file(Registry, File, ok(Parser)),
    assertion(Parser.status == unsupported),
    assertion(Parser.reason == no_parser_backend).

test(tree_sitter_language_without_grammar_is_unsupported_for_parsing) :-
    with_registry(tree_sitter_language_without_grammar_is_unsupported_for_parsing_).

tree_sitter_language_without_grammar_is_unsupported_for_parsing_(Registry) :-
    register_project(Registry, project(alpha)),
    register_file(Registry, project(alpha), _{path:"src/app.js"}, File),
    parser_for_file(Registry, File, ok(Parser)),
    assertion(Parser.status == unsupported),
    assertion(Parser.language == javascript),
    assertion(Parser.backend == tree_sitter),
    assertion(Parser.reason == missing_grammar),
    grammar_for_file(Registry, File, ok(Grammar)),
    assertion(Grammar.status == unsupported),
    assertion(Grammar.reason == missing_grammar).

test(prolog_uses_swi_native_backend) :-
    with_registry(prolog_uses_swi_native_backend_).

prolog_uses_swi_native_backend_(Registry) :-
    register_project(Registry, project(alpha)),
    register_file(Registry, project(alpha), _{path:"prolog/app.pl"}, File),
    parser_for_file(Registry, File, ok(Parser)),
    assertion(Parser.status == ready),
    assertion(Parser.language == prolog),
    assertion(Parser.backend == swi_native),
    grammar_for_file(Registry, File, ok(Grammar)),
    assertion(Grammar.status == not_applicable),
    assertion(Grammar.backend == swi_native).

test(grammar_registration_is_declarative_for_python_js_nim_and_fourth_language) :-
    with_registry(grammar_registration_is_declarative_for_python_js_nim_and_fourth_language_).

grammar_registration_is_declarative_for_python_js_nim_and_fourth_language_(Registry) :-
    fake_grammar(tree_sitter_python, "1.0", Python),
    fake_grammar(tree_sitter_javascript, "1.0", Javascript),
    fake_grammar(tree_sitter_nim, "1.0", Nim),
    fake_grammar(tree_sitter_lua, "1.0", Lua),
    ts_grammar_register(Registry, python, Python, ok(_)),
    ts_grammar_register(Registry, javascript, Javascript, ok(_)),
    ts_grammar_register(Registry, nim, Nim, ok(_)),
    ts_grammar_register(Registry, lua, Lua, ok(_)),
    ts_grammars(Registry, Grammars),
    assertion(length(Grammars, 4)),
    forall(member(Grammar, Grammars),
           assertion(Grammar.state == configured)).

test(grammar_identity_is_not_raw_library_path) :-
    with_registry(grammar_identity_is_not_raw_library_path_).

grammar_identity_is_not_raw_library_path_(Registry) :-
    fake_grammar(tree_sitter_python, "1.0", Spec),
    ts_grammar_register(Registry, python, Spec, ok(Ref)),
    ts_grammar(Registry, python, Grammar),
    assertion(Ref == Grammar.ref),
    assertion(Grammar.ref \== Grammar.library),
    assertion(Grammar.identity == package(tree_sitter_python, "1.0")).

test(registered_grammar_makes_tree_sitter_parser_configured_without_loading_it) :-
    with_registry(registered_grammar_makes_tree_sitter_parser_configured_without_loading_it_).

registered_grammar_makes_tree_sitter_parser_configured_without_loading_it_(Registry) :-
    register_project(Registry, project(alpha)),
    register_file(Registry, project(alpha), _{path:"src/app.py"}, File),
    fake_grammar(tree_sitter_python, "1.0", Spec),
    ts_grammar_register(Registry, python, Spec, ok(Ref)),
    parser_for_file(Registry, File, ok(Parser)),
    assertion(Parser.status == configured),
    assertion(Parser.grammar_ref == Ref),
    assertion(Parser.activation == inactive),
    grammar_for_file(Registry, File, ok(Selection)),
    assertion(Selection.status == configured),
    assertion(Selection.grammar.state == configured).

test(grammar_unregister_and_reregister_changes_versioned_identity) :-
    with_registry(grammar_unregister_and_reregister_changes_versioned_identity_).

grammar_unregister_and_reregister_changes_versioned_identity_(Registry) :-
    fake_grammar(tree_sitter_python, "1.0", Spec1),
    fake_grammar(tree_sitter_python, "2.0", Spec2),
    ts_grammar_register(Registry, python, Spec1, ok(Ref1)),
    ts_grammar_unregister(Registry, python, ok(unregistered(Ref1, inactive))),
    \+ ts_grammar(Registry, python, _),
    ts_grammar_register(Registry, python, Spec2, ok(Ref2)),
    assertion(Ref1 \== Ref2).

test(file_metadata_preserves_excluded_vendor_generated_and_regions) :-
    with_registry(file_metadata_preserves_excluded_vendor_generated_and_regions_).

file_metadata_preserves_excluded_vendor_generated_and_regions_(Registry) :-
    register_project(Registry, project(alpha)),
    register_file(Registry,
                  project(alpha),
                  _{path:"vendor/generated.js",
                    hash:"abc",
                    generation:9,
                    excluded:true,
                    vendor:true,
                    generated:true,
                    embedded_regions:[region(html, 0, 10)]},
                  File),
    project_source_file(Registry, File, Record),
    assertion(Record.excluded == true),
    assertion(Record.vendor == true),
    assertion(Record.generated == true),
    assertion(Record.embedded_regions == [region(html, 0, 10)]).

test(custom_language_backend_is_registry_data) :-
    with_registry(custom_language_backend_is_registry_data_).

custom_language_backend_is_registry_data_(Registry) :-
    project_source_language_register(Registry,
                                     custom_lang,
                                     external(custom_parser),
                                     _{origin:test},
                                     ok(language(custom_lang))),
    project_source_language_parser(Registry,
                                   custom_lang,
                                   external(custom_parser)).

test(destroyed_registry_fails_structurally) :-
    project_source_registry_create(Registry),
    project_source_registry_destroy(Registry),
    project_source_project_register(Registry,
                                    project(alpha),
                                    _{},
                                    error(Error)),
    assertion(Error.kind == invalid_registry).

:- end_tests(rlm_project_source).
