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

/** <module> Durable storage for effect identity and observations

Attempt lifecycle writes are append-only revisions.  Updating an attempt never
retracts its previous durable state first, so a process death during a state
transition cannot erase the last authoritative lifecycle fact.  Explicit
retention/deletion is a separate operation.

The persistency journal is intentionally single-writer.  A process holds an OS
advisory lock on a dedicated sidecar file for the entire attached-store
lifetime.  A second process fails closed instead of racing local admission
against the same journal.  The OS releases the lock when the owning process
exits, including abrupt process death, so a fresh process can resume/reconcile.
*/

:- use_module(library(lists)).
:- use_module(library(persistency)).

:- persistent
       effect_call_record(call_id:atom, fingerprint:atom, kind:atom,
                          request:any, logical_key:any, created_at:float),
       effect_attempt_record(attempt_id:atom, revision:integer, call_id:atom,
                             fingerprint:atom, sequence:integer,
                             parent_attempt:any, mode:atom, status:atom,
                             idempotency_key:atom, authority:any,
                             metadata:any, created_at:float, updated_at:float),
       effect_observation_record(attempt_id:atom, observation:any),
       effect_event_record(call_id:atom, sequence:integer, event:any).

:- dynamic effect_store_lock/3.

effect_persist_open(File) :-
    with_mutex(rlm_effect_persist_db, effect_persist_open_locked(File)).

effect_persist_open_locked(File) :-
    (   db_attached(Current)
    ->  (   same_file_or_atom(Current, File)
        ->  ensure_effect_store_lock(File)
        ;   effect_persist_detach_locked,
            effect_persist_attach_locked(File)
        )
    ;   effect_persist_attach_locked(File)
    ).

effect_persist_attach_locked(File) :-
    canonical_store_file(File, Canonical),
    effect_store_lock_file(Canonical, LockFile),
    acquire_effect_store_lock(Canonical, LockFile, Stream),
    catch(db_attach(File, [sync(close)]),
          Exception,
          ( close_effect_store_lock_stream(Stream),
            throw(Exception) )),
    assertz(effect_store_lock(Canonical, LockFile, Stream)).

ensure_effect_store_lock(File) :-
    canonical_store_file(File, Canonical),
    (   effect_store_lock(Locked, _, _),
        same_file_or_atom(Locked, Canonical)
    ->  true
    ;   effect_store_lock_file(Canonical, LockFile),
        acquire_effect_store_lock(Canonical, LockFile, Stream),
        assertz(effect_store_lock(Canonical, LockFile, Stream))
    ).

acquire_effect_store_lock(Canonical, LockFile, Stream) :-
    catch(open(LockFile, append, Stream,
               [ encoding(utf8),
                 lock(exclusive),
                 wait(false)
               ]),
          error(permission_error(lock, source_sink, _), Context),
          throw(error(permission_error(lock, effect_store, Canonical),
                      Context))).

effect_store_lock_file(Canonical, LockFile) :-
    atom_concat(Canonical, '.lock', LockFile).

canonical_store_file(File, Canonical) :-
    catch(absolute_file_name(File, Canonical), _, fail),
    !.
canonical_store_file(File, File).

effect_persist_close :-
    with_mutex(rlm_effect_persist_db, effect_persist_detach_locked).

effect_persist_detach_locked :-
    call_cleanup(
        (   db_attached(_)
        ->  db_detach
        ;   true
        ),
        release_effect_store_lock).

release_effect_store_lock :-
    (   retract(effect_store_lock(_, _, Stream))
    ->  close_effect_store_lock_stream(Stream),
        release_effect_store_lock
    ;   true
    ).

close_effect_store_lock_stream(Stream) :-
    catch(close(Stream), _, true).

effect_persist_attached(File) :-
    db_attached(File).

effect_persist_put_call(Call) :-
    require_attached,
    require_ground(Call),
    Call = effect_call{call_id:CallId,
                       fingerprint:Fingerprint,
                       kind:Kind,
                       request:Request,
                       logical_key:LogicalKey,
                       created_at:CreatedAt},
    with_mutex(rlm_effect_persist_db,
               put_call_locked(CallId, Fingerprint, Kind, Request,
                               LogicalKey, CreatedAt)).

