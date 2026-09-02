:- begin_tests(rlm_project_syntax).

:- use_module('../prolog/rlm_project_source').
:- use_module('../prolog/rlm_project_syntax').
:- use_module('../prolog/rlm_async').
:- use_module(library(crypto)).

:- dynamic project_syntax_test_directory/1.
:- prolog_load_context(directory, TestDirectory),
   assertz(project_syntax_test_directory(TestDirectory)).

fixture_path(Language, Path) :-
    project_syntax_test_directory(TestDirectory),
    current_prolog_flag(shared_object_extension, Extension),
    atomic_list_concat([Language, Extension], '.', FileName),
    directory_file_path(TestDirectory, 'fixtures/tree-sitter', FixtureDirectory),
    directory_file_path(FixtureDirectory, FileName, Path).

fixture_symbol(c, tree_sitter_c).
fixture_symbol(python, tree_sitter_python).
fixture_symbol(javascript, tree_sitter_javascript).
fixture_symbol(markdown, tree_sitter_markdown).
fixture_symbol(json, tree_sitter_json).
fixture_symbol(org, tree_sitter_org).
fixture_symbol(common_lisp, tree_sitter_commonlisp).
fixture_symbol(nim, tree_sitter_nim).

with_syntax_registry(Goal) :-
    setup_call_cleanup(project_source_registry_create(Registry),
                       call(Goal, Registry),
                       project_source_registry_destroy(Registry)).

register_project(Registry) :-
    project_source_project_register(Registry,
                                    project(syntax_fixture),
                                    _{origin:test},
                                    ok(project(project(syntax_fixture)))).

register_file(Registry, Id, Path, File) :-
    project_source_file_register(Registry,
                                 project(syntax_fixture),
                                 _{id:Id,
                                   path:Path,
                                   generation:1,
                                   provenance:_{origin:test}},
                                 ok(File)).

activate_fixture(Registry, Fixture, Language) :-
    fixture_path(Fixture, Path),
    fixture_symbol(Fixture, Symbol),
    Spec = _{identity:ci_fixture(Fixture),
             library:Path,
             symbol:Symbol,
             abi:unknown,
             version:"fixture-v1",
             provenance:_{origin:ci_fixture}},
    ts_grammar_register(Registry, Language, Spec, ok(_)),
    ts_grammar_activate(Registry, Language, ok(activated(_))).

test(materializes_named_nodes_fields_ranges_and_provenance, [nondet]) :-
    with_syntax_registry(materializes_named_nodes_fields_ranges_and_provenance_).

materializes_named_nodes_fields_ranges_and_provenance_(Registry) :-
    register_project(Registry),
    register_file(Registry, main, "src/main.c", File),
    activate_fixture(Registry, c, c),
    Source = "int add(int a, int b) { return a + b; }",
    project_syntax_materialize(Registry,
                               File,
                               Source,
                               [mode(named), max_nodes(100), max_depth(32)],
                               ok(Summary)),
    assertion(Summary.status == complete),
    assertion(Summary.node_count > 0),
    Parse = Summary.parse,
    assertion(Parse = syntax_parse(File, 1)),
    project_syntax_node(Registry, Function, Parse, function_definition),
    project_syntax_field(Registry, Function, declarator, Declarator),
    project_syntax_node(Registry, Declarator, Parse, function_declarator),
    project_syntax_span(Registry, Function, Span),
    assertion(Span.file == File),
    assertion(Span.start_byte < Span.end_byte),
    project_syntax_node_provenance(Registry, Function, Provenance),
    assertion(Provenance.project == project(syntax_fixture)),
    assertion(Provenance.file == File),
    assertion(Provenance.parse == Parse),
    assertion(Provenance.grammar_ref = grammar_ref(c, _)),
    assertion(\+ project_syntax_node(Registry, _, Parse, ';')),
    assertion(\+ sub_term('$BLOB'(_), Function)).

json_fixture_available :-
    fixture_path(json, Path),
    exists_file(Path).

test(json_document_uses_the_same_generic_projection,
     [condition(json_fixture_available), nondet]) :-
    with_syntax_registry(json_document_uses_the_same_generic_projection_).

