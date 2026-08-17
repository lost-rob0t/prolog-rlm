:- module(rlm_effect_migration,
          [ effect_store_migrate/2,
            effect_migration_validate_snapshot/2,
            effect_migration_read_manifest/4
          ]).

/** <module> Explicit offline migration for PR #78 effect journals

Migration never calls an effect adapter.  It preserves legacy durable facts as
authoritative history and adds only v2 store metadata plus separately audited
adapter bindings.  New execution continues through the normal v2 ticket
constructor; legacy tickets are never made admissible.
*/

:- use_module(library(crypto)).
:- use_module(library(http/json)).
:- use_module(library(lists)).
:- use_module(library(pairs)).
:- use_module(library(process)).
:- use_module(library(readutil)).
:- use_module(rlm_effect_persist, []).

effect_store_migrate(Options0, Report) :-
    migration_report_base(Base),
    catch(( normalize_migration_options(Options0, Options),
            migrate_effect_store(Options, Base, Report0) ),
          Exception,
          migration_exception_report(Exception, Base, Report0)),
    Report = Report0.

migration_report_base(
    effect_migration_report{
        report_schema:'prolog-rlm.effect-migration-report.v1',
        status:validation_failed,
        source_path:none,
        destination_path:none,
        source_schema:unknown,
        destination_schema:2,
        migration_id:none,
        store_namespace:none,
        source_verification_digest:none,
        migrated_call_count:0,
        migrated_attempt_count:0,
        observation_count:0,
        event_count:0,
        unresolved_attempt_count:0,
        attempts_requiring_adapter_bindings:[],
        preserved_provider_key_count:0,
        backup_path:none,
        validation_result:not_run,
        warnings:[]
    }).

normalize_migration_options(Options0, Options) :-
    ( is_dict(Options0), ground(Options0) -> true
    ; throw(migration_fault(incompatible, invalid_options)) ),
    dict_keys(Options0, Keys),
    forall(member(Key, Keys),
           ( memberchk(Key, [source,output,manifest,backup,in_place]) -> true
           ; throw(migration_fault(incompatible, unknown_option(Key))) )),
    Defaults = migration_options{output:none,
                                 manifest:none,
                                 backup:none,
                                 in_place:false},
    put_dict(Options0, Defaults, Merged),
    require_path_option(Merged.source, source, Source),
    normalize_bool(Merged.in_place, InPlace),
    destination_option(InPlace, Source, Merged.output, Destination),
    backup_option(InPlace, Source, Merged.backup, Backup),
    optional_path(Merged.manifest, manifest, Manifest),
    Options = Merged.put(_{source:Source,
                           output:Destination,
                           backup:Backup,
                           manifest:Manifest,
                           in_place:InPlace}).

require_path_option(Value, _, Path) :-
    path_atom(Value, Path),
    Path \== '',
    !.
require_path_option(_, Role, _) :-
    throw(migration_fault(incompatible, missing_or_invalid_path(Role))).

optional_path(none, _, none) :- !.
optional_path(Value, Role, Path) :- require_path_option(Value, Role, Path).

path_atom(Value, Value) :- atom(Value), !.
path_atom(Value, Path) :- string(Value), atom_string(Path, Value).

normalize_bool(true, true) :- !.
normalize_bool(false, false) :- !.
normalize_bool(_, _) :-
    throw(migration_fault(incompatible, invalid_in_place_flag)).

destination_option(true, Source, none, Source) :- !.
destination_option(true, Source, Value, Source) :-
    require_path_option(Value, output, Output),
    path_alias(Source, Output),
    !.
destination_option(true, _, _, _) :-
    throw(migration_fault(incompatible, in_place_output_mismatch)).
destination_option(false, _, none, _) :-
    throw(migration_fault(incompatible, output_required)).
destination_option(false, Source, Value, Output) :-
    require_path_option(Value, output, Output),
    ( path_alias(Source, Output)
    -> throw(migration_fault(incompatible, source_output_alias_collision))
    ;  true ).

