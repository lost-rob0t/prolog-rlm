:- module(rlm_graph_persist,
          [ graph_persist_open/1,
            graph_persist_close/0,
            graph_persist_put_checkpoint/3,
            graph_persist_get_checkpoint/3,
            graph_persist_append_event/3,
            graph_persist_history/2,
            graph_persist_delete_run/1
          ]).

/** <module> SWI persistency backend for durable graph execution */

:- use_module(library(persistency)).

:- persistent
       graph_checkpoint_record(run_id:atom,
                               graph_id:atom,
                               snapshot:any),
       graph_event_record(run_id:atom,
                          sequence:integer,
                          event:any).

graph_persist_open(File) :-
    with_mutex(rlm_graph_persist,
               graph_persist_open_locked(File)).

graph_persist_open_locked(File) :-
    (   db_attached(Current)
    ->  (   same_file_or_atom(Current, File)
        ->  true
        ;   db_detach,
            db_attach(File, [sync(close)])
        )
    ;   db_attach(File, [sync(close)])
    ).

graph_persist_close :-
    with_mutex(rlm_graph_persist,
               (   db_attached(_)
               ->  db_detach
               ;   true
               )).

graph_persist_put_checkpoint(RunId, GraphId, Snapshot) :-
    require_attached,
    ground(Snapshot),
    !,
    with_mutex(rlm_graph_persist,
               ( retractall_graph_checkpoint_record(RunId, _, _),
                 assert_graph_checkpoint_record(RunId, GraphId, Snapshot)
               )).
graph_persist_put_checkpoint(_, _, Snapshot) :-
    throw(error(instantiation_error,
                context(rlm_graph_persist,
                        non_ground_checkpoint(Snapshot)))).

graph_persist_get_checkpoint(RunId, GraphId, Snapshot) :-
    require_attached,
    with_mutex(rlm_graph_persist,
               graph_checkpoint_record(RunId, GraphId, Snapshot)).

graph_persist_append_event(RunId, Sequence, Event) :-
    require_attached,
    ground(Event),
    !,
    with_mutex(rlm_graph_persist,
               assert_graph_event_record(RunId, Sequence, Event)).
graph_persist_append_event(_, _, Event) :-
    throw(error(instantiation_error,
                context(rlm_graph_persist,
                        non_ground_event(Event)))).

graph_persist_history(RunId, Events) :-
    require_attached,
    with_mutex(rlm_graph_persist,
               findall(Sequence-Event,
                       graph_event_record(RunId, Sequence, Event),
                       Pairs0)),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Events).

graph_persist_delete_run(RunId) :-
    require_attached,
    with_mutex(rlm_graph_persist,
               ( retractall_graph_checkpoint_record(RunId, _, _),
                 retractall_graph_event_record(RunId, _, _)
               )).

require_attached :-
    (   db_attached(_)
    ->  true
    ;   throw(error(existence_error(graph_persistent_backend, attached),
                    context(rlm_graph_persist,
                            'no graph persistency file is attached')))
    ).

same_file_or_atom(A, B) :-
    A == B,
    !.
same_file_or_atom(A, B) :-
    catch(same_file(A, B), _, fail).

pairs_values([], []).
pairs_values([_-Value|Pairs], [Value|Values]) :-
    pairs_values(Pairs, Values).