json_document_uses_the_same_generic_projection_(Registry) :-
    register_project(Registry),
    register_file(Registry, manifest, "package.json", File),
    activate_fixture(Registry, json, json),
    project_syntax_materialize(Registry,
                               File,
                               "{\"name\":\"project-kb\",\"private\":true}",
                               [mode(named)],
                               ok(Summary)),
    project_syntax_node(Registry, Root, Summary.parse, document),
    project_syntax_node_text(Registry, Root, [], ok(Text)),
    assertion(Text == "{\"name\":\"project-kb\",\"private\":true}").

bundle_fixtures_available :-
    forall(member(Fixture,
                  [python, javascript, markdown, json, org, common_lisp, nim]),
           ( fixture_path(Fixture, Path),
             exists_file(Path)
           )).

bundle_case(python, python, "src/example.py", "def answer():\n    return 42\n").
bundle_case(javascript,
            javascript,
            "src/example.js",
            "function answer() { return 42; }\n").
bundle_case(markdown, markdown, "README.md", "# Project KB\n\nState.\n").
bundle_case(json, json, "package.json", "{\"private\":true}\n").
bundle_case(org, org, "notes.org", "* Project KB\nState.\n").
bundle_case(common_lisp,
            common_lisp,
            "src/example.lisp",
            "(defun answer () 42)\n").
bundle_case(nim, nim, "src/example.nim", "proc answer(): int = 42\n").

test(standard_code_and_document_grammars_share_projection,
     [condition(bundle_fixtures_available), nondet]) :-
    with_syntax_registry(standard_code_and_document_grammars_share_projection_).

standard_code_and_document_grammars_share_projection_(Registry) :-
    register_project(Registry),
    forall(bundle_case(Fixture, Language, Path, Source),
           ( atom_concat(Language, '_fixture', Id),
             register_file(Registry, Id, Path, File),
             activate_fixture(Registry, Fixture, Language),
             project_syntax_materialize(Registry,
                                        File,
                                        Source,
                                        [mode(named)],
                                        ok(Summary)),
             Root = syntax_node(Summary.parse, []),
             project_syntax_node(Registry, Root, Summary.parse, RootType),
             assertion(atom(RootType)),
             assertion(Summary.node_count > 0)
           )).

test(new_parse_generation_makes_old_generation_explicitly_stale, [nondet]) :-
    with_syntax_registry(new_parse_generation_makes_old_generation_explicitly_stale_).

new_parse_generation_makes_old_generation_explicitly_stale_(Registry) :-
    register_project(Registry),
    register_file(Registry, main, "src/main.c", File),
    activate_fixture(Registry, c, c),
    project_syntax_materialize(Registry, File, "int x;", [], ok(First)),
    project_syntax_node(Registry, OldRoot, First.parse, translation_unit),
    project_syntax_materialize(Registry, File, "int y;", [], ok(Second)),
    assertion(First.parse \== Second.parse),
    project_syntax_current_parse(Registry, File, Second.parse),
    project_syntax_parse_record(Registry, First.parse, OldRecord),
    project_syntax_parse_record(Registry, Second.parse, NewRecord),
    assertion(OldRecord.currentness == stale),
    assertion(NewRecord.currentness == current),
    project_syntax_node_text(Registry,
                             OldRoot,
                             [],
                             error(StaleError)),
    assertion(StaleError.kind == stale_parse),
    project_syntax_node_text(Registry,
                             OldRoot,
                             [allow_stale(true)],
                             ok("int x;")).

test(utf8_text_lookup_uses_tree_sitter_byte_ranges, [nondet]) :-
    with_syntax_registry(utf8_text_lookup_uses_tree_sitter_byte_ranges_).

utf8_text_lookup_uses_tree_sitter_byte_ranges_(Registry) :-
    register_project(Registry),
    register_file(Registry, unicode, "src/unicode.c", File),
    activate_fixture(Registry, c, c),
    project_syntax_materialize(Registry,
                               File,
                               "/* π */ int value;",
                               [mode(all)],
                               ok(Summary)),
    project_syntax_node(Registry, Comment, Summary.parse, comment),
    project_syntax_node_text(Registry, Comment, [], ok(Text)),
    assertion(Text == "/* π */").

