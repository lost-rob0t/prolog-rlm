:- module(rlm_project_semantic_persist,
          [ project_semantic_persist_open/2,
            project_semantic_persist_close/0,
            project_semantic_persist_append/4,
            project_semantic_persist_snapshot/2
          ]).

/** <module> Project-semantic observation persistence

Project-knowledge persistence adapter for #98 normalized direct semantic
observations.  It is a sibling of the #97 project-query journal, not an
artifact, graph, effect, or generic fact store.  Only closed observation
records enter the journal; derived relations are recomputed on demand and are
never persisted.  Currentness is not journaled: currentness authority stays
with the #97 extraction records, so a restart can never resurrect semantic
facts as current when the query layer no longer holds the extraction current.

SWI-Prolog 10.0.2 exposes `sync(close)` rather than the newer `sync(always)`
spelling; closing the journal after every write is the strongest supported
process-crash boundary, matching the #97 adapter.
*/

:- use_module(library(persistency)).

:- persistent
       semantic_record(project:any,
                       extraction:any,
                       sequence:integer,
                       record:any).

project_semantic_persist_open(File0, Outcome) :-
    catch(( normalize_path(File0, File),
            with_mutex(rlm_project_semantic_persist,
                       project_semantic_persist_open_locked(File)),
            Result = ok(File)
          ),
          Exception,
          Result = error(project_semantic_persist_error{
                             kind:attach_failed,
                             file:File0,
                             exception:Exception
                         })),
    Outcome = Result.

project_semantic_persist_open_locked(File) :-
    (   db_attached(Current)
    ->  (   same_file_or_atom(Current, File)
        ->  true
        ;   db_detach,
            db_attach(File, [sync(close)])
        )
    ;   db_attach(File, [sync(close)])
    ).

project_semantic_persist_close :-
    with_mutex(rlm_project_semantic_persist,
               (   db_attached(_)
               ->  db_detach
               ;   true
               )).

project_semantic_persist_append(Project, Extraction, Sequence, Record) :-
    require_attached,
    ground(Project),
    ground(Extraction),
    ground(Sequence),
    ground(Record),
    !,
    with_mutex(rlm_project_semantic_persist,
               assert_semantic_record(Project, Extraction, Sequence, Record)).
project_semantic_persist_append(Project, Extraction, Sequence, Record) :-
    throw(error(instantiation_error,
                context(rlm_project_semantic_persist,
                        non_ground_observation(Project,
                                               Extraction,
                                               Sequence,
                                               Record)))).

require_attached :-
    (   db_attached(_)
    ->  true
    ;   throw(error(existence_error(project_semantic_persistent_backend,
                                    attached),
                    context(rlm_project_semantic_persist,
                            'no project-semantic persistency file is attached')))
    ).

%% Ordered snapshot of one project's journaled semantic observations.
%% A re-normalized extraction writes identical rows again; sort/2 collapses
%% exact duplicates so replay is deterministic.
project_semantic_persist_snapshot(Project, Records) :-
    require_attached,
    findall(Extraction-Sequence-Record,
            semantic_record(Project, Extraction, Sequence, Record),
            Rows0),
    sort(Rows0, Records).

normalize_path(Value, Path) :-
    ( atom(Value) -> Path = Value ; string(Value) -> atom_string(Path, Value) ; fail ),
    !.
normalize_path(Value, _) :-
    throw(project_semantic_fault(invalid_path(Value))).

same_file_or_atom(A, B) :-
    A == B,
    !.
same_file_or_atom(A, B) :-
    catch(same_file(A, B), _, fail).
