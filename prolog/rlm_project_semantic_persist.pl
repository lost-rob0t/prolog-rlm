:- module(rlm_project_semantic_persist,
          [ project_semantic_persist_open/2,
            project_semantic_persist_close/0,
            project_semantic_persist_publish/4,
            project_semantic_persist_snapshot/3
          ]).

/** <module> Project-semantic observation persistence

Project-knowledge persistence adapter for #98 normalized direct semantic
observations.  It is a sibling of the #97 project-query journal, not an
artifact, graph, effect, or generic fact store.

One normalized publication for one extraction is journaled as a single
`semantic_publication/3` row: a crash can never leave a partially journaled
extraction behind that later hydrates as current knowledge, because the row
is one durable append closed by `sync(close)`.

The adapter keeps one attached journal file at a time.  Publication and
snapshot operations are self-sufficient: they ensure the journal of the
target project is the attached one before reading or writing, so several
projects (and several registries) can share one process without writing a
project's observations into another project's journal file.

Currentness is not journaled: currentness authority stays with the #97
extraction records, so a restart can never resurrect semantic facts as
current when the query layer no longer holds the extraction current.

SWI-Prolog 10.0.2 exposes `sync(close)` rather than the newer `sync(always)`
spelling; closing the journal after every write is the strongest supported
process-crash boundary, matching the #97 adapter.
*/

:- use_module(library(persistency)).

:- persistent
       semantic_publication(project:any,
                            extraction:any,
                            records:any).

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

%% Durably journal one complete semantic publication as a single atomic row.
%% The journal of File is attached first, so a multi-project process never
%% appends a project's observations into another project's journal.
project_semantic_persist_publish(File0, Project, Extraction, Records) :-
    (   ground(Project),
        ground(Extraction),
        ground(Records)
    ->  true
    ;   throw(error(instantiation_error,
                    context(rlm_project_semantic_persist,
                            non_ground_publication(Project,
                                                   Extraction,
                                                   Records))))
    ),
    normalize_path(File0, File),
    with_mutex(rlm_project_semantic_persist,
               ( project_semantic_persist_open_locked(File),
                 assert_semantic_publication(Project, Extraction, Records)
               )).

%% Ordered snapshot of one project's journaled publications.  A
%% re-normalized extraction writes an identical row again; sort/2 collapses
%% exact duplicates so replay is deterministic.
project_semantic_persist_snapshot(File0, Project, Publications) :-
    normalize_path(File0, File),
    with_mutex(rlm_project_semantic_persist,
               project_semantic_persist_open_locked(File)),
    findall(Extraction-Records,
            semantic_publication(Project, Extraction, Records),
            Rows0),
    sort(Rows0, Publications).

project_semantic_persist_close :-
    with_mutex(rlm_project_semantic_persist,
               (   db_attached(_)
               ->  db_detach
               ;   true
               )).

normalize_path(Value, Path) :-
    (   atom(Value) -> Path = Value
    ;   string(Value) -> atom_string(Path, Value)
    ),
    !.
normalize_path(Value, _) :-
    throw(project_semantic_fault(invalid_path(Value))).

same_file_or_atom(A, B) :-
    A == B,
    !.
same_file_or_atom(A, B) :-
    catch(same_file(A, B), _, fail).