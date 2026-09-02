:- initialization(main, main).

:- use_module('../prolog/rlm_tree_sitter').
:- use_module('../prolog/rlm_project_source').
:- use_module('../prolog/rlm_project_query').

main([Root]) :-
    catch(reload_query_observation(Root),
          Error,
          ( print_message(error, Error),
            halt(1)
          )),
    writeln(query_kb_phase_complete).

reload_query_observation(Root) :-
    project_source_registry_create(Registry),
    project_source_project_register(Registry,
                                    project(restart_fixture),
                                    _{origin:test, project_root:Root},
                                    ok(_)),
    project_source_file_register(Registry,
                                 project(restart_fixture),
                                 _{id:main,
                                   path:"src/main.c",
                                   generation:1,
                                   provenance:_{origin:test}},
                                 ok(File)),
    project_query_current_extraction(Registry, File, Extraction),
    project_query_matches(Registry, Extraction, Match),
    Match.captures = [Capture],
    Capture.name == "definition",
    project_query_node_provenance(Registry, Capture.node, Provenance),
    Provenance.extraction == Extraction,
    Provenance.parse_generation == 1,
    absolute_file_name('test/fixtures/tree-sitter/c.so', GrammarPath,
                       [access(read)]),
    ts_grammar_register(Registry,
                        c,
                        _{identity:restart_fixture,
                          library:GrammarPath,
                          symbol:tree_sitter_c,
                          abi:unknown,
                          version:"fixture-v1",
                          provenance:_{origin:test}},
                        ok(_)),
    ts_grammar_activate(Registry, c, ok(activated(_))),
    project_query_pack_register(Registry,
                                c,
                                definitions,
                                "(function_definition) @definition",
                                _{version:"pack-v1",
                                  provenance:_{origin:test}},
                                ok(_)),
    project_query_pack_activate(Registry, c, definitions, ok(_)),
    project_query_extract(Registry,
                          File,
                          "int restart(void) { return 1; }",
                          [definitions],
                          [kb_root(Root)],
                          ok(NextSummary)),
    NextSummary.extraction == query_extraction(File, 2),
    project_source_registry_destroy(Registry).