test(recovered_malformed_source_materializes_error_observations, [nondet]) :-
    with_syntax_registry(recovered_malformed_source_materializes_error_observations_).

recovered_malformed_source_materializes_error_observations_(Registry) :-
    register_project(Registry),
    register_file(Registry, malformed, "src/malformed.c", File),
    activate_fixture(Registry, c, c),
    project_syntax_materialize(Registry,
                               File,
                               "int main(",
                               [mode(all)],
                               ok(Summary)),
    assertion(Summary.tree_status == recovered_with_errors),
    findall(Kind,
            project_syntax_error(Registry, _, Kind),
            Kinds),
    assertion(Kinds \== []).

test(node_limit_publishes_partial_not_complete, [nondet]) :-
    with_syntax_registry(node_limit_publishes_partial_not_complete_).

node_limit_publishes_partial_not_complete_(Registry) :-
    register_project(Registry),
    register_file(Registry, bounded, "src/bounded.c", File),
    activate_fixture(Registry, c, c),
    project_syntax_materialize(Registry,
                               File,
                               "int a; int b; int c;",
                               [mode(all), max_nodes(2)],
                               partial(Summary)),
    assertion(Summary.status == partial),
    assertion(Summary.reason == limit(max_nodes, 2)),
    project_syntax_parse_record(Registry, Summary.parse, Record),
    assertion(Record.status == partial).

test(source_byte_limit_blocks_without_publishing_a_parse) :-
    with_syntax_registry(source_byte_limit_blocks_without_publishing_a_parse_).

source_byte_limit_blocks_without_publishing_a_parse_(Registry) :-
    register_project(Registry),
    register_file(Registry, bounded, "src/bounded.c", File),
    activate_fixture(Registry, c, c),
    project_syntax_materialize(Registry,
                               File,
                               "int too_large;",
                               [max_source_bytes(3)],
                               blocked(Error)),
    assertion(Error.kind == source_limit),
    assertion(\+ project_syntax_current_parse(Registry, File, _)).

test(depth_limit_is_an_explicit_partial_generation, [nondet]) :-
    with_syntax_registry(depth_limit_is_an_explicit_partial_generation_).

depth_limit_is_an_explicit_partial_generation_(Registry) :-
    register_project(Registry),
    register_file(Registry, deep, "src/deep.c", File),
    activate_fixture(Registry, c, c),
    project_syntax_materialize(Registry,
                               File,
                               "int main(void) { return (((1))); }",
                               [mode(all), max_depth(1)],
                               partial(Summary)),
    assertion(Summary.reason == limit(max_depth, 1)).

test(empty_file_is_a_complete_parse_generation, [nondet]) :-
    with_syntax_registry(empty_file_is_a_complete_parse_generation_).

empty_file_is_a_complete_parse_generation_(Registry) :-
    register_project(Registry),
    register_file(Registry, empty, "src/empty.c", File),
    activate_fixture(Registry, c, c),
    project_syntax_materialize(Registry, File, "", [], ok(Summary)),
    assertion(Summary.status == complete),
    project_syntax_node(Registry, _, Summary.parse, translation_unit).

test(identical_source_in_two_files_has_distinct_node_identity, [nondet]) :-
    with_syntax_registry(identical_source_in_two_files_has_distinct_node_identity_).

identical_source_in_two_files_has_distinct_node_identity_(Registry) :-
    register_project(Registry),
    register_file(Registry, one, "src/one.c", FirstFile),
    register_file(Registry, two, "src/two.c", SecondFile),
    activate_fixture(Registry, c, c),
    project_syntax_materialize(Registry, FirstFile, "int x;", [], ok(First)),
    project_syntax_materialize(Registry, SecondFile, "int x;", [], ok(Second)),
    project_syntax_node(Registry, FirstRoot, First.parse, translation_unit),
    project_syntax_node(Registry, SecondRoot, Second.parse, translation_unit),
    assertion(FirstRoot \== SecondRoot).

