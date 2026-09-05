:- begin_tests(rlm_project_query).

:- use_module('../prolog/rlm_project_source').
:- use_module('../prolog/rlm_project_query').
:- use_module(library(filesex)).

:- dynamic project_query_test_directory/1.
:- prolog_load_context(directory, TestDirectory),
   assertz(project_query_test_directory(TestDirectory)).

fixture_path(Language, Path) :-
    project_query_test_directory(TestDirectory),
    current_prolog_flag(shared_object_extension, Extension),
    atomic_list_concat([Language, Extension], '.', FileName),
    directory_file_path(TestDirectory, 'fixtures/tree-sitter', FixtureDirectory),
    directory_file_path(FixtureDirectory, FileName, Path).

fixture_symbol(c, tree_sitter_c).
fixture_symbol(python, tree_sitter_python).
fixture_symbol(javascript, tree_sitter_javascript).

with_query_registry(Goal) :-
    tmp_file(project_query_root, Root),
    make_directory_path(Root),
    setup_call_cleanup(
        project_source_registry_create(Registry),
        call(Goal, Registry, Root),
        ( project_source_registry_destroy(Registry),
          catch(delete_directory_and_contents(Root), _, true)
        )
    ).

register_project(Registry, Root) :-
    project_source_project_register(Registry,
                                    project(query_fixture),
                                    _{origin:test, project_root:Root},
                                    ok(project(project(query_fixture)))).

register_file(Registry, Id, Path, File) :-
    project_source_file_register(Registry,
                                 project(query_fixture),
                                 _{id:Id,
                                   path:Path,
                                   generation:1,
                                   provenance:_{origin:test}},
                                 ok(File)).

activate_fixture(Registry, Language) :-
    fixture_path(Language, Path),
    fixture_symbol(Language, Symbol),
    ts_grammar_register(Registry,
                        Language,
                        _{identity:query_fixture(Language),
                          library:Path,
                          symbol:Symbol,
                          abi:unknown,
                          version:"fixture-v1",
                          provenance:_{origin:query_fixture}},
                        ok(_)),
    ts_grammar_activate(Registry, Language, ok(activated(_))).

register_pack(Registry, Language, Purpose, Source) :-
    project_query_pack_register(Registry,
                                Language,
                                Purpose,
                                Source,
                                _{version:"pack-v1",
                                  provenance:_{origin:test}},
                                ok(_)),
    project_query_pack_activate(Registry,
                                Language,
                                Purpose,
                                ok(activated(_))).

test(captures_are_grouped_and_provenance_complete, [nondet]) :-
    with_query_registry(captures_are_grouped_and_provenance_complete_).

captures_are_grouped_and_provenance_complete_(Registry, Root) :-
    register_project(Registry, Root),
    register_file(Registry, main, "src/main.c", File),
    activate_fixture(Registry, c),
    register_pack(Registry, c, definitions, "(function_definition) @definition"),
    project_query_extract(Registry,
                          File,
                          "int answer(void) { return 42; }",
                          [definitions],
                          [kb_root(Root)],
                          ok(Summary)),
    assertion(Summary.status == complete),
    assertion(Summary.match_count == 1),
    get_dict(extraction, Summary, Extraction),
    project_query_matches(Registry, Extraction, Match),
    Match.captures = [Capture],
    assertion(Capture.name == "definition"),
    assertion(Capture.ordinal == 0),
    Capture.node = syntax_node(SyntaxParse, Path),
    assertion(SyntaxParse = syntax_parse(File, _)),
    assertion(is_list(Path)),
    get_dict(node, Capture, CaptureNode),
    project_query_node_provenance(Registry, CaptureNode, Provenance),
    SyntaxParse = syntax_parse(File, ParseGeneration),
    assertion(Provenance.file == File),
    assertion(Provenance.language == c),
    assertion(Provenance.grammar_ref = grammar_ref(c, _)),
    assertion(Provenance.parse_generation == ParseGeneration),
    assertion(Provenance.start_byte < Provenance.end_byte),
    assertion(\+ sub_term('$BLOB'(_), Capture)).

test(python_and_javascript_use_the_same_generic_query_api, [nondet]) :-
    with_query_registry(python_and_javascript_use_the_same_generic_query_).

