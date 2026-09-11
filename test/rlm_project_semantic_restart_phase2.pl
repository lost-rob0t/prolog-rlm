/* Fresh-process phase 2: re-register the project/file, hydrate the semantic
   journal on first read, and answer semantic queries without any source or
   re-extraction. Stale mode additionally proves a restart cannot resurrect
   the observations of a superseded extraction as current. */
:- use_module('../prolog/rlm_project_source').
:- use_module('../prolog/rlm_project_query').
:- use_module('../prolog/rlm_project_semantic').
:- use_module(library(filesex)).

:- initialization(main, main).

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
    (   Mode == current
    ->  findall(Name,
                ( project_semantic_definitions(Registry, File, none, Definition),
                  Name = Definition.name
                ),
                Names),
        (   Names == [answer, helper]
        ->  true
        ;   throw(error(semantic_fixture_names(Names), _))
        ),
        findall(Kind,
                ( project_semantic_definitions(Registry, File, none, Definition),
                  Kind = Definition.kind
                ),
                Kinds),
        (   Kinds == [function, function]
        ->  true
        ;   throw(error(semantic_fixture_kinds(Kinds), _))
        ),
        project_semantic_knowledge_state(Registry, File, current)
    ;   Mode == stale
    ->  project_semantic_knowledge_state(Registry, File, none),
        findall(_, project_semantic_definitions(Registry, File, none, _), Rows),
        (   Rows == []
        ->  true
        ;   throw(error(semantic_fixture_resurrected(Rows), _))
        )
    ),
    format("semantic_kb_phase2_complete~n"),
    flush_output.