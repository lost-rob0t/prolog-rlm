/* Fresh-process phase 1: register, extract, normalize, print a marker, and
   either die uncleanly (killed by the runner) or exit after journaling.
   The semantic journal must already be durable when the process dies. */
:- use_module('../prolog/rlm_tree_sitter').
:- use_module('../prolog/rlm_project_source').
:- use_module('../prolog/rlm_project_query').
:- use_module('../prolog/rlm_project_semantic_pack').
:- use_module('../prolog/rlm_project_semantic').
:- use_module(library(filesex)).

:- initialization(main, main).

:- dynamic fixture_dir/1.
:- prolog_load_context(directory, TD), assertz(fixture_dir(TD)).

main([Root, Mode]) :-
    catch(( setup_call_cleanup(
                project_source_registry_create(Registry),
                run(Registry, Root, Mode),
                project_source_registry_destroy(Registry) ),
            flush_output,
            read_line_to_string(user_input, _) ),
          Error,
          ( print_message(error, Error),
            halt(1)
          )),
    read_line_to_string(user_input, _).

run(Registry, Root, Mode) :-
    fixture_dir(D),
    current_prolog_flag(shared_object_extension, Extension),
    atomic_list_concat([D, '/fixtures/tree-sitter/python.', Extension], G),
    project_source_project_register(Registry,
                                    project(semantic_fixture),
                                    _{origin:fixture, project_root:Root},
                                    ok(project(_Project))),
    project_source_file_register(Registry,
                                 project(semantic_fixture),
                                 _{id:main,
                                   path:"src/example.py",
                                   generation:1,
                                   provenance:_{origin:fixture}},
                                 ok(File)),
    ts_grammar_register(Registry,
                        python,
                        _{identity:semantic_fixture(python),
                          library:G,
                          symbol:tree_sitter_python,
                          abi:unknown,
                          version:"fixture-v1",
                          provenance:_{origin:semantic_fixture}},
                        ok(_)),
    ts_grammar_activate(Registry, python, ok(_)),
    project_semantic_pack_register(Registry, python, ok(_)),
    project_semantic_pack_activate(Registry, python, ok(_)),
    Source = "def answer():\n    return helper(1)\n\ndef helper(n):\n    return n\n",
    project_query_extract(Registry,
                          File,
                          Source,
                          [definitions],
                          [kb_root(Root)],
                          ok(_)),
    project_semantic_normalize(Registry,
                               File,
                               Source,
                               [kb_root(Root)],
                               ok(Summary)),
    (   Summary.definitions == 2
    ->  true
    ;   throw(error(semantic_fixture_mismatch(Summary.definitions), _))
    ),
    (   Mode == stale
    ->  project_query_pack_register(Registry,
                                    python,
                                    definitions,
                                    "(function_definition name: (identifier) @definition.name) @definition.function",
                                    _{version:"pack-v2", provenance:_{origin:fixture}},
                                    ok(_)),
        project_semantic_knowledge_state(Registry, File, State),
        (   State = stale(query_extraction(File, _))
        ->  true
        ;   throw(error(semantic_fixture_state(State), _))
        )
    ;   Mode == current
    ->  project_semantic_knowledge_state(Registry, File, current)
    ),
    format("semantic_kb_phase_complete~n"),
    flush_output.