backup_option(false, _, none, none) :- !.
backup_option(false, _, Value, Backup) :-
    optional_path(Value, backup, Backup).
backup_option(true, _, none, _) :-
    throw(migration_fault(incompatible, backup_required_for_in_place)).
backup_option(true, Source, Value, Backup) :-
    require_path_option(Value, backup, Backup),
    ( path_alias(Source, Backup)
    -> throw(migration_fault(incompatible, source_backup_alias_collision))
    ;  true ).

migrate_effect_store(Options, Base, Report) :-
    canonical_existing_path(Options.source, Source),
    canonical_destination_path(Options.output, Destination),
    put_dict(_{source_path:Source,destination_path:Destination}, Base, B1),
    setup_call_cleanup(
        rlm_effect_persist:effect_persist_migration_source_open(
            Source, SourceHandle, Schema, Snapshot),
        migrate_locked(Schema, Snapshot, Source, Destination, Options,
                       B1, Report),
        rlm_effect_persist:effect_persist_migration_source_close(SourceHandle)).

migrate_locked(v2, Snapshot, _, _, _, Base, Report) :-
    !,
    existing_v2_report(Snapshot, Base, Report).
migrate_locked(incompatible(Versions), _, _, _, _, _, _) :-
    !,
    throw(migration_fault(incompatible, schema_versions(Versions))).
migrate_locked(Schema, Snapshot, Source, Destination, Options, Base, Report) :-
    memberchk(Schema, [v1,empty]),
    source_file_digest(Source, SourceDigest),
    migration_phase(source_locked),
    validate_source_schema(Schema, Snapshot),
    effect_migration_validate_snapshot(Snapshot, Validation),
    migration_phase(source_validated),
    effect_migration_read_manifest(Options.manifest, SourceDigest, Snapshot,
                                   Bindings),
    unresolved_attempts(Snapshot, Unresolved),
    attempts_without_bindings(Unresolved, Bindings, Snapshot,
                              MissingBindings),
    deterministic_migration_identity(SourceDigest, Destination,
                                     MigrationId, StoreId),
    counts(Snapshot, Counts),
    warnings(MissingBindings, Warnings),
    canonical_destination_preflight(Source, Destination, Options),
    setup_call_cleanup(
        destination_lock(Source, Destination, DestinationHandle),
        publish_migration(Snapshot, Bindings, Source, Destination, Options,
                          SourceDigest, MigrationId, StoreId),
        destination_unlock(DestinationHandle)),
    migration_phase(published),
    report_success(Base, Schema, SourceDigest, MigrationId, StoreId,
                   Counts, Unresolved, MissingBindings, Options,
                   Validation, Warnings, Report).

existing_v2_report(Snapshot, Base, Report) :-
    effect_migration_validate_snapshot(Snapshot, _),
    metadata_value(Snapshot.metadata, namespace, StoreId),
    ( member(migration(MigrationId, SourceSchema, SourceDigest,
                       Destination, _, complete), Snapshot.migrations)
    -> true
    ;  MigrationId = none,
       SourceSchema = 2,
       SourceDigest = none,
       Destination = Base.source_path ),
    counts(Snapshot, Counts),
    Report = Base.put(_{status:already_migrated,
                        source_schema:SourceSchema,
                        migration_id:MigrationId,
                        store_namespace:StoreId,
                        source_verification_digest:SourceDigest,
                        destination_path:Destination,
                        migrated_call_count:Counts.calls,
                        migrated_attempt_count:Counts.attempts,
                        observation_count:Counts.observations,
                        event_count:Counts.events,
                        preserved_provider_key_count:Counts.provider_keys,
                        validation_result:pass}).