put_call_locked(CallId, Fingerprint, Kind, Request, LogicalKey, CreatedAt) :-
    (   effect_call_record(CallId, Fingerprint, ExistingKind,
                           ExistingRequest, ExistingKey, _)
    ->  (   ExistingKind == Kind,
            ExistingRequest == Request,
            ExistingKey == LogicalKey
        ->  true
        ;   throw(error(permission_error(redefine,
                                         effect_call,
                                         CallId-Fingerprint), _))
        )
    ;   assert_effect_call_record(CallId, Fingerprint, Kind, Request,
                                  LogicalKey, CreatedAt)
    ).

effect_persist_get_call(CallId, Fingerprint, Call) :-
    require_attached,
    effect_call_record(CallId, Fingerprint, Kind, Request, LogicalKey, CreatedAt),
    Call = effect_call{call_id:CallId,
                       fingerprint:Fingerprint,
                       kind:Kind,
                       request:Request,
                       logical_key:LogicalKey,
                       created_at:CreatedAt}.

effect_persist_put_attempt(Attempt) :-
    require_attached,
    require_ground(Attempt),
    Attempt = effect_attempt{attempt_id:AttemptId,
                             revision:Revision,
                             call_id:CallId,
                             fingerprint:Fingerprint,
                             sequence:Sequence,
                             parent_attempt:ParentAttempt,
                             mode:Mode,
                             status:Status,
                             idempotency_key:IdempotencyKey,
                             authority:Authority,
                             metadata:Metadata,
                             created_at:CreatedAt,
                             updated_at:UpdatedAt},
    with_mutex(rlm_effect_persist_db,
               put_attempt_locked(AttemptId, Revision, CallId, Fingerprint,
                                  Sequence, ParentAttempt, Mode, Status,
                                  IdempotencyKey, Authority, Metadata,
                                  CreatedAt, UpdatedAt)).

put_attempt_locked(AttemptId, Revision, CallId, Fingerprint, Sequence,
                   ParentAttempt, Mode, Status, IdempotencyKey, Authority,
                   Metadata, CreatedAt, UpdatedAt) :-
    latest_attempt_revision_locked(AttemptId, LatestRevision, Latest),
    validate_attempt_revision(LatestRevision, Revision, AttemptId),
    validate_attempt_identity(Latest, CallId, Fingerprint, Sequence,
                              ParentAttempt, Mode, IdempotencyKey, CreatedAt,
                              AttemptId),
    assert_effect_attempt_record(AttemptId, Revision, CallId, Fingerprint,
                                 Sequence, ParentAttempt, Mode, Status,
                                 IdempotencyKey, Authority, Metadata,
                                 CreatedAt, UpdatedAt).

latest_attempt_revision_locked(AttemptId, Revision, Attempt) :-
    findall(R, effect_attempt_record(AttemptId, R, _, _, _, _, _, _, _, _, _, _, _),
            Revisions),
    (   Revisions == []
    ->  Revision = 0,
        Attempt = none
    ;   max_list(Revisions, Revision),
        attempt_at_revision(AttemptId, Revision, Attempt)
    ).

attempt_at_revision(AttemptId, Revision, Attempt) :-
    effect_attempt_record(AttemptId, Revision, CallId, Fingerprint, Sequence,
                          ParentAttempt, Mode, Status, IdempotencyKey,
                          Authority, Metadata, CreatedAt, UpdatedAt),
    Attempt = effect_attempt{attempt_id:AttemptId,
                             revision:Revision,
                             call_id:CallId,
                             fingerprint:Fingerprint,
                             sequence:Sequence,
                             parent_attempt:ParentAttempt,
                             mode:Mode,
                             status:Status,
                             idempotency_key:IdempotencyKey,
                             authority:Authority,
                             metadata:Metadata,
                             created_at:CreatedAt,
                             updated_at:UpdatedAt}.

validate_attempt_revision(0, 1, _) :- !.
validate_attempt_revision(Latest, Revision, _) :-
    Revision =:= Latest+1,
    !.
validate_attempt_revision(Latest, Revision, AttemptId) :-
    throw(error(domain_error(effect_attempt_revision,
                             attempt(AttemptId, Latest, Revision)), _)).

