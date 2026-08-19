:- begin_tests(rlm_tree_sitter).

:- use_module('../prolog/rlm_tree_sitter').

:- dynamic tree_sitter_test_directory/1.
:- prolog_load_context(directory, TestDirectory),
   assertz(tree_sitter_test_directory(TestDirectory)).

fixture_path(Language, Path) :-
    tree_sitter_test_directory(TestDirectory),
    current_prolog_flag(shared_object_extension, Extension),
    atomic_list_concat([Language, Extension], '.', FileName),
    directory_file_path(TestDirectory, 'fixtures/tree-sitter', FixtureDirectory),
    directory_file_path(FixtureDirectory, FileName, Path).

fixture_language(c, tree_sitter_c).
fixture_language(lua, tree_sitter_lua).
fixture_language(query, tree_sitter_query).

load_fixture(Language, Handle) :-
    fixture_language(Language, Symbol),
    fixture_path(Language, Path),
    ts_language_load(Path, Symbol, Handle).

with_parser(Language, Goal) :-
    setup_call_cleanup(
        ( load_fixture(Language, LanguageHandle),
          ts_parser_create(Parser),
          ts_parser_set_language(Parser, LanguageHandle, ok(configured))
        ),
        call(Goal, Parser, LanguageHandle),
        ( ts_parser_close(Parser, _),
          ts_language_close(LanguageHandle, _)
        )
    ).

parse_source(Parser, Source, Tree, Root) :-
    ts_parse_string(Parser, Source, Tree),
    ts_tree_root(Tree, Root).

test(runtime_abi_is_ordered) :-
    ts_runtime_abi(Minimum, Maximum),
    assertion(integer(Minimum)),
    assertion(integer(Maximum)),
    assertion(Minimum =< Maximum).

test(loads_three_grammars_through_one_generic_api) :-
    forall(member(Language, [c,lua,query]),
           setup_call_cleanup(
               load_fixture(Language, Handle),
               ( ts_language_abi(Handle, Abi),
                 ts_language_compatible(Handle,
                                        ok(compatible(Abi, Minimum, Maximum))),
                 assertion(Abi >= Minimum),
                 assertion(Abi =< Maximum)
               ),
               ts_language_close(Handle, _)
           )).

test(missing_library_is_structured,
     [throws(error(tree_sitter_error(load_library, _), rlm_tree_sitter))]) :-
    ts_language_load('/definitely/not/a/tree-sitter-grammar.so',
                     tree_sitter_missing,
                     _).

test(missing_symbol_is_structured,
     [throws(error(tree_sitter_error(load_symbol, _), rlm_tree_sitter))]) :-
    fixture_path(c, Path),
    ts_language_load(Path, tree_sitter_definitely_missing, _).

test(incompatible_grammar_abi_is_rejected_before_parse,
     [throws(error(tree_sitter_error(incompatible_language_abi, _),
                   rlm_tree_sitter))]) :-
    fixture_path('c-incompatible', Path),
    ts_language_load(Path, tree_sitter_c, _).

test(parser_without_language_is_structured,
     [throws(error(tree_sitter_error(parser_without_language, _),
                   rlm_tree_sitter))]) :-
    setup_call_cleanup(ts_parser_create(Parser),
                       ts_parse_string(Parser, "int x;", _),
                       ts_parser_close(Parser, _)).

test(c_parse_traverse_fields_and_ranges) :-
    with_parser(c, c_parse_traverse_fields_and_ranges_).

c_parse_traverse_fields_and_ranges_(Parser, _) :-
    Source = "int add(int a, int b) { return a + b; }",
    setup_call_cleanup(
        parse_source(Parser, Source, Tree, Root),
        ( ts_node_type(Root, translation_unit),
          ts_node_named(Root),
          \+ ts_node_has_error(Root),
          ts_node_start_byte(Root, 0),
          ts_node_end_byte(Root, EndByte),
          assertion(EndByte > 0),
          ts_node_start_point(Root, point(0, 0)),
          ts_node_named_child(Root, 0, Function),
          ts_node_type(Function, function_definition),
          ts_node_field(Function, declarator, Declarator),
          ts_node_type(Declarator, function_declarator),
          ts_node_child_count(Function, ChildCount),
          assertion(ChildCount > 0)
        ),
        ts_tree_close(Tree, _)
    ).

test(lua_parse_via_same_api) :-
    with_parser(lua, lua_parse_via_same_api_).

lua_parse_via_same_api_(Parser, _) :-
    setup_call_cleanup(
        parse_source(Parser, "local answer = 42", Tree, Root),
        ( ts_node_type(Root, Type),
          assertion(atom(Type)),
          \+ ts_node_has_error(Root),
          ts_node_child_count(Root, Count),
          assertion(Count > 0)
        ),
        ts_tree_close(Tree, _)
    ).

test(query_parse_via_same_api) :-
    with_parser(query, query_parse_via_same_api_).

query_parse_via_same_api_(Parser, _) :-
    setup_call_cleanup(
        parse_source(Parser, "(identifier) @name", Tree, Root),
        ( ts_node_type(Root, Type),
          assertion(atom(Type)),
          \+ ts_node_has_error(Root),
          ts_node_child_count(Root, Count),
          assertion(Count > 0)
        ),
        ts_tree_close(Tree, _)
    ).