test(generated_file_requires_explicit_inclusion, [nondet]) :-
    with_syntax_registry(generated_file_requires_explicit_inclusion_).

generated_file_requires_explicit_inclusion_(Registry) :-
    register_project(Registry),
    project_source_file_register(Registry,
                                 project(syntax_fixture),
                                 _{id:generated,
                                   path:"src/generated.c",
                                   generated:true},
                                 ok(File)),
    activate_fixture(Registry, c, c),
    project_syntax_materialize(Registry,
                               File,
                               "int generated;",
                               [],
                               blocked(Error)),
    assertion(Error.kind == file_policy),
    project_syntax_materialize(Registry,
                               File,
                               "int generated;",
                               [include_generated(true)],
                               ok(_)).

test(node_text_limit_is_structured, [nondet]) :-
    with_syntax_registry(node_text_limit_is_structured_).

node_text_limit_is_structured_(Registry) :-
    register_project(Registry),
    register_file(Registry, text_limit, "src/text_limit.c", File),
    activate_fixture(Registry, c, c),
    project_syntax_materialize(Registry, File, "int value;", [], ok(Summary)),
    project_syntax_node(Registry, Root, Summary.parse, translation_unit),
    project_syntax_node_text(Registry, Root, [max_bytes(2)], blocked(Error)),
    assertion(Error.kind == text_limit).

test(registry_destroy_removes_materialized_observations, [nondet]) :-
    project_source_registry_create(Registry),
    register_project(Registry),
    register_file(Registry, cleanup, "src/cleanup.c", File),
    activate_fixture(Registry, c, c),
    project_syntax_materialize(Registry, File, "int cleanup;", [], ok(Summary)),
    project_source_registry_destroy(Registry),
    assertion(\+ project_syntax_parse_record(Registry, Summary.parse, _)),
    assertion(\+ project_syntax_node(Registry, _, Summary.parse, _)).

test(async_and_sync_materialization_share_execute_path, [nondet]) :-
    with_syntax_registry(async_and_sync_materialization_share_execute_path_).

async_and_sync_materialization_share_execute_path_(Registry) :-
    register_project(Registry),
    register_file(Registry, async, "src/async.c", File),
    activate_fixture(Registry, c, c),
    project_syntax_materialize_async(Registry,
                                     File,
                                     "int async_value;",
                                     [],
                                     Future),
    setup_call_cleanup(true,
                       rlm_future_await(Future, ok(First)),
                       rlm_future_destroy(Future)),
    project_syntax_materialize(Registry,
                               File,
                               "int sync_value;",
                               [],
                               ok(Second)),
    assertion(First.parse \== Second.parse),
    project_syntax_current_parse(Registry, File, Second.parse).

test(blocked_changed_refresh_invalidates_previous_current, [nondet]) :-
    with_syntax_registry(blocked_changed_refresh_invalidates_previous_current_).

blocked_changed_refresh_invalidates_previous_current_(Registry) :-
    register_project(Registry),
    register_file(Registry, refresh, "src/refresh.c", File),
    activate_fixture(Registry, c, c),
    project_syntax_materialize(Registry, File, "int old;", [], ok(First)),
    project_syntax_materialize(Registry,
                               File,
                               "int changed;",
                               [max_source_bytes(1)],
                               blocked(Error)),
    assertion(Error.kind == source_limit),
    assertion(\+ project_syntax_current_parse(Registry, File, _)),
    project_syntax_parse_record(Registry, First.parse, OldRecord),
    assertion(OldRecord.currentness == stale).

test(registered_content_hash_must_match_supplied_source, [nondet]) :-
    with_syntax_registry(registered_content_hash_must_match_supplied_source_).

