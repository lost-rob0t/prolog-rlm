:- begin_tests(rlm_effect_migration).

:- use_module('../prolog/rlm_effect').
:- use_module('../prolog/rlm_effect_executor').
:- use_module('../prolog/rlm_effect_migration').
:- use_module('../prolog/rlm_cli').
:- use_module(effect_legacy_fixture).
:- use_module(library(crypto)).
:- use_module(library(http/json)).

setup_paths(Source, Destination) :-
    tmp_file(legacy_effect, Source),
    atom_concat(Source, '.v2', Destination).

cleanup_paths(Paths) :-
    catch(rlm_effect_store_close, _, true),
    forall(member(Path, Paths),
           ( catch(delete_file(Path), _, true),
             atom_concat(Path, '.lock', Lock),
             catch(delete_file(Lock), _, true),
             atom_concat(Path, '.migrating', Temp),
             catch(delete_file(Temp), _, true),
             atom_concat(Temp, '.lock', TempLock),
             catch(delete_file(TempLock), _, true) )).

migrate_fixture(Source, Destination, Details, Report) :-
    legacy_fixture_create(Source, Details),
    effect_store_migrate(_{source:Source,output:Destination}, Report).

test(real_pr78_schema_preserves_observation_and_provider_keys) :-
    setup_paths(Source, Destination),
    setup_call_cleanup(
        true,
        ( migrate_fixture(Source, Destination, Details, Report),
          assertion(Report.status == migrated),
          assertion(Report.migrated_attempt_count == 2),
          assertion(Report.preserved_provider_key_count == 2),
          rlm_effect_store_open(Destination),
          rlm_effect_observation(Details.observed_attempt, Observation),
          assertion(Observation == Details.observation),
          rlm_effect_status(Details.uncertain_attempt, Uncertain),
          assertion(Uncertain.status == dispatching),
          assertion(Uncertain.idempotency_key ==
                    Details.uncertain_provider_key),
          rlm_effect_store_close ),
        cleanup_paths([Source,Destination])).

test(ordinary_open_of_legacy_store_remains_fail_closed) :-
    setup_paths(Source, Destination),
    setup_call_cleanup(
        legacy_fixture_create(Source, _),
        catch(rlm_effect_store_open(Source), Error, true),
        cleanup_paths([Source,Destination])),
    assertion(nonvar(Error)),
    assertion(Error = error(permission_error(open,
                                              legacy_effect_store_requires_migration,
                                              _), _)).

test(migration_is_idempotently_reported) :-
    setup_paths(Source, Destination),
    setup_call_cleanup(
        true,
        ( migrate_fixture(Source, Destination, _, First),
          assertion(First.status == migrated),
          effect_store_migrate(_{source:Destination,output:Source}, Second),
          assertion(Second.status == already_migrated),
          assertion(Second.migration_id == First.migration_id) ),
        cleanup_paths([Source,Destination])).

test(cli_routes_documented_migration_command_and_emits_report_payload) :-
    setup_paths(Source, Destination),
    setup_call_cleanup(
        legacy_fixture_create(Source, _),
        ( cli_run(['effect-store',migrate,'--source',Source,
                   '--output',Destination,'--json'], ok(Session)),
          assertion(Session.command == effect_store_migrate),
          assertion(Session.status == pass),
          assertion(Session.output.json == true),
          assertion(Session.payload.status == migrated),
          assertion(Session.payload.report_schema ==
                    'prolog-rlm.effect-migration-report.v1') ),
        cleanup_paths([Source,Destination])).

test(unresolved_without_binding_never_calls_adapter) :-
    setup_paths(Source, Destination),
    setup_call_cleanup(
        true,
        ( migrate_fixture(Source, Destination, Details, Report),
          assertion(Report.attempts_requiring_adapter_bindings ==
                    [Details.uncertain_attempt]),
          rlm_effect_store_open(Destination),
          effect_reconcile(wrong_adapter, Details.uncertain_attempt, Outcome),
          assertion(Outcome = error(effect_error{
              kind:adapter_identity_mismatch,
              expected:unknown,
              actual:wrong_adapter})),
          rlm_effect_store_close ),
        cleanup_paths([Source,Destination])).

