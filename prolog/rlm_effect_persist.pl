:- module(rlm_effect_persist,
          [ effect_persist_open/1,
            effect_persist_close/0,
            effect_persist_attached/1,
            effect_persist_put_call/1,
            effect_persist_get_call/3,
            effect_persist_put_attempt/1,
            effect_persist_get_attempt/2,
            effect_persist_attempts/3,
            effect_persist_put_observation/2,
            effect_persist_get_observation/2,
            effect_persist_append_event/2,
            effect_persist_events/2,
            effect_persist_delete_call/1
          ]).

/** <module> Durable storage for effect identity and observations */

:- use_module(library(persistency)).

:- persistent
       effect_call_record(call_id:atom, fingerprint:atom, kind:atom,
                          request:any, logical_key:any, created_at:float),
       effect_attempt_record(attempt_id:atom, call_id:atom, fingerprint:atom,
                             sequence:integer, parent_attempt:any, mode:atom,
                             status:atom, idempotency_key:atom, authority:any,
                             metadata:any, created_at:float, updated_at:float),
       effect_observation_record(attempt_id:atom, observation:any),
       effect_event_record(call_id:atom, sequence:integer, event:any).

effect_persist_open(File) :-
    with_mutex(rlm_effect_persist_db, effect_persist_open_locked(File)).

effect_persist_open_locked(File) :-
    ( db_attached(Current)
    -> ( same_file_or_atom(Current, File)
       -> true
       ;  db_detach, db_attach(File, [sync(close)]) )
    ; db_attach(File, [sync(close)])
    ).

effect_persist_close :-
    with_mutex(rlm_effect_persist_db,
               (db_attached(_) -> db_detach ; true)).

effect_persist_attached(File) :- db_attached(File).

effect_persist_put_call(Call) :-
    require_attached,
    ground(Call),
    Call = effect_call{call_id:CallId, fingerprint:Fingerprint, kind:Kind,
                       request:Request, logical_key:LogicalKey,
                       created_at:CreatedAt},
    with_mutex(rlm_effect_persist_db,
               ( effect_call_record(CallId, Fingerprint, Kind,
                                    ExistingRequest, ExistingKey, _)
               -> ( ExistingRequest == Request, ExistingKey == LogicalKey
                  -> true
                  ; throw(error(permission_error(redefine, effect_call,
                                                 CallId-Fingerprint), _)) )
               ; assert_effect_call_record(CallId, Fingerprint, Kind, Request,
                                           LogicalKey, CreatedAt) )).

effect_persist_get_call(CallId, Fingerprint, Call) :-
    require_attached,
    effect_call_record(CallId, Fingerprint, Kind, Request, LogicalKey, CreatedAt),
    Call = effect_call{call_id:CallId, fingerprint:Fingerprint, kind:Kind,
                       request:Request, logical_key:LogicalKey,
                       created_at:CreatedAt}.

effect_persist_put_attempt(Attempt) :-
    require_attached,
    ground(Attempt),
    Attempt = effect_attempt{attempt_id:AttemptId, call_id:CallId,
                             fingerprint:Fingerprint, sequence:Sequence,
                             parent_attempt:ParentAttempt, mode:Mode,
                             status:Status, idempotency_key:IdempotencyKey,
                             authority:Authority, metadata:Metadata,
                             created_at:CreatedAt, updated_at:UpdatedAt},
    with_mutex(rlm_effect_persist_db,
               ( retractall_effect_attempt_record(AttemptId, _, _, _, _, _,
                                                  _, _, _, _, _, _),
                 assert_effect_attempt_record(AttemptId, CallId, Fingerprint,
                                              Sequence, ParentAttempt, Mode,
                                              Status, IdempotencyKey, Authority,
                                              Metadata, CreatedAt, UpdatedAt) )).

effect_persist_get_attempt(AttemptId, Attempt) :-
    require_attached,
    effect_attempt_record(AttemptId, CallId, Fingerprint, Sequence,
                          ParentAttempt, Mode, Status, IdempotencyKey,
                          Authority, Metadata, CreatedAt, UpdatedAt),
    Attempt = effect_attempt{attempt_id:AttemptId, call_id:CallId,
                             fingerprint:Fingerprint, sequence:Sequence,
                             parent_attempt:ParentAttempt, mode:Mode,
                             status:Status, idempotency_key:IdempotencyKey,
                             authority:Authority, metadata:Metadata,
                             created_at:CreatedAt, updated_at:UpdatedAt}.

effect_persist_attempts(CallId, Fingerprint, Attempts) :-
    require_attached,
    findall(Sequence-Attempt,
            ( effect_attempt_record(AttemptId, CallId, Fingerprint, Sequence,
                                    ParentAttempt, Mode, Status, IdempotencyKey,
                                    Authority, Metadata, CreatedAt, UpdatedAt),
              Attempt = effect_attempt{attempt_id:AttemptId, call_id:CallId,
                                       fingerprint:Fingerprint,
                                       sequence:Sequence,
                                       parent_attempt:ParentAttempt, mode:Mode,
                                       status:Status,
                                       idempotency_key:IdempotencyKey,
                                       authority:Authority, metadata:Metadata,
                                       created_at:CreatedAt, updated_at:UpdatedAt} ),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Attempts).

effect_persist_put_observation(AttemptId, Observation) :-
    require_attached,
    ground(Observation),
    with_mutex(rlm_effect_persist_db,
               ( effect_observation_record(AttemptId, Existing)
               -> (Existing == Observation -> true
                  ; throw(error(permission_error(redefine,
                                                 effect_observation,
                                                 AttemptId), _)))
               ; assert_effect_observation_record(AttemptId, Observation) )).

effect_persist_get_observation(AttemptId, Observation) :-
    require_attached,
    effect_observation_record(AttemptId, Observation).

effect_persist_append_event(CallId, Event0) :-
    require_attached,
    ground(Event0),
    with_mutex(rlm_effect_persist_db,
               ( next_event_sequence(CallId, Sequence),
                 put_dict(sequence, Event0, Sequence, Event),
                 assert_effect_event_record(CallId, Sequence, Event) )).

next_event_sequence(CallId, Sequence) :-
    findall(N, effect_event_record(CallId, N, _), Ns),
    (Ns == [] -> Sequence = 1 ; max_list(Ns, Max), Sequence is Max+1).

effect_persist_events(CallId, Events) :-
    require_attached,
    findall(Sequence-Event, effect_event_record(CallId, Sequence, Event), Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Events).

effect_persist_delete_call(CallId) :-
    require_attached,
    with_mutex(rlm_effect_persist_db,
               ( findall(AttemptId,
                         effect_attempt_record(AttemptId, CallId, _, _, _, _,
                                               _, _, _, _, _, _), AttemptIds),
                 forall(member(AttemptId, AttemptIds),
                        retractall_effect_observation_record(AttemptId, _)),
                 retractall_effect_attempt_record(_, CallId, _, _, _, _, _, _,
                                                  _, _, _, _),
                 retractall_effect_call_record(CallId, _, _, _, _, _),
                 retractall_effect_event_record(CallId, _, _) )).

require_attached :-
    ( db_attached(_) -> true
    ; throw(error(existence_error(effect_persistent_backend, attached),
                  context(rlm_effect_persist,
                          'no effect persistency file is attached'))) ).

same_file_or_atom(A, B) :- A == B, !.
same_file_or_atom(A, B) :- catch(same_file(A, B), _, fail).

pairs_values([], []).
pairs_values([_-Value|Pairs], [Value|Values]) :- pairs_values(Pairs, Values).