publish_migration(Snapshot, Bindings, Source, Destination, Options,
                  SourceDigest, MigrationId, StoreId) :-
    maybe_create_backup(Options, Source, SourceDigest),
    migration_phase(backup_complete),
    temporary_destination(Destination, Temp),
    cleanup_stale_temp(Temp),
    get_time(Now),
    Migration = migration{id:MigrationId,
                          source_digest:SourceDigest,
                          destination:Destination,
                          created_at:Now},
    catch(( rlm_effect_persist:effect_persist_write_migrated(
                Temp, Snapshot, Migration, Bindings, StoreId),
            migration_phase(data_flushed),
            validate_staged_store(Temp, Snapshot, SourceDigest, StoreId,
                                  Bindings),
            migration_phase(validated),
            durable_file(Temp),
            migration_phase(before_publication),
            publish_destination(Temp, Destination, Options.in_place),
            durable_parent(Destination),
            migration_phase(after_publication) ),
          Exception,
          ( cleanup_failed_temp(Temp), throw(Exception) )).

destination_lock(Source, Destination, none) :-
    path_alias(Source, Destination),
    !.
destination_lock(_, Destination, Handle) :-
    rlm_effect_persist:effect_persist_migration_path_lock(Destination, Handle).

destination_unlock(none) :- !.
destination_unlock(Handle) :-
    rlm_effect_persist:effect_persist_migration_source_close(Handle).

canonical_destination_preflight(Source, Destination, Options) :-
    ( Options.in_place == true
    -> ( path_alias(Source, Destination) -> true
       ; throw(migration_fault(incompatible, in_place_alias_changed)) )
    ;  ( exists_file(Destination)
       -> throw(migration_fault(incompatible, destination_exists))
       ;  true )
    ),
    ( Options.backup \== none, exists_file(Options.backup)
    -> throw(migration_fault(incompatible, backup_exists))
    ;  true ).

maybe_create_backup(Options, Source, SourceDigest) :-
    ( Options.in_place == true
    -> canonical_destination_path(Options.backup, Backup),
       copy_binary_file(Source, Backup),
       durable_file(Backup),
       source_file_digest(Backup, BackupDigest),
       ( BackupDigest == SourceDigest
       -> true
       ;  throw(migration_fault(validation_failed, backup_digest_mismatch)) )
    ;  true ).

copy_binary_file(Source, Destination) :-
    setup_call_cleanup(open(Source, read, In, [type(binary)]),
        setup_call_cleanup(open(Destination, write, Out,
                                [type(binary),create([read,write])]),
                           copy_stream_data(In, Out),
                           close(Out)),
        close(In)).

publish_destination(Temp, Destination, false) :-
    ( exists_file(Destination)
    -> throw(migration_fault(incompatible, destination_raced))
    ;  rename_file(Temp, Destination) ).
publish_destination(Temp, Destination, true) :-
    rename_file(Temp, Destination).

validate_staged_store(Temp, Original, SourceDigest, StoreId, Bindings) :-
    setup_call_cleanup(
        rlm_effect_persist:effect_persist_migration_source_open(
            Temp, Handle, v2, Migrated),
        validate_staged_snapshot(Migrated, Original, SourceDigest,
                                 StoreId, Bindings),
        rlm_effect_persist:effect_persist_migration_source_close(Handle)).

validate_staged_snapshot(Migrated, Original, SourceDigest, StoreId, Bindings) :-
    effect_migration_validate_snapshot(Migrated, _),
    Migrated.calls == Original.calls,
    Migrated.attempts == Original.attempts,
    Migrated.observations == Original.observations,
    Migrated.events == Original.events,
    metadata_value(Migrated.metadata, namespace, StoreId),
    metadata_value(Migrated.metadata, schema_version, 2),
    metadata_value(Migrated.metadata, source_digest, SourceDigest),
    sort(Migrated.bindings, SortedBindings),
    sort(Bindings, SortedBindings),
    !.
validate_staged_snapshot(_, _, _, _, _) :-
    throw(migration_fault(validation_failed, staged_store_mismatch)).

/* Snapshot validation -------------------------------------------------- */