registered_content_hash_must_match_supplied_source_(Registry) :-
    register_project(Registry),
    crypto_data_hash("int expected;",
                     Digest,
                     [algorithm(sha256), encoding(utf8)]),
    atom_concat('sha256:', Digest, RegisteredHash),
    project_source_file_register(Registry,
                                 project(syntax_fixture),
                                 _{id:hashed,
                                   path:"src/hashed.c",
                                   hash:RegisteredHash},
                                 ok(File)),
    activate_fixture(Registry, c, c),
    project_syntax_materialize(Registry,
                               File,
                               "int expected;",
                               [],
                               ok(Valid)),
    project_syntax_materialize(Registry,
                               File,
                               "int unrelated;",
                               [],
                               error(Error)),
    assertion(Error.kind == source_hash_mismatch),
    project_syntax_current_parse(Registry, File, Valid.parse),
    project_syntax_parse_record(Registry, Valid.parse, Record),
    assertion(Record.currentness == current).

test(older_generation_cannot_replace_newer_current, [nondet]) :-
    with_syntax_registry(older_generation_cannot_replace_newer_current_).

older_generation_cannot_replace_newer_current_(Registry) :-
    register_project(Registry),
    register_file(Registry, ordered, "src/ordered.c", File),
    rlm_project_syntax:reserve_parse_admission(Registry,
                                               File,
                                               OldGeneration),
    rlm_project_syntax:complete_parse_admission(Registry,
                                                File,
                                                OldGeneration,
                                                old),
    rlm_project_syntax:reserve_parse_admission(Registry,
                                               File,
                                               NewGeneration),
    rlm_project_syntax:complete_parse_admission(Registry,
                                                File,
                                                NewGeneration,
                                                new),
    NewParse = syntax_parse(File, NewGeneration),
    OldParse = syntax_parse(File, OldGeneration),
    NewRecord = project_syntax_parse{parse:NewParse,
                                     generation:NewGeneration,
                                     content_hash:new,
                                     currentness:current},
    OldRecord = project_syntax_parse{parse:OldParse,
                                     generation:OldGeneration,
                                     content_hash:old,
                                     currentness:current},
    rlm_project_syntax:publish_parse(Registry,
                                     File,
                                     NewParse,
                                     NewRecord,
                                     "new",
                                     []),
    rlm_project_syntax:publish_parse(Registry,
                                     File,
                                     OldParse,
                                     OldRecord,
                                     "old",
                                     []),
    project_syntax_current_parse(Registry, File, NewParse),
    project_syntax_parse_record(Registry, OldParse, PublishedOld),
    assertion(PublishedOld.currentness == stale).

large_c_source(Source) :-
    length(Statements, 50000),
    maplist(=("int value;\n"), Statements),
    atomics_to_string(Statements, Source).

test(materialization_deadline_is_structured_and_publishes_no_current,
     [nondet]) :-
    with_syntax_registry(materialization_deadline_is_structured_and_publishes_no_current_).

materialization_deadline_is_structured_and_publishes_no_current_(Registry) :-
    register_project(Registry),
    register_file(Registry, deadline, "src/deadline.c", File),
    activate_fixture(Registry, c, c),
    large_c_source(Source),
    project_syntax_materialize(Registry,
                               File,
                               Source,
                               [max_source_bytes(1000000),
                                timeout_seconds(0.000001)],
                               error(Error)),
    assertion(Error.kind == timeout),
    assertion(\+ project_syntax_current_parse(Registry, File, _)).

test(cancelled_future_publishes_no_current, [nondet]) :-
    with_syntax_registry(cancelled_future_publishes_no_current_).

cancelled_future_publishes_no_current_(Registry) :-
    register_project(Registry),
    register_file(Registry, cancelled, "src/cancelled.c", File),
    activate_fixture(Registry, c, c),
    large_c_source(Source),
    project_syntax_materialize_async(Registry,
                                     File,
                                     Source,
                                     [max_source_bytes(1000000)],
                                     Future),
    setup_call_cleanup(
        true,
        ( rlm_future_cancel(Future, ok(cancelled)),
          rlm_future_await(Future, error(Error)),
          assertion(Error.kind == cancelled)
        ),
        rlm_future_destroy(Future)),
    assertion(\+ project_syntax_current_parse(Registry, File, _)).

:- end_tests(rlm_project_syntax).