python_and_javascript_use_the_same_generic_query_(Registry, Root) :-
    register_project(Registry, Root),
    register_file(Registry, python_file, "src/example.py", PythonFile),
    register_file(Registry, javascript_file, "src/example.js", JavascriptFile),
    activate_fixture(Registry, python),
    activate_fixture(Registry, javascript),
    register_pack(Registry,
                  python,
                  definitions,
                  "(function_definition) @definition"),
    register_pack(Registry,
                  javascript,
                  definitions,
                  "(function_declaration) @definition"),
    register_pack(Registry,
                  javascript,
                  calls,
                  "(call_expression) @call"),
    project_query_extract(Registry,
                          PythonFile,
                          "def answer():\n    return 42\n",
                          [definitions],
                          [kb_root(Root)],
                          ok(PythonSummary)),
    assertion(PythonSummary.match_count == 1),
    project_query_extract(Registry,
                          JavascriptFile,
                          "function answer() { return call(); }\n",
                          [definitions, calls],
                          [kb_root(Root)],
                          ok(JavascriptSummary)),
    assertion(JavascriptSummary.match_count == 2),
    get_dict(extraction, JavascriptSummary, JavascriptExtraction),
    findall(Name,
            ( project_query_captures(Registry,
                                     JavascriptExtraction,
                                     Capture),
              Name = Capture.name
            ),
            Names),
    assertion(Names == ["definition", "call"]).

test(replacing_a_pack_stales_old_extraction_and_changes_hash, [nondet]) :-
    with_query_registry(replacing_a_pack_stales_old_extraction_and_changes_hash_).

replacing_a_pack_stales_old_extraction_and_changes_hash_(Registry, Root) :-
    register_project(Registry, Root),
    register_file(Registry, reload, "src/reload.c", File),
    activate_fixture(Registry, c),
    register_pack(Registry, c, definitions, "(function_definition) @definition"),
    project_query_extract(Registry,
                          File,
                          "int old(void) { return 1; }",
                          [definitions],
                          [kb_root(Root)],
                          ok(First)),
    project_query_pack_register(Registry,
                                c,
                                definitions,
                                "(function_definition) @definition_new",
                                _{version:"pack-v2",
                                  provenance:_{origin:test}},
                                ok(replaced(_))),
    project_query_pack_activate(Registry,
                                c,
                                definitions,
                                ok(activated(_))),
    project_query_extract(Registry,
                          File,
                          "int old(void) { return 1; };",
                          [definitions],
                          [kb_root(Root)],
                          ok(Second)),
    get_dict(extraction, First, FirstExtraction),
    get_dict(extraction, Second, SecondExtraction),
    assertion(FirstExtraction \== SecondExtraction),
    project_query_matches(Registry, FirstExtraction, _),
    project_query_current_extraction(Registry, File, SecondExtraction),
    findall(Provenance,
            project_query_node_provenance(Registry, _, Provenance),
            Provenances),
    member(Provenance, Provenances),
    get_dict(extraction, Provenance, SecondExtraction).

test(wrong_grammar_and_callable_source_fail_closed, [nondet]) :-
    with_query_registry(wrong_grammar_and_callable_source_fail_closed_).

wrong_grammar_and_callable_source_fail_closed_(Registry, Root) :-
    register_project(Registry, Root),
    register_file(Registry, main, "src/main.c", File),
    activate_fixture(Registry, c),
    register_pack(Registry, javascript, definitions, "(function_declaration) @definition"),
    project_query_extract(Registry,
                          File,
                          "int answer;",
                          [definitions],
                          [kb_root(Root)],
                          error(WrongGrammar)),
    assertion(WrongGrammar.kind == query_language_mismatch),
    project_query_pack_register(Registry,
                                c,
                                unsafe,
                                call(consult, secret),
                                _{},
                                error(CallableError)),
    assertion(CallableError.kind == type_error).

test(subtree_and_byte_range_execution_are_bounded, [nondet]) :-
    with_query_registry(subtree_and_byte_range_execution_are_bounded_).

subtree_and_byte_range_execution_are_bounded_(Registry, Root) :-
    register_project(Registry, Root),
    register_file(Registry, main, "src/main.c", File),
    activate_fixture(Registry, c),
    register_pack(Registry, c, definitions, "(function_definition) @definition"),
    Source = "int answer(void) { return 42; }",
    project_query_extract(Registry,
                          File,
                          Source,
                          [definitions],
                          [kb_root(Root), byte_range(0, 100)],
                          ok(First)),
    get_dict(extraction, First, FirstExtraction),
    project_query_captures(Registry, FirstExtraction, Capture),
    get_dict(node, Capture, CaptureNode),
    project_query_extract(Registry,
                          File,
                          Source,
                          [definitions],
                          [kb_root(Root), subtree(CaptureNode)],
                          ok(Second)),
    assertion(Second.match_count == 1),
    project_query_extract(Registry,
                          File,
                          Source,
                          [definitions],
                          [kb_root(Root), max_matches(1)],
                          partial(Partial)),
    assertion(Partial.reason == limit(max_matches, 1)).

test(zero_and_multiple_matches_remain_structured, [nondet]) :-
    with_query_registry(zero_and_multiple_matches_remain_structured_).