effect_migration_validate_snapshot(Snapshot, Validation) :-
    ( is_dict(Snapshot, effect_snapshot), ground(Snapshot) -> true
    ; throw(migration_fault(corrupt, invalid_snapshot)) ),
    validate_unique_calls(Snapshot.calls),
    validate_attempts(Snapshot.calls, Snapshot.attempts),
    validate_observations(Snapshot.attempts, Snapshot.observations),
    validate_events(Snapshot.calls, Snapshot.events),
    Validation = validation{result:pass}.

validate_source_schema(empty, Snapshot) :-
    !,
    ( Snapshot.calls == [], Snapshot.attempts == [],
      Snapshot.observations == [], Snapshot.events == [],
      Snapshot.metadata == [], Snapshot.scopes == [], Snapshot.epochs == [],
      Snapshot.migrations == [], Snapshot.bindings == []
    -> true
    ; throw(migration_fault(corrupt, nonempty_store_classified_empty)) ).
validate_source_schema(v1, Snapshot) :-
    !,
    ( Snapshot.metadata == [], Snapshot.scopes == [], Snapshot.epochs == [],
      Snapshot.migrations == [], Snapshot.bindings == []
    -> true
    ; throw(migration_fault(incompatible, legacy_store_contains_v2_records)) ).

validate_unique_calls(Calls) :-
    maplist(call_key, Calls, Keys),
    require_unique(Keys, duplicate_call),
    forall(member(Call, Calls),
           ( is_dict(Call, effect_call), atom(Call.call_id),
             atom(Call.fingerprint), atom(Call.kind),
             number(Call.created_at) -> true
           ; throw(migration_fault(corrupt, invalid_call)) )).

call_key(Call, Call.call_id-Call.fingerprint).

validate_attempts(Calls, Attempts) :-
    forall(member(Attempt, Attempts), validate_attempt_shape(Attempt)),
    findall(Id, (member(Attempt, Attempts), Id = Attempt.attempt_id), Ids0),
    sort(Ids0, Ids),
    forall(member(Id, Ids), validate_attempt_chain(Id, Calls, Attempts)),
    findall(Key,
            ( member(Id, Ids), latest_attempt(Id, Attempts, A),
              Key = A.idempotency_key ),
            ProviderKeys),
    require_unique(ProviderKeys, duplicate_provider_idempotency_key).

validate_attempt_shape(Attempt) :-
    ( is_dict(Attempt, effect_attempt),
      atom(Attempt.attempt_id), integer(Attempt.revision),
      Attempt.revision >= 1, atom(Attempt.call_id),
      atom(Attempt.fingerprint), integer(Attempt.sequence),
      Attempt.sequence >= 1, memberchk(Attempt.mode, [initial,retry,resample]),
      memberchk(Attempt.status,
                [admitted,dispatching,observed,cancelled_before_claim,
                 cancelled_pre_dispatch,cancellation_requested,indeterminate,
                 retry_authorized,abandoned]),
      atom(Attempt.idempotency_key), Attempt.idempotency_key \== '',
      number(Attempt.created_at), number(Attempt.updated_at)
    -> true
    ; throw(migration_fault(corrupt, invalid_attempt)) ).

validate_attempt_chain(Id, Calls, Attempts) :-
    include(attempt_has_id(Id), Attempts, Revisions0),
    map_list_to_pairs(attempt_revision, Revisions0, RevisionPairs),
    keysort(RevisionPairs, SortedPairs),
    pairs_values(SortedPairs, Revisions),
    validate_revision_numbers(Revisions, 1),
    validate_status_transitions(Revisions),
    Revisions = [First|_],
    forall(member(Revision, Revisions), same_attempt_identity(First, Revision)),
    ( member(Call, Calls), Call.call_id == First.call_id,
      Call.fingerprint == First.fingerprint
    -> true
    ; throw(migration_fault(corrupt, missing_attempt_call(Id))) ),
    validate_lineage(First, Attempts).

