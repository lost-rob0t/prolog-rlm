:- module(rlm_artifact_persist,
          [ artifact_persist_open/1,
            artifact_persist_close/0,
            artifact_persist_append/4,
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

artifact_persist_append(Namespace, Key, BaseArtifact, Artifact) :-
    require_attached,
    ground(BaseArtifact),
    !,
    with_mutex(rlm_artifact_persist,
               ( findall(V,
                         artifact_record(Namespace, Key, V, _),
                         Versions),
                 next_version(Versions, Version),
                 Ref = artifact_ref{namespace:Namespace,
                                    key:Key,
                                    version:Version},
                 put_dict(_{ref:Ref, version:Version},
                          BaseArtifact,
                          Artifact),
                 assert_artifact_record(Namespace,
                                        Key,
                                        Version,
                                        Artifact)
               )).
artifact_persist_append(_, _, BaseArtifact, _) :-
    throw(error(instantiation_error,
                context(rlm_artifact_persist,
                        non_ground_artifact(BaseArtifact)))).

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

next_version([], 1).
next_version(Versions, Version) :-
    Versions \== [],
    max_list(Versions, Latest),
    Version is Latest+1.

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
