:- module(rlm_artifact_persist,
          [ artifact_persist_open/1,
            artifact_persist_close/0,
            artifact_persist_next_version/3,
            artifact_persist_put/4,
            artifact_persist_get/4,
            artifact_persist_latest/4,
            artifact_persist_list/2,
            artifact_persist_delete_namespace/1
          ]).

/** <module> SWI persistency backend for durable RLM artifacts */

:- use_module(library(persistency)).

:- persistent
       artifact_record(namespace:any,
                       key:atom,
                       version:integer,
                       artifact:any).

artifact_persist_open(File) :-
    with_mutex(rlm_artifact_persist,
               artifact_persist_open_locked(File)).

artifact_persist_open_locked(File) :-
    (   db_attached(Current)
    ->  (   same_file_or_atom(Current, File)
        ->  true
        ;   db_detach,
            db_attach(File, [sync(close)])
        )
    ;   db_attach(File, [sync(close)])
    ).

artifact_persist_close :-
    with_mutex(rlm_artifact_persist,
               (   db_attached(_)
               ->  db_detach
               ;   true
               )).

artifact_persist_next_version(Namespace, Key, Version) :-
    require_attached,
    with_mutex(rlm_artifact_persist,
               findall(V,
                       artifact_record(Namespace, Key, V, _),
                       Versions)),
    (   Versions == []
    ->  Version = 1
    ;   max_list(Versions, Latest),
        Version is Latest+1
    ).

artifact_persist_put(Namespace, Key, Version, Artifact) :-
    require_attached,
    ground(Artifact),
    integer(Version),
    Version > 0,
    !,
    with_mutex(rlm_artifact_persist,
               (   artifact_record(Namespace, Key, Version, Existing)
               ->  (   Existing == Artifact
                   ->  true
                   ;   throw(error(permission_error(overwrite,
                                                     artifact_version,
                                                     Namespace-Key-Version),
                                     context(rlm_artifact_persist,
                                             'artifact versions are immutable')))
                   )
               ;   assert_artifact_record(Namespace,
                                          Key,
                                          Version,
                                          Artifact)
               )).
artifact_persist_put(_, _, Version, Artifact) :-
    throw(error(domain_error(artifact_record, Version-Artifact),
                context(rlm_artifact_persist,
                        'artifact version and payload must be ground'))).

artifact_persist_get(Namespace, Key, Version, Artifact) :-
    require_attached,
    with_mutex(rlm_artifact_persist,
               artifact_record(Namespace, Key, Version, Artifact)).

artifact_persist_latest(Namespace, Key, Version, Artifact) :-
    require_attached,
    with_mutex(rlm_artifact_persist,
               findall(V-A,
                       artifact_record(Namespace, Key, V, A),
                       Pairs)),
    Pairs \== [],
    keysort(Pairs, Sorted),
    last(Sorted, Version-Artifact).

artifact_persist_list(Namespace, Artifacts) :-
    require_attached,
    with_mutex(rlm_artifact_persist,
               findall(Key-Version-Artifact,
                       artifact_record(Namespace, Key, Version, Artifact),
                       Rows0)),
    sort(Rows0, Rows),
    findall(Artifact, member(_-_-Artifact, Rows), Artifacts).

artifact_persist_delete_namespace(Namespace) :-
    require_attached,
    with_mutex(rlm_artifact_persist,
               retractall_artifact_record(Namespace, _, _, _)).

require_attached :-
    (   db_attached(_)
    ->  true
    ;   throw(error(existence_error(artifact_persistent_backend, attached),
                    context(rlm_artifact_persist,
                            'no artifact persistency file is attached')))
    ).

same_file_or_atom(A, B) :-
    A == B,
    !.
same_file_or_atom(A, B) :-
    catch(same_file(A, B), _, fail).
