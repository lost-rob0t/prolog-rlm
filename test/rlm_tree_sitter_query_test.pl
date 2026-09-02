:- begin_tests(rlm_tree_sitter_query).

:- use_module('../prolog/rlm_tree_sitter').

:- dynamic query_test_directory/1.
:- prolog_load_context(directory, TestDirectory),
   assertz(query_test_directory(TestDirectory)).

fixture_path(Language, Path) :-
    query_test_directory(TestDirectory),
    current_prolog_flag(shared_object_extension, Extension),
    atomic_list_concat([Language, Extension], '.', FileName),
    directory_file_path(TestDirectory, 'fixtures/tree-sitter', FixtureDirectory),
    directory_file_path(FixtureDirectory, FileName, Path).

with_parser(Goal) :-
    fixture_path(c, Path),
    setup_call_cleanup(
        ( ts_language_load(Path, tree_sitter_c, Language),
          ts_parser_create(Parser),
          ts_parser_set_language(Parser, Language, ok(configured))
        ),
        call(Goal, Parser, Language),
        ( ts_parser_close(Parser, _),
          ts_language_close(Language, _)
        )
    ).

parse_root(Parser, Source, Tree, Root) :-
    ts_parse_string(Parser, Source, Tree),
    ts_tree_root(Tree, Root).

test(compile_metadata_and_match_grouping, [nondet]) :-
    with_parser(compile_metadata_and_match_grouping_).

compile_metadata_and_match_grouping_(Parser, Language) :-
    Source = "int answer(void) { return 42; }",
    QuerySource = "(function_definition) @definition",
    ts_query_compile(Language, QuerySource, Query),
    setup_call_cleanup(
        ts_query_cursor_create(Cursor),
        ( ts_query_pattern_count(Query, 1),
          ts_query_capture_count(Query, 1),
          ts_query_string_count(Query, 0),
          ts_query_capture_name(Query, 0, "definition"),
          ts_query_capture_quantifier(Query, 0, 0, one),
          ts_query_predicates(Query, 0, []),
          parse_root(Parser, Source, Tree, Root),
          setup_call_cleanup(
              true,
              ( ts_query_cursor_exec(Cursor, Query, Root),
                ts_query_next_match(Cursor,
                                    ts_match(MatchId,
                                             0,
                                             Captures)),
                assertion(integer(MatchId)),
                assertion(Captures = [ts_capture(_, _)]),
                \+ ts_query_next_match(Cursor, _)
              ),
              ts_tree_close(Tree, _)
          )
        ),
        ts_query_cursor_close(Cursor, _)
    ),
    ts_query_cursor_close(Cursor, ok(already_closed)),
    ts_query_close(Query, _).

test(compile_error_has_kind_and_byte_offset, [nondet]) :-
    with_parser(compile_error_has_kind_and_byte_offset_).

compile_error_has_kind_and_byte_offset_(_, Language) :-
    catch(ts_query_compile(Language, "(function_definition", _),
          Error,
          true),
    Error = error(tree_sitter_error(query_compile(_, Offset),
                                    point(Row, Column)),
                  rlm_tree_sitter),
    assertion(integer(Offset)),
    assertion(integer(Row)),
    assertion(integer(Column)).

test(query_source_is_data_not_a_callable, [nondet]) :-
    with_parser(query_source_is_data_not_a_callable_).

query_source_is_data_not_a_callable_(_, Language) :-
    catch(ts_query_compile(Language, call(consult, secret), _),
          Error,
          true),
    assertion(Error = error(type_error(query_source, call(consult, secret)), _)).

test(cursor_ranges_and_close_are_structured, [nondet]) :-
    with_parser(cursor_ranges_and_close_are_structured_).

cursor_ranges_and_close_are_structured_(Parser, Language) :-
    ts_query_compile(Language, "(identifier) @name", Query),
    setup_call_cleanup(
        ( ts_query_cursor_create(Cursor),
          parse_root(Parser, "int answer;", Tree, Root)
        ),
        setup_call_cleanup(
            true,
            ( ts_query_cursor_set_byte_range(Cursor, 4, 10),
              ts_query_cursor_set_point_range(Cursor,
                                              point(0, 4),
                                              point(0, 10)),
              ts_query_cursor_set_match_limit(Cursor, 8),
              ts_query_cursor_exec(Cursor, Query, Root),
              \+ ts_query_did_exceed_match_limit(Cursor)
            ),
            ts_tree_close(Tree, _)
        ),
        ts_query_cursor_close(Cursor, _)
    ),
    ts_query_close(Query, _).

test(next_capture_preserves_match_group, [nondet]) :-
    with_parser(next_capture_preserves_match_group_).

next_capture_preserves_match_group_(Parser, Language) :-
    ts_query_compile(Language, "(identifier) @name", Query),
    setup_call_cleanup(
        ts_query_cursor_create(Cursor),
        ( parse_root(Parser, "int answer;", Tree, Root),
          setup_call_cleanup(
              true,
              ( ts_query_cursor_exec(Cursor, Query, Root),
                ts_query_next_capture(Cursor,
                                      ts_match(_, 0, [ts_capture(0, _)]),
                                      0)
              ),
              ts_tree_close(Tree, _)
          )
        ),
        ts_query_cursor_close(Cursor, _)
    ),
    ts_query_close(Query, _).

test(query_retains_language_after_public_language_close, [nondet]) :-
    fixture_path(c, Path),
    ts_language_load(Path, tree_sitter_c, Language),
    ts_query_compile(Language, "(identifier) @name", Query),
    ts_language_close(Language, ok(closed)),
    ts_query_capture_count(Query, 1),
    ts_query_close(Query, ok(closed)),
    ts_query_close(Query, ok(already_closed)).

:- end_tests(rlm_tree_sitter_query).
