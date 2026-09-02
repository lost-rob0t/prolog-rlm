:- module(rlm_project_query_persist,
          [ project_query_persist_open/2,
            project_query_persist_close/0,
            project_query_persist_append/4,
            project_query_persist_replace/3,
            project_query_persist_snapshot/3
          ]).

/** <module> Project-query observation persistence

This is a project-knowledge persistence adapter, not an artifact, graph,
effect, or generic fact store.  Native query handles never enter the journal;
only closed extraction and match observations are persisted.  SWI-Prolog
10.0.2 exposes `sync(close)` rather than the newer `sync(always)` spelling;
closing the journal after every write is the strongest supported process-crash
boundary.
*/

:- use_module(library(persistency)).

:- persistent
       extraction_record(project:any,
                         extraction:any,
                         record:any),
       match_record(project:any,
                    extraction:any,
                    sequence:integer,
                    match:any).

project_query_persist_open(File0, Outcome) :-
    catch(( normalize_path(File0, File),
            with_mutex(rlm_project_query_persist,
                       project_query_persist_open_locked(File)),
            Result = ok(File)
          ),
          Exception,
          Result = error(project_query_persist_error{
                             kind:attach_failed,
                             file:File0,
                             exception:Exception
                         })),
    Outcome = Result.

project_query_persist_open_locked(File) :-
    (   db_attached(Current)
    ->  (   same_file_or_atom(Current, File)
        ->  true
        ;   db_detach,
            db_attach(File, [sync(close)])
        )
    ;   db_attach(File, [sync(close)])
    ).

project_query_persist_close :-
    with_mutex(rlm_project_query_persist,
               (   db_attached(_)
               ->  db_detach
               ;   true
               )).

project_query_persist_append(Project,
                             Extraction,
                             Record,
                             Matches) :-
    require_attached,
    ground(Project),
    ground(Extraction),
    ground(Record),
    ground(Matches),
    is_list(Matches),
    !,
    with_mutex(rlm_project_query_persist,
               ( assert_extraction_record(Project,
                                           Extraction,
                                           Record),
                 append_match_records(Project,
                                       Extraction,
                                       Matches,
                                       1)
               )).
project_query_persist_append(Project, Extraction, Record, Matches) :-
    ( ground(Project) -> ProjectState = ground ; ProjectState = nonground ),
    ( ground(Extraction) -> ExtractionState = ground ; ExtractionState = nonground ),
    ( ground(Record) -> RecordState = ground ; RecordState = nonground ),
    ( ground(Matches) -> MatchesState = ground ; MatchesState = nonground ),
    throw(error(instantiation_error,
                context(rlm_project_query_persist,
                        non_ground_observation(ProjectState,
                                               ExtractionState,
                                               RecordState,
                                               MatchesState)))).

project_query_persist_replace(Project, Extraction, Record) :-
    require_attached,
    ground(Project),
    ground(Extraction),
    ground(Record),
    !,
    with_mutex(rlm_project_query_persist,
               ( retractall_extraction_record(Project, Extraction, _),
                 assert_extraction_record(Project, Extraction, Record)
               )).
project_query_persist_replace(_, _, Record) :-
    throw(error(instantiation_error,
                context(rlm_project_query_persist,
                        non_ground_observation(Record)))).

append_match_records(_, _, [], _).
append_match_records(Project, Extraction, [Match|Matches], Sequence) :-
    assert_match_record(Project, Extraction, Sequence, Match),
    NextSequence is Sequence + 1,
    append_match_records(Project, Extraction, Matches, NextSequence).

project_query_persist_snapshot(Project, Records, Matches) :-
    require_attached,
    with_mutex(rlm_project_query_persist,
               ( findall(Extraction-Record,
                         extraction_record(Project, Extraction, Record),
                         RecordPairs),
                 findall(Extraction-Sequence-Match,
                         match_record(Project,
                                      Extraction,
                                      Sequence,
                                      Match),
                         MatchRows)
               )),
    keysort(RecordPairs, SortedRecords),
    keysort(MatchRows, SortedMatches),
    Records = SortedRecords,
    Matches = SortedMatches.

require_attached :-
    (   db_attached(_)
    ->  true
    ;   throw(error(existence_error(project_query_persistent_backend,
                                    attached),
                    context(rlm_project_query_persist,
                            'no project-query persistency file is attached')))
    ).

normalize_path(Value, Path) :-
    (   atom(Value)
    ->  Path = Value
    ;   string(Value)
    ->  atom_string(Path, Value)
    ;   throw(error(type_error(path, Value),
                    context(rlm_project_query_persist,
                            invalid_persistence_path)))
    ).

same_file_or_atom(A, B) :-
    A == B,
    !.
same_file_or_atom(A, B) :-
    catch(same_file(A, B), _, fail).