test(malformed_source_returns_error_bearing_tree) :-
    with_parser(c, malformed_source_returns_error_bearing_tree_).

malformed_source_returns_error_bearing_tree_(Parser, _) :-
    setup_call_cleanup(
        parse_source(Parser, "int main(", Tree, Root),
        ts_node_has_error(Root),
        ts_tree_close(Tree, _)
    ).

test(utf8_ranges_are_byte_offsets) :-
    with_parser(c, utf8_ranges_are_byte_offsets_).

utf8_ranges_are_byte_offsets_(Parser, _) :-
    setup_call_cleanup(
        parse_source(Parser, "/* π */ int x;", Tree, Root),
        ts_node_end_byte(Root, 15),
        ts_tree_close(Tree, _)
    ).

test(child_index_is_validated,
     [throws(error(domain_error(tree_sitter_child_index, 999999), _))]) :-
    with_parser(c, child_index_is_validated_).

child_index_is_validated_(Parser, _) :-
    setup_call_cleanup(
        parse_source(Parser, "int x;", Tree, Root),
        ts_node_child(Root, 999999, _),
        ts_tree_close(Tree, _)
    ).

test(tree_close_invalidates_retained_nodes) :-
    with_parser(c, tree_close_invalidates_retained_nodes_).

tree_close_invalidates_retained_nodes_(Parser, _) :-
    ts_parse_string(Parser, "int x;", Tree),
    ts_tree_root(Tree, Root),
    ts_tree_close(Tree, ok(closed)),
    ts_tree_close(Tree, ok(already_closed)),
    catch(ts_node_type(Root, _), Error, true),
    assertion(Error = error(tree_sitter_error(closed_tree, _), rlm_tree_sitter)).

test(language_may_close_after_parser_retains_it) :-
    load_fixture(c, Language),
    setup_call_cleanup(
        ( ts_parser_create(Parser),
          ts_parser_set_language(Parser, Language, ok(configured)),
          ts_language_close(Language, ok(closed))
        ),
        setup_call_cleanup(
            parse_source(Parser, "int retained = 1;", Tree, Root),
            ts_node_type(Root, translation_unit),
            ts_tree_close(Tree, _)
        ),
        ts_parser_close(Parser, _)
    ).

test(node_keeps_unreferenced_tree_alive) :-
    with_parser(c, node_keeps_unreferenced_tree_alive_).

node_keeps_unreferenced_tree_alive_(Parser, _) :-
    root_without_tree_handle(Parser, Root),
    garbage_collect,
    garbage_collect_atoms,
    ts_node_type(Root, translation_unit).

root_without_tree_handle(Parser, Root) :-
    ts_parse_string(Parser, "int kept = 1;", Tree),
    ts_tree_root(Tree, Root).

test(tree_is_thread_affine) :-
    with_parser(c, tree_is_thread_affine_).

tree_is_thread_affine_(Parser, _) :-
    setup_call_cleanup(
        ( ts_parse_string(Parser, "int x;", Tree),
          message_queue_create(Queue)
        ),
        ( thread_create(thread_tree_result(Tree, Queue), Thread, []),
          thread_get_message(Queue, Result),
          thread_join(Thread, true),
          assertion(Result = error(tree_sitter_error(wrong_thread, _),
                                   rlm_tree_sitter))
        ),
        ( message_queue_destroy(Queue),
          ts_tree_close(Tree, _)
        )
    ).

thread_tree_result(Tree, Queue) :-
    catch(( ts_tree_root(Tree, _),
            Result = unexpected_success
          ),
          Error,
          Result = Error),
    thread_send_message(Queue, Result).

test(parser_and_language_close_are_idempotent) :-
    load_fixture(c, Language),
    ts_parser_create(Parser),
    ts_parser_set_language(Parser, Language, ok(configured)),
    ts_parser_close(Parser, ok(closed)),
    ts_parser_close(Parser, ok(already_closed)),
    ts_language_close(Language, ok(closed)),
    ts_language_close(Language, ok(already_closed)).

test(parser_is_thread_affine) :-
    setup_call_cleanup(
        ( load_fixture(c, Language),
          ts_parser_create(Parser),
          ts_parser_set_language(Parser, Language, ok(configured)),
          message_queue_create(Queue)
        ),
        ( thread_create(thread_parse_result(Parser, Queue), Thread, []),
          thread_get_message(Queue, Result),
          thread_join(Thread, true),
          assertion(Result = error(tree_sitter_error(wrong_thread, _),
                                   rlm_tree_sitter))
        ),
        ( message_queue_destroy(Queue),
          ts_parser_close(Parser, _),
          ts_language_close(Language, _)
        )
    ).

thread_parse_result(Parser, Queue) :-
    catch(( ts_parse_string(Parser, "int x;", Tree),
            ts_tree_close(Tree, _),
            Result = unexpected_success
          ),
          Error,
          Result = Error),
    thread_send_message(Queue, Result).

:- end_tests(rlm_tree_sitter).