attempt_has_id(Id, Attempt) :- Attempt.attempt_id == Id.
compare_attempt_revision(Order, A, B) :- compare(Order, A.revision, B.revision).
attempt_revision(Attempt, Attempt.revision).

validate_status_transitions([First|Rest]) :-
    ( memberchk(First.status, [admitted,cancelled_before_claim]) -> true
    ; throw(migration_fault(corrupt,
                            invalid_initial_status(First.attempt_id,
                                                   First.status))) ),
    validate_status_transitions_(First, Rest).

validate_status_transitions_(_, []).
validate_status_transitions_(Previous, [Next|Rest]) :-
    ( allowed_status_transition(Previous.status, Next.status) -> true
    ; throw(migration_fault(corrupt,
                            invalid_status_transition(Next.attempt_id,
                                                      Previous.status,
                                                      Next.status))) ),
    validate_status_transitions_(Next, Rest).

allowed_status_transition(admitted, dispatching).
allowed_status_transition(admitted, cancelled_pre_dispatch).
allowed_status_transition(dispatching, cancellation_requested).
allowed_status_transition(dispatching, indeterminate).
allowed_status_transition(dispatching, observed).
allowed_status_transition(cancellation_requested, indeterminate).
allowed_status_transition(cancellation_requested, observed).
allowed_status_transition(indeterminate, retry_authorized).
allowed_status_transition(indeterminate, abandoned).
allowed_status_transition(indeterminate, observed).
allowed_status_transition(retry_authorized, observed).

validate_revision_numbers([], _).
validate_revision_numbers([Attempt|Rest], Expected) :-
    ( Attempt.revision =:= Expected -> true
    ; throw(migration_fault(corrupt,
                            inconsistent_revision_chain(Attempt.attempt_id))) ),
    Next is Expected+1,
    validate_revision_numbers(Rest, Next).

same_attempt_identity(A, B) :-
    ( A.call_id == B.call_id, A.fingerprint == B.fingerprint,
      A.sequence =:= B.sequence, A.parent_attempt == B.parent_attempt,
      A.mode == B.mode, A.idempotency_key == B.idempotency_key,
      A.created_at =:= B.created_at
    -> true
    ; throw(migration_fault(corrupt,
                            conflicting_attempt_identity(A.attempt_id))) ).

validate_lineage(Attempt, _) :-
    Attempt.mode == initial,
    !,
    ( Attempt.sequence =:= 1, Attempt.parent_attempt == none -> true
    ; throw(migration_fault(corrupt,
                            invalid_initial_lineage(Attempt.attempt_id))) ).
validate_lineage(Attempt, Attempts) :-
    latest_attempt(Attempt.parent_attempt, Attempts, Parent),
    ( Parent.call_id == Attempt.call_id,
      Parent.fingerprint == Attempt.fingerprint,
      Attempt.sequence =:= Parent.sequence+1
    -> true
    ; throw(migration_fault(corrupt,
                            invalid_parent_lineage(Attempt.attempt_id))) ).

latest_attempt(Id, Attempts, Latest) :-
    include(attempt_has_id(Id), Attempts, Found),
    Found \== [],
    map_list_to_pairs(attempt_revision, Found, Pairs),
    keysort(Pairs, SortedPairs),
    pairs_values(SortedPairs, Sorted),
    last(Sorted, Latest),
    !.
latest_attempt(Id, _, _) :-
    throw(migration_fault(corrupt, missing_parent_attempt(Id))).

validate_observations(Attempts, Observations) :-
    findall(Id, member(Id-_, Observations), Ids),
    require_unique(Ids, duplicate_observation),
    forall(member(Id-Observation, Observations),
           validate_observation(Id, Observation, Attempts)),
    findall(Attempt,
            ( latest_attempt_member(Attempts, Attempt),
              Attempt.status == observed ),
            ObservedAttempts),
    forall(member(Attempt, ObservedAttempts),
           ( memberchk(Attempt.attempt_id-_, Observations) -> true
           ; throw(migration_fault(corrupt,
                                   missing_observation(Attempt.attempt_id))) )).