validate_attempt_identity(none, _, _, _, _, _, _, _, _) :- !.
validate_attempt_identity(Previous, CallId, Fingerprint, Sequence,
                          ParentAttempt, Mode, IdempotencyKey, CreatedAt,
                          AttemptId) :-
    (   Previous.call_id == CallId,
        Previous.fingerprint == Fingerprint,
        Previous.sequence =:= Sequence,
        Previous.parent_attempt == ParentAttempt,
        Previous.mode == Mode,
        Previous.idempotency_key == IdempotencyKey,
        Previous.created_at =:= CreatedAt
    ->  true
    ;   throw(error(permission_error(redefine,
                                     effect_attempt_identity,
                                     AttemptId), _))
    ).

effect_persist_get_attempt(AttemptId, Attempt) :-
    require_attached,
    with_mutex(rlm_effect_persist_db,
               latest_attempt_revision_locked(AttemptId, Revision, Attempt)),
    Revision > 0.

effect_persist_attempts(CallId, Fingerprint, Attempts) :-
    require_attached,
    with_mutex(rlm_effect_persist_db,
               findall(AttemptId,
                       effect_attempt_record(AttemptId, _, CallId, Fingerprint,
                                             _, _, _, _, _, _, _, _, _),
                       AttemptIds0)),
    sort(AttemptIds0, AttemptIds),
    maplist(effect_persist_get_attempt, AttemptIds, Unsorted),
    findall(Sequence-Attempt,
            ( member(Attempt, Unsorted), Sequence = Attempt.sequence ),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Attempts).

effect_persist_put_observation(AttemptId, Observation) :-
    require_attached,
    require_ground(Observation),
    with_mutex(rlm_effect_persist_db,
               put_observation_locked(AttemptId, Observation)).

put_observation_locked(AttemptId, Observation) :-
    (   effect_observation_record(AttemptId, Existing)
    ->  (   Existing == Observation
        ->  true
        ;   throw(error(permission_error(redefine,
                                         effect_observation,
                                         AttemptId), _))
        )
    ;   assert_effect_observation_record(AttemptId, Observation)
    ).

effect_persist_get_observation(AttemptId, Observation) :-
    require_attached,
    effect_observation_record(AttemptId, Observation).

effect_persist_append_event(CallId, Event0) :-
    require_attached,
    require_ground(Event0),
    with_mutex(rlm_effect_persist_db,
               ( next_event_sequence_locked(CallId, Sequence),
                 put_dict(sequence, Event0, Sequence, Event),
                 assert_effect_event_record(CallId, Sequence, Event)
               )).

next_event_sequence_locked(CallId, Sequence) :-
    findall(N, effect_event_record(CallId, N, _), Ns),
    (   Ns == []
    ->  Sequence = 1
    ;   max_list(Ns, Max),
        Sequence is Max+1
    ).

effect_persist_events(CallId, Events) :-
    require_attached,
    findall(Sequence-Event,
            effect_event_record(CallId, Sequence, Event),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Events).

effect_persist_delete_call(CallId) :-
    require_attached,
    with_mutex(rlm_effect_persist_db,
               ( findall(AttemptId,
                         effect_attempt_record(AttemptId, _, CallId, _, _, _,
                                               _, _, _, _, _, _, _),
                         AttemptIds0),
                 sort(AttemptIds0, AttemptIds),
                 forall(member(AttemptId, AttemptIds),
                        retractall_effect_observation_record(AttemptId, _)),
                 retractall_effect_attempt_record(_, _, CallId, _, _, _, _, _,
                                                  _, _, _, _, _),
                 retractall_effect_call_record(CallId, _, _, _, _, _),
                 retractall_effect_event_record(CallId, _, _)
               )).

require_ground(Value) :-
    ground(Value),
    !.
require_ground(Value) :-
    throw(error(instantiation_error,
                context(rlm_effect_persist, non_ground_value(Value)))).

require_attached :-
    (   db_attached(_)
    ->  true
    ;   throw(error(existence_error(effect_persistent_backend, attached),
                    context(rlm_effect_persist,
                            'no effect persistency file is attached')))
    ).

same_file_or_atom(A, B) :- A == B, !.
same_file_or_atom(A, B) :- catch(same_file(A, B), _, fail).

pairs_values([], []).
pairs_values([_-Value|Pairs], [Value|Values]) :- pairs_values(Pairs, Values).
