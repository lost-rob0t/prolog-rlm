:- module(rlm_effect_persist,
          [ effect_persist_open/1,
            effect_persist_close/0,
            effect_persist_attached/1,
            effect_persist_store_id/1,
            effect_persist_acquire_lease/2,
            effect_persist_release_lease/1,
            effect_persist_current_epoch/2,
            effect_persist_advance_epoch/2,
            effect_persist_put_call_scope/4,
            effect_persist_get_call_scope/4,
            effect_persist_put_call/1,
            effect_persist_get_call/3,
            effect_persist_put_attempt/1,
            effect_persist_get_attempt/2,
            effect_persist_attempts/3,
            effect_persist_put_observation/2,
            effect_persist_get_observation/2,
            effect_persist_append_event/2,
            effect_persist_events/2,
            effect_persist_migration_source_open/4,
            effect_persist_migration_source_close/1,
            effect_persist_migration_path_lock/2,
            effect_persist_write_migrated/5,
            effect_persist_migration_info/1,
            effect_persist_legacy_adapter/2,
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
:- use_module(library(uuid)).

:- persistent
       effect_call_record(call_id:atom, fingerprint:atom, kind:atom,
                          request:any, logical_key:any, created_at:float),
       effect_attempt_record(attempt_id:atom, revision:integer, call_id:atom,
                             fingerprint:atom, sequence:integer,
                             parent_attempt:any, mode:atom, status:atom,
                             idempotency_key:atom, authority:any,
                             metadata:any, created_at:float, updated_at:float),
       effect_observation_record(attempt_id:atom, observation:any),
       effect_event_record(call_id:atom, sequence:integer, event:any),
       effect_store_metadata(key:atom, value:any),
       effect_call_scope_record(call_id:atom, store_id:atom,
                                base_call_id:atom, epoch:integer),
       effect_epoch_record(store_id:atom, base_call_id:atom, epoch:integer),
       effect_migration_record(migration_id:atom, source_schema:integer,
                               source_digest:atom, destination_path:atom,
                               created_at:float, status:atom),
       effect_legacy_adapter_binding_record(attempt_id:atom, adapter:atom).

:- dynamic effect_store_lock/3.
:- dynamic effect_store_lease/2.

effect_persist_open(File) :-
    with_mutex(rlm_effect_persist_db, effect_persist_open_locked(File)).

effect_persist_open_locked(File) :-
    (   db_attached(Current)
    ->  (   same_file_or_atom(Current, File)
        ->  ensure_effect_store_lock(File),
            ensure_effect_store_metadata(File)
        ;   require_no_active_effect_leases(switch, Current),
            effect_persist_detach_locked,
            effect_persist_attach_locked(File)
        )
    ;   effect_persist_attach_locked(File)
    ).

effect_persist_attach_locked(File) :-
    canonical_store_file(File, Canonical),
    effect_store_lock_file(Canonical, LockFile),
    acquire_effect_store_lock(Canonical, LockFile, Stream),
    catch(( db_attach(File, [sync(close)]),
            ensure_effect_store_metadata(File) ),
          Exception,
          ( catch(db_detach, _, true),
            close_effect_store_lock_stream(Stream),
            throw(Exception) )),
    assertz(effect_store_lock(Canonical, LockFile, Stream)).

ensure_effect_store_metadata(File) :-
    findall(StoreId, effect_store_metadata(namespace, StoreId), StoreIds),
    ensure_single_store_namespace(StoreIds),
    ensure_schema_version,
    ensure_migrated_path_binding(File).

ensure_migrated_path_binding(File) :-
    findall(Path,
            effect_migration_record(_, 1, _, Path, _, complete),
            Paths),
    (   Paths == []
    ->  true
    ;   sort(Paths, [Expected]),
        canonical_store_file(File, Actual),
        ( same_file_or_atom(Expected, Actual)
        -> true
        ;  throw(error(permission_error(open, migrated_effect_store_copy,
                                         Expected-Actual), _)) )
    ).

ensure_single_store_namespace([StoreId]) :-
    atom(StoreId),
    StoreId \== '',
    !.
ensure_single_store_namespace([]) :-
    !,
    (   legacy_effect_records_exist
    ->  db_attached(File),
        throw(error(permission_error(open,
                                     legacy_effect_store_requires_migration,
                                     File), _))
    ;   uuid(UUID, [version(4)]),
        atom_concat('effect-store:', UUID, StoreId),
        assert_effect_store_metadata(namespace, StoreId)
    ).
ensure_single_store_namespace(_) :-
    throw(error(domain_error(effect_store_namespace, corrupt), _)).

ensure_schema_version :-
    findall(Version, effect_store_metadata(schema_version, Version), Versions),
    (   Versions == []
    ->  assert_effect_store_metadata(schema_version, 2)
    ;   Versions == [2]
    ->  true
    ;   throw(error(domain_error(effect_store_schema_version, Versions), _))
    ).

legacy_effect_records_exist :-
    effect_call_record(_, _, _, _, _, _),
    !.
legacy_effect_records_exist :-
    effect_attempt_record(_, _, _, _, _, _, _, _, _, _, _, _, _),
    !.
legacy_effect_records_exist :-
    effect_observation_record(_, _),
    !.
legacy_effect_records_exist :-
    effect_event_record(_, _, _).

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
    with_mutex(rlm_effect_persist_db,
               ( ( db_attached(Current)
                 -> require_no_active_effect_leases(close, Current)
                 ;  true
                 ),
                 effect_persist_detach_locked
               )).

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

effect_persist_store_id(StoreId) :-
    require_attached,
    effect_store_metadata(namespace, StoreId).

effect_persist_acquire_lease(ExpectedStoreId, Lease) :-
    with_mutex(rlm_effect_persist_db,
               acquire_effect_lease_locked(ExpectedStoreId, Lease)).

acquire_effect_lease_locked(ExpectedStoreId, Lease) :-
    effect_persist_store_id(CurrentStoreId),
    (   CurrentStoreId == ExpectedStoreId
    ->  uuid(UUID, [version(4)]),
        atom_concat('effect-lease:', UUID, Lease),
        assertz(effect_store_lease(Lease, CurrentStoreId))
    ;   throw(error(permission_error(acquire, effect_store_lease,
                                     ExpectedStoreId-CurrentStoreId), _))
    ).

effect_persist_release_lease(Lease) :-
    with_mutex(rlm_effect_persist_db,
               retractall(effect_store_lease(Lease, _))).

require_no_active_effect_leases(Action, Store) :-
    (   effect_store_lease(_, StoreId)
    ->  throw(error(permission_error(Action, effect_store,
                                     active_effects(Store, StoreId)), _))
    ;   true
    ).

effect_persist_current_epoch(BaseCallId, Epoch) :-
    require_attached,
    effect_persist_store_id(StoreId),
    with_mutex(rlm_effect_persist_db,
               current_epoch_locked(StoreId, BaseCallId, Epoch)).

current_epoch_locked(StoreId, BaseCallId, Epoch) :-
    findall(E, effect_epoch_record(StoreId, BaseCallId, E), Epochs),
    (   Epochs == []
    ->  Epoch = 1,
        assert_effect_epoch_record(StoreId, BaseCallId, Epoch)
    ;   max_list(Epochs, Epoch)
    ).

effect_persist_advance_epoch(CallId, NextEpoch) :-
    require_attached,
    with_mutex(rlm_effect_persist_db,
               advance_epoch_locked(CallId, NextEpoch)).

advance_epoch_locked(CallId, NextEpoch) :-
    effect_call_scope_record(CallId, StoreId, BaseCallId, CallEpoch),
    current_epoch_locked(StoreId, BaseCallId, CurrentEpoch),
    (   CurrentEpoch =:= CallEpoch
    ->  NextEpoch is CurrentEpoch+1,
        assert_effect_epoch_record(StoreId, BaseCallId, NextEpoch)
    ;   NextEpoch = CurrentEpoch
    ).

effect_persist_put_call_scope(CallId, StoreId, BaseCallId, Epoch) :-
    require_attached,
    with_mutex(rlm_effect_persist_db,
               put_call_scope_locked(CallId, StoreId, BaseCallId, Epoch)).

put_call_scope_locked(CallId, StoreId, BaseCallId, Epoch) :-
    (   effect_call_scope_record(CallId, ExistingStore, ExistingBase,
                                 ExistingEpoch)
    ->  ( ExistingStore == StoreId,
          ExistingBase == BaseCallId,
          ExistingEpoch =:= Epoch
        -> true
        ;  throw(error(permission_error(redefine, effect_call_scope,
                                        CallId), _)) )
    ;   assert_effect_call_scope_record(CallId, StoreId, BaseCallId, Epoch)
    ).

effect_persist_get_call_scope(CallId, StoreId, BaseCallId, Epoch) :-
    require_attached,
    effect_call_scope_record(CallId, StoreId, BaseCallId, Epoch).

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
               append_event_locked(CallId, Event0)).

append_event_locked(CallId, Event0) :-
    get_dict(event_id, Event0, EventId),
    (   effect_event_record(CallId, _, Existing),
        get_dict(event_id, Existing, EventId)
    ->  true
    ;   next_event_sequence_locked(CallId, Sequence),
        put_dict(sequence, Event0, Sequence, Event),
        assert_effect_event_record(CallId, Sequence, Event)
    ).

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

/* Offline migration support ------------------------------------------- */

effect_persist_migration_source_open(File, Handle, Schema, Snapshot) :-
    with_mutex(rlm_effect_persist_db,
               migration_source_open_locked(File, Handle, Schema, Snapshot)).

migration_source_open_locked(File, Handle, Schema, Snapshot) :-
    (   db_attached(Current)
    ->  throw(error(permission_error(migrate, effect_store,
                                     already_attached(Current)), _))
    ;   true
    ),
    canonical_store_file(File, Canonical),
    effect_store_lock_file(Canonical, LockFile),
    acquire_effect_store_lock(Canonical, LockFile, Stream),
    catch(( db_attach(File, [sync(close)]),
            migration_schema(Schema),
            migration_snapshot(Snapshot),
            db_detach,
            Handle = migration_source(Canonical, LockFile, Stream) ),
          Exception,
          ( catch(db_detach, _, true),
            close_effect_store_lock_stream(Stream),
            throw(Exception) )).

effect_persist_migration_source_close(migration_source(_, _, Stream)) :-
    close_effect_store_lock_stream(Stream).
effect_persist_migration_source_close(migration_path(_, _, Stream)) :-
    close_effect_store_lock_stream(Stream).

effect_persist_migration_path_lock(File,
                                   migration_path(Canonical, LockFile,
                                                  Stream)) :-
    canonical_store_file(File, Canonical),
    effect_store_lock_file(Canonical, LockFile),
    acquire_effect_store_lock(Canonical, LockFile, Stream).

migration_schema(v1) :-
    \+ effect_store_metadata(schema_version, _),
    legacy_effect_records_exist,
    !.
migration_schema(empty) :-
    \+ effect_store_metadata(schema_version, _),
    \+ legacy_effect_records_exist,
    !.
migration_schema(v2) :-
    findall(Version, effect_store_metadata(schema_version, Version), [2]),
    !.
migration_schema(incompatible(Versions)) :-
    findall(Version, effect_store_metadata(schema_version, Version), Versions).

migration_snapshot(Snapshot) :-
    findall(effect_call{call_id:CallId,
                        fingerprint:Fingerprint,
                        kind:Kind,
                        request:Request,
                        logical_key:LogicalKey,
                        created_at:CreatedAt},
            effect_call_record(CallId, Fingerprint, Kind, Request,
                               LogicalKey, CreatedAt),
            Calls),
    findall(effect_attempt{attempt_id:AttemptId,
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
            effect_attempt_record(AttemptId, Revision, CallId, Fingerprint,
                                  Sequence, ParentAttempt, Mode, Status,
                                  IdempotencyKey, Authority, Metadata,
                                  CreatedAt, UpdatedAt),
            Attempts),
    findall(AttemptId-Observation,
            effect_observation_record(AttemptId, Observation),
            Observations),
    findall(CallId-Sequence-Event,
            effect_event_record(CallId, Sequence, Event),
            Events),
    findall(Key-Value, effect_store_metadata(Key, Value), Metadata),
    findall(call_scope(CallId, StoreId, BaseCallId, Epoch),
            effect_call_scope_record(CallId, StoreId, BaseCallId, Epoch),
            Scopes),
    findall(epoch(StoreId, BaseCallId, Epoch),
            effect_epoch_record(StoreId, BaseCallId, Epoch),
            Epochs),
    findall(migration(MigrationId, SourceSchema, SourceDigest,
                      Destination, CreatedAt, Status),
            effect_migration_record(MigrationId, SourceSchema, SourceDigest,
                                    Destination, CreatedAt, Status),
            Migrations),
    findall(binding(AttemptId, Adapter),
            effect_legacy_adapter_binding_record(AttemptId, Adapter),
            Bindings),
    Snapshot = effect_snapshot{calls:Calls,
                               attempts:Attempts,
                               observations:Observations,
                               events:Events,
                               metadata:Metadata,
                               scopes:Scopes,
                               epochs:Epochs,
                               migrations:Migrations,
                               bindings:Bindings}.

effect_persist_write_migrated(File, Snapshot, Migration, Bindings, StoreId) :-
    with_mutex(rlm_effect_persist_db,
               write_migrated_locked(File, Snapshot, Migration,
                                     Bindings, StoreId)).

write_migrated_locked(File, Snapshot, Migration, Bindings, StoreId) :-
    (   db_attached(Current)
    ->  throw(error(permission_error(migrate, effect_store,
                                     already_attached(Current)), _))
    ;   true
    ),
    catch(( db_attach(File, [sync(close)]),
            write_legacy_snapshot(Snapshot),
            assert_effect_store_metadata(namespace, StoreId),
            assert_effect_store_metadata(schema_version, 2),
            assert_effect_store_metadata(migrated_from_schema, 1),
            assert_effect_store_metadata(migration_id, Migration.id),
            assert_effect_store_metadata(source_digest, Migration.source_digest),
            assert_effect_migration_record(Migration.id, 1,
                                           Migration.source_digest,
                                           Migration.destination,
                                           Migration.created_at, complete),
            forall(member(binding(AttemptId, Adapter), Bindings),
                   assert_effect_legacy_adapter_binding_record(AttemptId,
                                                               Adapter)),
            db_sync(gc(always)),
            db_detach ),
          Exception,
          ( catch(db_detach, _, true),
            throw(Exception) )).

write_legacy_snapshot(Snapshot) :-
    forall(member(Call, Snapshot.calls),
           assert_effect_call_record(Call.call_id, Call.fingerprint,
                                     Call.kind, Call.request,
                                     Call.logical_key, Call.created_at)),
    forall(member(Attempt, Snapshot.attempts),
           assert_effect_attempt_record(Attempt.attempt_id, Attempt.revision,
                                        Attempt.call_id, Attempt.fingerprint,
                                        Attempt.sequence,
                                        Attempt.parent_attempt, Attempt.mode,
                                        Attempt.status,
                                        Attempt.idempotency_key,
                                        Attempt.authority, Attempt.metadata,
                                        Attempt.created_at,
                                        Attempt.updated_at)),
    forall(member(AttemptId-Observation, Snapshot.observations),
           assert_effect_observation_record(AttemptId, Observation)),
    forall(member(CallId-Sequence-Event, Snapshot.events),
           assert_effect_event_record(CallId, Sequence, Event)).

effect_persist_migration_info(Info) :-
    require_attached,
    effect_migration_record(MigrationId, SourceSchema, SourceDigest,
                            Destination, CreatedAt, complete),
    Info = effect_migration{id:MigrationId,
                            source_schema:SourceSchema,
                            source_digest:SourceDigest,
                            destination:Destination,
                            created_at:CreatedAt,
                            status:complete}.

effect_persist_legacy_adapter(AttemptId, Adapter) :-
    require_attached,
    effect_legacy_adapter_binding_record(AttemptId, Adapter).

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