zero_and_multiple_matches_remain_structured_(Registry, Root) :-
    register_project(Registry, Root),
    register_file(Registry, functions, "src/functions.c", File),
    activate_fixture(Registry, c),
    register_pack(Registry, c, definitions, "(function_definition) @definition"),
    register_pack(Registry, c, calls, "(call_expression) @call"),
    project_query_extract(Registry,
                          File,
                          "int one(void) { return 1; }\nint two(void) { return 2; }",
                          [definitions],
                          [kb_root(Root)],
                          ok(Multiple)),
    assertion(Multiple.match_count == 2),
    project_query_extract(Registry,
                          File,
                          "int one(void) { return 1; }",
                          [calls],
                          [kb_root(Root)],
                          ok(Zero)),
    assertion(Zero.match_count == 0),
    assertion(Zero.capture_count == 0).

test(predicate_bearing_packs_are_rejected_without_evaluation, [nondet]) :-
    with_query_registry(predicate_bearing_packs_are_rejected_without_evaluation_).

predicate_bearing_packs_are_rejected_without_evaluation_(Registry, Root) :-
    register_project(Registry, Root),
    register_file(Registry, predicate, "src/predicate.c", File),
    activate_fixture(Registry, c),
    register_pack(Registry,
                  c,
                  predicates,
                  "((identifier) @name (#eq? @name \"answer\"))"),
    project_query_extract(Registry,
                          File,
                          "int answer;",
                          [predicates],
                          [kb_root(Root)],
                          error(Error)),
    assertion(Error.kind == unsupported_predicate).

test(malformed_pack_query_has_structured_location, [nondet]) :-
    with_query_registry(malformed_pack_query_has_structured_location_).

malformed_pack_query_has_structured_location_(Registry, Root) :-
    register_project(Registry, Root),
    register_file(Registry, malformed, "src/malformed.c", File),
    activate_fixture(Registry, c),
    register_pack(Registry, c, malformed, "(function_definition"),
    project_query_extract(Registry,
                          File,
                          "int answer(void) { return 42; }",
                          [malformed],
                          [kb_root(Root)],
                          error(Error)),
    assertion(Error.kind == query_compile),
    assertion(integer(Error.byte_offset)),
    assertion(Error.point = point(_, _)).

test(unicode_points_use_tree_sitter_byte_columns, [nondet]) :-
    with_query_registry(unicode_points_use_tree_sitter_byte_columns_).

unicode_points_use_tree_sitter_byte_columns_(Registry, Root) :-
    register_project(Registry, Root),
    register_file(Registry, unicode, "src/unicode.c", File),
    activate_fixture(Registry, c),
    register_pack(Registry, c, identifiers, "(identifier) @name"),
    project_query_extract(Registry,
                          File,
                          "int πvalue;",
                          [identifiers],
                          [kb_root(Root),
                           point_range(point(0, 4), point(0, 20))],
                          ok(Summary)),
    get_dict(extraction, Summary, Extraction),
    project_query_captures(Registry, Extraction, Capture),
    assertion(Capture.start_byte == 4),
    assertion(Capture.start_point == point(0, 4)).

test(read_only_project_root_is_a_structured_failure) :-
    tmp_file(project_query_read_only, Root),
    make_directory_path(Root),
    setup_call_cleanup(
        true,
        (   project_source_registry_create(Registry),
            project_source_project_register(Registry,
                                            project(read_only_fixture),
                                            _{origin:test, project_root:Root},
                                            ok(_)),
            project_source_file_register(Registry,
                                         project(read_only_fixture),
                                         _{id:main,
                                           path:"src/main.c",
                                           generation:1,
                                           provenance:_{origin:test}},
                                         ok(File)),
            activate_fixture(Registry, c),
            project_query_pack_register(Registry,
                                        c,
                                        definitions,
                                        "(function_definition) @definition",
                                        _{version:"pack-v1",
                                          provenance:_{origin:test}},
                                        ok(_)),
            project_query_pack_activate(Registry, c, definitions, ok(_)),
            atom_concat(Root, '.kb-root-blocked-by-regular-file', KBRoot),
            open(KBRoot, write, KBBlocker, [type(binary)]),
            close(KBBlocker),
            project_query_extract(Registry,
                                  File,
                                  "int answer(void) { return 42; }",
                                  [definitions],
                                  [kb_root(KBRoot)],
                                  error(Error)),
            assertion(Error.kind == kb_unwritable),
            project_source_registry_destroy(Registry)
        ),
        catch(delete_directory_and_contents(Root), _, true)
    ).

large_query_source(Source) :-
    length(Statements, 20000),
    maplist(=("int value;\n"), Statements),
    atomics_to_string(Statements, Source).

test(deadline_failure_does_not_publish_a_current_extraction, [nondet]) :-
    with_query_registry(deadline_failure_does_not_publish_a_current_extraction_).