validate_observation(Id, Observation, Attempts) :-
    latest_attempt(Id, Attempts, Attempt),
    ( is_dict(Observation), ground(Observation),
      memberchk(Attempt.status,
                [dispatching,cancellation_requested,indeterminate,
                 retry_authorized,observed]),
      get_dict(status, Observation, Status),
      memberchk(Status, [succeeded,failed,cancelled]),
      get_dict(value, Observation, _), get_dict(usage, Observation, _),
      get_dict(provenance, Observation, _)
    -> true
    ; throw(migration_fault(corrupt, invalid_observation(Id))) ).

latest_attempt_member(Attempts, Latest) :-
    member(Candidate, Attempts),
    latest_attempt(Candidate.attempt_id, Attempts, Latest),
    Candidate == Latest.

validate_events(Calls, Events) :-
    findall(CallId-Sequence, member(CallId-Sequence-_, Events), Keys),
    require_unique(Keys, duplicate_event_sequence),
    findall(EventId,
            ( member(_-_-Event0, Events), EventId = Event0.event_id ),
            EventIds),
    require_unique(EventIds, duplicate_event_id),
    forall(member(CallId-_-Event, Events),
           ( member(Call, Calls), Call.call_id == CallId,
             is_dict(Event), ground(Event), get_dict(event_id, Event, _)
           -> true
           ; throw(migration_fault(corrupt, invalid_event(CallId))) )).

require_unique(Values, _) :-
    sort(Values, Unique),
    length(Values, N), length(Unique, N),
    !.
require_unique(_, Kind) :- throw(migration_fault(corrupt, Kind)).

/* Manifest ------------------------------------------------------------- */

effect_migration_read_manifest(none, _, _, []) :- !.
effect_migration_read_manifest(Path, SourceDigest, Snapshot, Bindings) :-
    catch(setup_call_cleanup(open(Path, read, Stream, [encoding(utf8)]),
                             json_read_dict(Stream, Manifest,
                                            [value_string_as(atom)]),
                             close(Stream)),
          Exception,
          throw(migration_fault(ambiguous_adapter,
                                manifest_read_error(Exception)))),
    validate_manifest(Manifest, SourceDigest, Snapshot, Bindings).

validate_manifest(Manifest, SourceDigest, Snapshot, Bindings) :-
    ( is_dict(Manifest), ground(Manifest) -> true
    ; throw(migration_fault(ambiguous_adapter, invalid_manifest)) ),
    dict_keys(Manifest, Keys),
    sort(Keys, Sorted),
    ( Sorted == [bindings,schema,source_digest] -> true
    ; throw(migration_fault(ambiguous_adapter, unknown_manifest_keys(Keys))) ),
    ( Manifest.schema == 'prolog-rlm.effect-migration-manifest.v1' -> true
    ; throw(migration_fault(ambiguous_adapter, invalid_manifest_schema)) ),
    ( Manifest.source_digest == SourceDigest -> true
    ; throw(migration_fault(ambiguous_adapter, source_digest_mismatch)) ),
    ( is_list(Manifest.bindings) -> true
    ; throw(migration_fault(ambiguous_adapter, invalid_bindings)) ),
    maplist(validate_binding(Snapshot), Manifest.bindings, Bindings),
    findall(Id, member(binding(Id,_), Bindings), Ids),
    ( sort(Ids, Unique), length(Ids, N), length(Unique, N) -> true
    ; throw(migration_fault(ambiguous_adapter, conflicting_bindings)) ).

