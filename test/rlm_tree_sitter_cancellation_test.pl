:- begin_tests(rlm_tree_sitter_cancellation).

:- use_module('../prolog/rlm_tree_sitter').
:- use_module(library(time)).

:- dynamic cancellation_test_directory/1.
:- prolog_load_context(directory, TestDirectory),
   assertz(cancellation_test_directory(TestDirectory)).

c_fixture_path(Path) :-
    cancellation_test_directory(TestDirectory),
    current_prolog_flag(shared_object_extension, Extension),
    atomic_list_concat([c, Extension], '.', FileName),
    directory_file_path(TestDirectory, 'fixtures/tree-sitter', FixtureDirectory),
    directory_file_path(FixtureDirectory, FileName, Path).

with_c_parser(Goal) :-
    c_fixture_path(Path),
    setup_call_cleanup(
        ( ts_language_load(Path, tree_sitter_c, Language),
          ts_parser_create(Parser),
          ts_parser_set_language(Parser, Language, ok(configured))
        ),
        call(Goal, Parser),
        ( ts_parser_close(Parser, _),
          ts_language_close(Language, _)
        )
    ).

large_native_source(Source) :-
    length(Statements, 100000),
    maplist(=("int value;\n"), Statements),
    atomics_to_string(Statements, Source).

test(native_chunk_reader_observes_deadline) :-
    with_c_parser(native_chunk_reader_observes_deadline_).

native_chunk_reader_observes_deadline_(Parser) :-
    large_native_source(Source),
    catch(call_with_time_limit(0.000001,
                               ts_parse_string(Parser, Source, Tree)),
          time_limit_exceeded,
          TimedOut = true),
    (   var(Tree)
    ->  assertion(TimedOut == true)
    ;   ts_tree_close(Tree, _),
        assertion(fail)
    ).

:- end_tests(rlm_tree_sitter_cancellation).