deadline_failure_does_not_publish_a_current_extraction_(Registry, Root) :-
    register_project(Registry, Root),
    register_file(Registry, deadline, "src/deadline.c", File),
    activate_fixture(Registry, c),
    register_pack(Registry, c, definitions, "(function_definition) @definition"),
    large_query_source(Source),
    project_query_extract(Registry,
                          File,
                          Source,
                          [definitions],
                          [kb_root(Root), timeout_seconds(0.000001)],
                          error(Error)),
    assertion(Error.kind == timeout),
    assertion(\+ project_query_current_extraction(Registry, File, _)).

test(new_parse_publication_fences_prior_records_stale, [nondet]) :-
    with_query_registry(new_parse_publication_fences_prior_records_stale_).

new_parse_publication_fences_prior_records_stale_(Registry, Root) :-
    register_project(Registry, Root),
    register_file(Registry, fence, "src/fence.c", File),
    activate_fixture(Registry, c),
    register_pack(Registry, c, definitions, "(function_definition) @definition"),
    project_query_extract(Registry,
                          File,
                          "int first(void) { return 1; }",
                          [definitions],
                          [kb_root(Root)],
                          ok(First)),
    project_query_extract(Registry,
                          File,
                          "int second(void) { return 2; }",
                          [definitions],
                          [kb_root(Root)],
                          ok(Second)),
    get_dict(extraction, First, FirstExtraction),
    get_dict(extraction, Second, SecondExtraction),
    assertion(FirstExtraction \== SecondExtraction),
    findall(Parse-C,
            ( rlm_project_query:query_parse_fact(_, Parse, Record),
              Parse = syntax_parse(File, _),
              get_dict(currentness, Record, C)
            ),
            ParseRows),
    assertion(memberchk(syntax_parse(File, 1)-stale, ParseRows)),
    assertion(memberchk(syntax_parse(File, 2)-current, ParseRows)),
    assertion(\+ member(_-indeterminate(pending(_)), ParseRows)),
    findall(Extraction-C,
            ( rlm_project_query:query_extraction_fact(_, File, Extraction, Record),
              get_dict(currentness, Record, C)
            ),
            ExtractionRows),
    assertion(memberchk(FirstExtraction-stale, ExtractionRows)),
    assertion(memberchk(SecondExtraction-current, ExtractionRows)),
    assertion(\+ member(_-indeterminate(pending(_)), ExtractionRows)),
    project_query_current_extraction(Registry, File, SecondExtraction),
    rlm_project_query_persist:project_query_persist_snapshot(project(query_fixture),
                                                             Records,
                                                             _),
    assertion(( memberchk(FirstExtraction-FirstRow, Records),
                get_dict(currentness, FirstRow, stale) )),
    assertion(( memberchk(SecondExtraction-SecondRow, Records),
                get_dict(currentness, SecondRow, current) )).

test(reused_parse_publication_fences_prior_extraction_stale, [nondet]) :-
    with_query_registry(reused_parse_publication_fences_prior_extraction_stale_).

reused_parse_publication_fences_prior_extraction_stale_(Registry, Root) :-
    register_project(Registry, Root),
    register_file(Registry, reuse_fence, "src/reuse_fence.c", File),
    activate_fixture(Registry, c),
    register_pack(Registry, c, definitions, "(function_definition) @definition"),
    Source = "int answer(void) { return 42; }",
    project_query_extract(Registry,
                          File,
                          Source,
                          [definitions],
                          [kb_root(Root)],
                          ok(First)),
    project_query_extract(Registry,
                          File,
                          Source,
                          [definitions],
                          [kb_root(Root)],
                          ok(Second)),
    get_dict(extraction, First, FirstExtraction),
    get_dict(extraction, Second, SecondExtraction),
    assertion(FirstExtraction \== SecondExtraction),
    findall(Generation-C,
            ( rlm_project_query:query_parse_fact(_, syntax_parse(File, Generation), Record),
              get_dict(currentness, Record, C)
            ),
            ParseRows),
    assertion(ParseRows == [1-current]),
    findall(Extraction-C,
            ( rlm_project_query:query_extraction_fact(_, File, Extraction, Record),
              get_dict(currentness, Record, C)
            ),
            ExtractionRows),
    assertion(memberchk(FirstExtraction-stale, ExtractionRows)),
    assertion(memberchk(SecondExtraction-current, ExtractionRows)),
    assertion(\+ member(_-indeterminate(pending(_)), ExtractionRows)),
    project_query_current_extraction(Registry, File, SecondExtraction),
    rlm_project_query_persist:project_query_persist_snapshot(project(query_fixture),
                                                             Records,
                                                             _),
    assertion(( memberchk(FirstExtraction-FirstRow, Records),
                get_dict(currentness, FirstRow, stale) )),
    assertion(( memberchk(SecondExtraction-SecondRow, Records),
                get_dict(currentness, SecondRow, current) )).

:- end_tests(rlm_project_query).