validate_binding(Snapshot, Dict, binding(AttemptId, Adapter)) :-
    ( is_dict(Dict), ground(Dict),
      dict_keys(Dict, Keys), sort(Keys, [adapter,attempt_id]),
      atom(Dict.attempt_id), atom(Dict.adapter),
      valid_adapter_atom(Dict.adapter)
    -> AttemptId = Dict.attempt_id, Adapter = Dict.adapter
    ; throw(migration_fault(ambiguous_adapter, invalid_binding)) ),
    ( latest_attempt(AttemptId, Snapshot.attempts, _) -> true
    ; throw(migration_fault(ambiguous_adapter,
                            nonexistent_attempt_binding(AttemptId))) ).

valid_adapter_atom(Adapter) :-
    atom_codes(Adapter, [First|Rest]),
    code_type(First, lower),
    forall(member(Code, Rest), adapter_code(Code)).

adapter_code(Code) :- code_type(Code, alnum), !.
adapter_code(0'_).

/* Reports and identity ------------------------------------------------- */

unresolved_attempts(Snapshot, Unresolved) :-
    findall(Id,
            ( latest_attempt_member(Snapshot.attempts, Attempt),
              memberchk(Attempt.status,
                        [dispatching,cancellation_requested,indeterminate,
                         retry_authorized]),
              Id = Attempt.attempt_id,
              \+ memberchk(Id-_, Snapshot.observations) ),
            Unresolved0),
    sort(Unresolved0, Unresolved).

attempts_without_bindings(Unresolved, Bindings, _, Missing) :-
    findall(Id,
            ( member(Id, Unresolved),
              \+ memberchk(binding(Id,_), Bindings) ),
            Missing).

warnings([], []).
warnings(Missing, [unresolved_attempts_require_adapter_bindings(Missing)]) :-
    Missing \== [].

counts(Snapshot, Counts) :-
    length(Snapshot.calls, Calls),
    findall(Id,
            ( member(Attempt0, Snapshot.attempts), Id = Attempt0.attempt_id ),
            Ids0),
    sort(Ids0, AttemptIds), length(AttemptIds, Attempts),
    length(Snapshot.observations, Observations),
    length(Snapshot.events, Events),
    findall(Key,
            ( member(AttemptId, AttemptIds),
              latest_attempt(AttemptId, Snapshot.attempts, Attempt),
              Key = Attempt.idempotency_key ),
            Keys0),
    sort(Keys0, Keys), length(Keys, ProviderKeys),
    Counts = counts{calls:Calls,attempts:Attempts,
                    observations:Observations,events:Events,
                    provider_keys:ProviderKeys}.

report_success(Base, Schema, SourceDigest, MigrationId, StoreId,
               Counts, Unresolved, MissingBindings, Options,
               Validation, Warnings, Report) :-
    schema_number(Schema, SourceSchema),
    length(Unresolved, UnresolvedCount),
    ( Options.in_place == true -> Backup = Options.backup ; Backup = none ),
    Report = Base.put(_{status:migrated,
                        source_schema:SourceSchema,
                        migration_id:MigrationId,
                        store_namespace:StoreId,
                        source_verification_digest:SourceDigest,
                        migrated_call_count:Counts.calls,
                        migrated_attempt_count:Counts.attempts,
                        observation_count:Counts.observations,
                        event_count:Counts.events,
                        unresolved_attempt_count:UnresolvedCount,
                        attempts_requiring_adapter_bindings:MissingBindings,
                        preserved_provider_key_count:Counts.provider_keys,
                        backup_path:Backup,
                        validation_result:Validation.result,
                        warnings:Warnings}).

schema_number(v1, 1).
schema_number(empty, 1).

deterministic_migration_identity(SourceDigest, Destination,
                                 MigrationId, StoreId) :-
    term_string(migration(SourceDigest,Destination), MigrationMaterial,
                [quoted(true),ignore_ops(true)]),
    term_string(namespace(SourceDigest,Destination), NamespaceMaterial,
                [quoted(true),ignore_ops(true)]),
    crypto_data_hash(MigrationMaterial, MigrationHex,
                     [algorithm(sha256),encoding(utf8)]),
    crypto_data_hash(NamespaceMaterial, NamespaceHex,
                     [algorithm(sha256),encoding(utf8)]),
    atom_concat('effect-migration:', MigrationHex, MigrationId),
    atom_concat('effect-store:', NamespaceHex, StoreId).

source_file_digest(Path, Digest) :-
    crypto_file_hash(Path, Hex, [algorithm(sha256)]),
    atom_concat('sha256:', Hex, Digest).

metadata_value(Metadata, Key, Value) :- memberchk(Key-Value, Metadata).

/* Filesystem and interruption boundaries ------------------------------ */

canonical_existing_path(Path, Canonical) :-
    catch(absolute_file_name(Path, Canonical,
                             [access(read),file_type(regular),solutions(first)]),
          _, fail),
    !.
canonical_existing_path(Path, _) :-
    throw(migration_fault(incompatible, source_not_readable(Path))).

canonical_destination_path(Path, Canonical) :-
    file_directory_name(Path, Dir0),
    file_base_name(Path, Base),
    catch(absolute_file_name(Dir0, Dir,
                             [access(write),file_type(directory),
                              solutions(first)]),
          _, fail),
    !,
    directory_file_path(Dir, Base, Canonical).
canonical_destination_path(Path, _) :-
    throw(migration_fault(incompatible,
                          destination_directory_not_writable(Path))).

path_alias(A, B) :- A == B, !.
path_alias(A, B) :- exists_file(A), exists_file(B), catch(same_file(A,B),_,fail), !.
path_alias(A, B) :-
    catch((absolute_file_name(A, CA, [access(none)]),
           absolute_file_name(B, CB, [access(none)]), CA == CB), _, fail).

temporary_destination(Destination, Temp) :-
    atom_concat(Destination, '.migrating', Temp).

cleanup_stale_temp(Temp) :-
    ( exists_file(Temp) -> delete_file(Temp) ; true ).
cleanup_failed_temp(Temp) :-
    catch(( exists_file(Temp) -> delete_file(Temp) ; true ), _, true).

durable_file(Path) :- run_sync(Path).
durable_parent(Path) :- file_directory_name(Path, Directory), run_sync(Directory).

run_sync(Path) :-
    catch(( process_create(path(sync), ['-f',Path], [process(Pid)]),
            process_wait(Pid, exit(0)) ),
          Exception,
          throw(migration_fault(interrupted, sync_failed(Exception)))).

migration_phase(Phase) :-
    ( getenv('RLM_EFFECT_MIGRATION_MARKER_DIR', Directory)
    -> directory_file_path(Directory, Phase, Marker),
       setup_call_cleanup(open(Marker, write, Stream, [encoding(utf8)]),
                          format(Stream, '~w~n', [Phase]), close(Stream))
    ;  true ),
    ( getenv('RLM_EFFECT_MIGRATION_PAUSE_AT', Paused),
      Paused == Phase
    -> format('migration_phase_ready ~w~n', [Phase]),
       flush_output,
       read_line_to_string(user_input, _)
    ;  true ),
    ( getenv('RLM_EFFECT_MIGRATION_CRASH_AT', Requested),
      Requested == Phase
    -> halt(97)
    ;  true ).

migration_exception_report(migration_fault(Status, Detail), Base, Report) :-
    !,
    Report = Base.put(_{status:Status,
                        validation_result:fail,
                        warnings:[Detail]}).
migration_exception_report(error(permission_error(lock, effect_store, Detail), _),
                           Base, Report) :-
    !,
    Report = Base.put(_{status:lock_conflict,
                        validation_result:not_run,
                        warnings:[Detail]}).
migration_exception_report(Exception, Base, Report) :-
    safe_exception(Exception, Safe),
    Report = Base.put(_{status:corrupt,
                        validation_result:fail,
                        warnings:[Safe]}).

safe_exception(Exception, Safe) :-
    catch(term_string(Exception, Safe,
                      [quoted(true),numbervars(true),max_depth(8)]),
          _, Safe = "unavailable").