test(post_migration_execution_uses_distinct_v2_identity) :-
    setup_paths(Source, Destination),
    setup_call_cleanup(
        true,
        ( migrate_fixture(Source, Destination, Details, Report),
          assertion(Report.status == migrated),
          rlm_effect_store_open(Destination),
          rlm_effect_prepare(model, request{prompt:observed}, _{},
                             execute(Ticket)),
          assertion(Ticket.call_id \== Details.observed_call),
          assertion(Ticket.attempt_id \== Details.observed_attempt),
          assertion(Ticket.idempotency_key \==
                    Details.observed_provider_key),
          rlm_effect_store_close ),
        cleanup_paths([Source,Destination])).

test(strict_manifest_binds_original_attempt) :-
    setup_paths(Source, Destination),
    atom_concat(Source, '.manifest.json', ManifestPath),
    setup_call_cleanup(
        legacy_fixture_create(Source, Details),
        ( crypto_file_hash(Source, Hex, [algorithm(sha256)]),
          atom_concat('sha256:', Hex, Digest),
          Manifest = _{schema:'prolog-rlm.effect-migration-manifest.v1',
                       source_digest:Digest,
                       bindings:[_{attempt_id:Details.uncertain_attempt,
                                   adapter:trusted_legacy_adapter}]},
          setup_call_cleanup(open(ManifestPath, write, Stream,
                                  [encoding(utf8)]),
                             json_write_dict(Stream, Manifest),
                             close(Stream)),
          effect_store_migrate(_{source:Source,output:Destination,
                                 manifest:ManifestPath}, Report),
          assertion(Report.status == migrated),
          assertion(Report.attempts_requiring_adapter_bindings == []),
          rlm_effect_store_open(Destination),
          rlm_effect_persist:effect_persist_legacy_adapter(
              Details.uncertain_attempt, trusted_legacy_adapter),
          rlm_effect_store_close ),
        cleanup_paths([Source,Destination,ManifestPath])).

test(manifest_wrong_digest_aborts_and_preserves_source) :-
    setup_paths(Source, Destination),
    atom_concat(Source, '.manifest.json', ManifestPath),
    setup_call_cleanup(
        legacy_fixture_create(Source, Details),
        ( Manifest = _{schema:'prolog-rlm.effect-migration-manifest.v1',
                       source_digest:'sha256:not-this-ledger',
                       bindings:[_{attempt_id:Details.uncertain_attempt,
                                   adapter:trusted_adapter}]},
          setup_call_cleanup(open(ManifestPath, write, Stream,
                                  [encoding(utf8)]),
                             json_write_dict(Stream, Manifest),
                             close(Stream)),
          effect_store_migrate(_{source:Source,output:Destination,
                                 manifest:ManifestPath}, Report),
          assertion(Report.status == ambiguous_adapter),
          assertion(\+ exists_file(Destination)),
          assertion(exists_file(Source)) ),
        cleanup_paths([Source,Destination,ManifestPath])).

test(in_place_requires_and_preserves_byte_exact_backup) :-
    setup_paths(Source, Destination),
    atom_concat(Source, '.backup', Backup),
    setup_call_cleanup(
        legacy_fixture_create(Source, _),
        ( crypto_file_hash(Source, Before, [algorithm(sha256)]),
          effect_store_migrate(_{source:Source,in_place:true,backup:Backup},
                               Report),
          assertion(Report.status == migrated),
          crypto_file_hash(Backup, BackupHash, [algorithm(sha256)]),
          assertion(BackupHash == Before),
          rlm_effect_store_open(Source),
          rlm_effect_store_close ),
        cleanup_paths([Source,Destination,Backup])).

test(copied_migrated_store_is_not_an_independent_writable_clone) :-
    setup_paths(Source, Destination),
    atom_concat(Destination, '.copy', Copy),
    setup_call_cleanup(
        true,
        ( migrate_fixture(Source, Destination, _, Report),
          assertion(Report.status == migrated),
          setup_call_cleanup(open(Destination, read, In, [type(binary)]),
              setup_call_cleanup(open(Copy, write, Out, [type(binary)]),
                                 copy_stream_data(In, Out), close(Out)),
              close(In)),
          catch(rlm_effect_store_open(Copy), Error, true),
          assertion(nonvar(Error)),
          assertion(Error = error(permission_error(open,
                                                    migrated_effect_store_copy,
                                                    _), _)) ),
        cleanup_paths([Source,Destination,Copy])).

:- end_tests(rlm_effect_migration).
