:- begin_tests(rlm_tool_effect).

:- meta_predicate with_effect_store(0).

:- use_module(library(process)).
:- use_module(library(readutil)).
:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_effect').
:- use_module('../prolog/rlm_effect_executor').
:- use_module('../prolog/rlm_authority').
:- use_module('../prolog/rlm_async').
:- use_module(effect_legacy_fixture).
:- use_module('support/tool_effect_test_support').

:- multifile rlm_effect_executor:effect_adapter_reconcile/4.
:- multifile rlm_effect_executor:effect_adapter_cancel/4.

setup_effect_store(File) :-
    tmp_file(rlm_tool_effect, File),
    rlm_effect_store_open(File),
    tool_effect_test_support:reset_tool_mutations.

cleanup_effect_store(File) :-
    catch(rlm_effect_store_close, _, true),
    catch(delete_file(File), _, true),
    tool_effect_test_support:reset_tool_mutations.

with_effect_store(Goal) :-
    setup_call_cleanup(setup_effect_store(File), Goal,
                       cleanup_effect_store(File)).

setup_write_registry(Registry) :-
    tool_registry_create(Registry),
    write_schema(Schema),
    tool_register(Registry, Schema,
                  tool_effect_test_support:counting_write_tool, ok(_)).

setup_gated_write_registry(Registry) :-
    tool_registry_create(Registry),
    write_schema(Schema),
    tool_register(Registry, Schema,
                  tool_effect_test_support:gated_counting_write_tool, ok(_)).

setup_gated_alternate_write_registry(Registry) :-
    tool_registry_create(Registry),
    write_schema(Schema),
    tool_register(Registry, Schema,
                  tool_effect_test_support:gated_alternate_write_tool, ok(_)).

setup_read_registry(Registry) :-
    tool_registry_create(Registry),
    fresh_read_schema(Schema),
    tool_register(Registry, Schema,
                  tool_effect_test_support:fresh_read_tool, ok(_)).

setup_blocking_registry(Registry) :-
    tool_registry_create(Registry),
    blocking_write_schema(Schema),
    tool_register(Registry, Schema,
                  tool_effect_test_support:blocking_write_tool, ok(_)).

invoke_write(Registry, Context, Value, Outcome, Trace) :-
    tool_invoke(Registry, [tool(counting_write)], counting_write,
                json{value:Value}, [authority_context(Context)],
                Outcome, Trace).

invoke_write_async(Registry, Context, Value, Future) :-
    tool_invoke_async(Registry, [tool(counting_write)],
                      counting_write, json{value:Value},
                      [authority_context(Context)], Future).

invoke_read(Registry, Value, Outcome, Trace) :-
    tool_invoke(Registry, [tool(fresh_read)], fresh_read,
                json{value:Value}, [], Outcome, Trace).

dangerous_context(Context) :-
    Context = session(tool_effect_dangerous),
    rlm_set_authority(Context, dangerous, ok(_)).

allow_once_context(Context) :-
    Context = session(tool_effect_allow_once),
    rlm_set_authority(Context, allow_once, ok(_)).

cleanup_context(Context) :-
    catch(rlm_authority_clear(Context), _, true).

expect_stage(_Stage, Expected, Actual) :-
    Actual = Expected,
    !.
expect_stage(Stage, Expected, Actual) :-
    throw(error(tool_effect_stage_failed(Stage,
                                         expected(Expected),
                                         actual(Actual)),
                context(rlm_tool_effect, Stage))).

/* 1. Effectful tool + later Prolog failure/backtracking mutates exactly once. */
test(effectful_tool_backtracking_mutates_once,
     [setup(reset_tool_mutations)]) :-
    setup_call_cleanup(
        setup_effect_store(Store),
        ( dangerous_context(Context),
          setup_write_registry(Registry),
          (   invoke_write(Registry, Context, 7, ok(_), _),
              fail
          ;   true ),
          tool_effect_test_support:tool_mutation_count(Count),
          assertion(Count =:= 1),
          invoke_write(Registry, Context, 7, ok(Replay), _),
          assertion(Replay.value.seen =:= 7),
          tool_effect_test_support:tool_mutation_count(StillOne),
          assertion(StillOne =:= 1),
          cleanup_context(Context),
          tool_registry_destroy(Registry) ),
        cleanup_effect_store(Store)).

/* 2. Sync, async, and repeated-await paths share one admitted attempt. */
test(sync_async_repeated_wait_share_one_attempt,
     [setup(reset_tool_mutations)]) :-
    setup_call_cleanup(
        setup_effect_store(Store),
        ( dangerous_context(Context),
          setup_write_registry(Registry),
          invoke_write_async(Registry, Context, 11, Future),
          rlm_future_status(Future, _),
          rlm_future_await(Future, AsyncResult),
          rlm_future_await(Future, Again),
          assertion(AsyncResult == Again),
          invoke_write(Registry, Context, 11, ok(SyncReplay), _),
          assertion(SyncReplay.value.seen =:= 11),
          tool_effect_test_support:tool_mutation_count(Count),
          assertion(Count =:= 1),
          rlm_future_destroy(Future),
          cleanup_context(Context),
          tool_registry_destroy(Registry) ),
        cleanup_effect_store(Store)).

/* 3. Edited pending approval cannot execute the stale ticket. */
test(edited_pending_cannot_execute_stale_ticket,
     [setup(reset_tool_mutations)]) :-
    setup_call_cleanup(
        setup_effect_store(Store),
        ( Context = session(tool_effect_edit),
          setup_write_registry(Registry),
          invoke_write(Registry, Context, 41, approval_required(Old), _),
          get_dict(id, Old, OldId),
          get_dict(fingerprint, Old, OldFingerprint),
          rlm_edit(OldId, _{args:_{value:42}}, ok(Edit)),
          get_dict(id, Edit, EditId),
          get_dict(fingerprint, Edit, EditFingerprint),
          assertion(EditFingerprint \== OldFingerprint),
          rlm_pending_resolution_async(EditId, ResolutionFuture),
          rlm_approve(EditId, ok(_)),
          rlm_future_await(ResolutionFuture, 2.0, Resolution),
          get_dict(outcome, Resolution, ok(Value)),
          get_dict(seen, Value, Seen),
          assertion(Seen =:= 42),
          tool_effect_test_support:tool_mutation_count(Count),
          assertion(Count =:= 1),
          tool_effect_test_support:tool_last_value(LastValue),
          assertion(LastValue =:= 42),
          rlm_approve(OldId, error(Stale)),
          get_dict(kind, Stale, StaleKind),
          assertion(StaleKind == approval_not_pending),
          tool_effect_test_support:tool_mutation_count(StillOne),
          assertion(StillOne =:= 1),
          rlm_future_destroy(ResolutionFuture),
          cleanup_context(Context),
          tool_registry_destroy(Registry) ),
        cleanup_effect_store(Store)).

/* 4. Changed payload cannot reuse allow_once. */
test(changed_payload_cannot_reuse_allow_once,
     [setup(reset_tool_mutations)]) :-
    setup_call_cleanup(
        setup_effect_store(Store),
        ( allow_once_context(Context),
          setup_write_registry(Registry),
          invoke_write(Registry, Context, 51, ok(_), FirstTrace),
          assertion(FirstTrace.authority == allow_once),
          tool_effect_test_support:tool_mutation_count(One),
          assertion(One =:= 1),
          invoke_write(Registry, Context, 52, approval_required(_), SecondTrace),
          assertion(SecondTrace.status == approval_required),
          tool_effect_test_support:tool_mutation_count(StillOne),
          assertion(StillOne =:= 1),
          rlm_authority(Context, Mode),
          assertion(Mode == approve_diff),
          cleanup_context(Context),
          tool_registry_destroy(Registry) ),
        cleanup_effect_store(Store)).

/* 5. Read-only tools retain fresh-read behavior (no memoization). */
test(read_only_tool_is_not_memoized,
     [setup(reset_tool_mutations)]) :-
    setup_call_cleanup(
        setup_effect_store(Store),
        ( setup_read_registry(Registry),
          invoke_read(Registry, 1, ok(First), _),
          invoke_read(Registry, 1, ok(Second), _),
          tool_effect_test_support:tool_mutation_count(Count),
          assertion(Count =:= 2),
          assertion(First.value.seen =:= 1),
          assertion(Second.value.count =:= 2),
          tool_registry_destroy(Registry) ),
        cleanup_effect_store(Store)).

/* 6. Store close/switch while a tool effect is in flight fails closed. */
test(store_close_during_inflight_tool_effect_fails_closed,
     [setup(reset_tool_mutations)]) :-
    setup_call_cleanup(
        setup_effect_store(Store),
        ( dangerous_context(Context),
          setup_blocking_registry(Registry),
          tool_effect_test_support:arm_blocking_gate,
          tool_invoke_async(Registry, [tool(blocking_write)],
                            blocking_write, json{value:61},
                            [authority_context(Context)], Future),
          tool_effect_test_support:await_blocking_write_entered,
          catch(rlm_effect_store_close, _, CloseThrew = true),
          assertion(CloseThrew == true),
          tool_effect_test_support:release_blocking_write,
          rlm_future_await(Future, _),
          rlm_future_destroy(Future),
          tool_effect_test_support:tool_mutation_count(Count),
          assertion(Count =:= 1),
          cleanup_context(Context),
          tool_registry_destroy(Registry) ),
        cleanup_effect_store(Store)).

/* 7. Legacy/migrated store restrictions cannot be bypassed by the tool path. */
test(legacy_store_fence_blocks_effectful_tool,
     [setup(reset_tool_mutations)]) :-
    tmp_file(rlm_tool_effect_legacy, Ledger),
    effect_legacy_fixture:legacy_fixture_create(Ledger, _),
    setup_call_cleanup(
        true,
        ( ( catch(rlm_effect_store_open(Ledger), _, fail)
          -> Opened = true
          ;  Opened = false ),
          assertion(Opened == false),
          dangerous_context(Context),
          setup_write_registry(Registry),
          invoke_write(Registry, Context, 77, error(_), _),
          tool_effect_test_support:tool_mutation_count(Count),
          assertion(Count =:= 0),
          cleanup_context(Context),
          tool_registry_destroy(Registry) ),
        ( catch(rlm_effect_store_close, _, true),
          catch(delete_file(Ledger), _, true) )).

/* 8. #54 execute -> Future -> sync-await direction remains intact. */
test(canonical_execute_future_sync_direction,
     [setup(reset_tool_mutations)]) :-
    setup_call_cleanup(
        setup_effect_store(Store),
        ( dangerous_context(Context),
          setup_write_registry(Registry),
          invoke_write_async(Registry, Context, 91, Future),
          rlm_future_await(Future, AsyncResult),
          AsyncResult.outcome = ok(AsyncExec),
          assertion(AsyncExec.value.seen =:= 91),
          invoke_write(Registry, Context, 91, ok(SyncReplay), _),
          assertion(SyncReplay.value.seen =:= 91),
          tool_effect_test_support:tool_mutation_count(Count),
          assertion(Count =:= 1),
          rlm_future_destroy(Future),
          cleanup_context(Context),
          tool_registry_destroy(Registry) ),
        cleanup_effect_store(Store)).

/* 9. Fresh-process recovery after a tool effect crashed post-acceptance. */
test(tool_effect_crash_after_acceptance_recovers_without_resubmission) :-
    tmp_file(rlm_tool_effect_crash, Base),
    atomic_list_concat([Base, '-ledger.db'], Ledger),
    atomic_list_concat([Base, '-mutation.term'], MutationFile),
    setup_call_cleanup(
        true,
        ( run_tool_crash_phase_one(Ledger, MutationFile),
          run_tool_crash_phase_two(Ledger, MutationFile) ),
        cleanup_crash_files([Ledger, MutationFile])).

/* 10. Authority over Ticket A cannot silently execute a new epoch Ticket B. */
test(stale_approved_ticket_cannot_execute_new_epoch,
     [setup(reset_tool_mutations)]) :-
    setup_call_cleanup(
        setup_effect_store(Store),
        ( ContextA = session(tool_effect_stale_ticket_a),
          ContextB = session(tool_effect_stale_ticket_b),
          setup_write_registry(Registry),
          invoke_write(Registry, ContextA, 101,
                       approval_required(Pending), _),
          EffectIdentity = Pending.operation.effect_identity,
          rlm_set_authority(ContextB, dangerous, ok(_)),
          invoke_write(Registry, ContextB, 101, ok(_), _),
          tool_effect_test_support:tool_mutation_count(One),
          assertion(One =:= 1),
          rlm_effect_prune(EffectIdentity.call_id, pruned),
          rlm_pending_resolution_async(Pending.id, ResolutionFuture),
          rlm_approve(Pending.id, ok(_)),
          rlm_future_await(ResolutionFuture, 2.0, Resolution),
          assertion(Resolution.outcome = error(_)),
          tool_effect_test_support:tool_mutation_count(StillOne),
          assertion(StillOne =:= 1),
          rlm_future_destroy(ResolutionFuture),
          cleanup_context(ContextA),
          cleanup_context(ContextB),
          tool_registry_destroy(Registry) ),
        cleanup_effect_store(Store)).

/* 11. Durable trusted binding identity is independent of registry allocation. */
test(trusted_binding_identity_prevents_cross_binding_replay,
     [setup(reset_tool_mutations)]) :-
    setup_call_cleanup(
        setup_effect_store(Store),
        ( ContextA = session(tool_effect_binding_a),
          ContextA2 = session(tool_effect_binding_a2),
          ContextB = session(tool_effect_binding_b),
          tool_effect_test_support:arm_binding_gate,
          setup_gated_write_registry(RegistryA),
          setup_gated_write_registry(RegistryA2),
          setup_gated_alternate_write_registry(RegistryB),
          RegistryA = tool_registry(RegistryAId),
          RegistryA2 = tool_registry(RegistryA2Id),
          assertion(RegistryAId \== RegistryA2Id),
          invoke_write(RegistryA, ContextA, 88, PrepareA, _),
          expect_stage(prepare_binding_a,
                       approval_required(PendingA), PrepareA),
          invoke_write(RegistryA2, ContextA2, 88, PrepareA2, _),
          expect_stage(prepare_binding_a2,
                       approval_required(PendingA2), PrepareA2),
          invoke_write(RegistryB, ContextB, 88, PrepareB, _),
          expect_stage(prepare_binding_b,
                       approval_required(PendingB), PrepareB),
          IdentityA = PendingA.operation.effect_identity,
          IdentityA2 = PendingA2.operation.effect_identity,
          IdentityB = PendingB.operation.effect_identity,
          assertion(IdentityA.fingerprint == IdentityA2.fingerprint),
          assertion(IdentityA.call_id == IdentityA2.call_id),
          assertion(IdentityA.attempt_id == IdentityA2.attempt_id),
          assertion(IdentityA.fingerprint \== IdentityB.fingerprint),
          assertion(IdentityA.call_id \== IdentityB.call_id),
          rlm_pending_resolution_async(PendingA.id, FutureA),
          rlm_pending_resolution_async(PendingB.id, FutureB),
          rlm_approve(PendingA.id, ApprovalA),
          expect_stage(approve_binding_a, ok(_), ApprovalA),
          rlm_approve(PendingB.id, ApprovalB),
          expect_stage(approve_binding_b, ok(_), ApprovalB),
          tool_effect_test_support:await_binding_gate_entries,
          tool_effect_test_support:release_binding_gate,
          rlm_future_await(FutureA, ResolutionA),
          rlm_future_await(FutureB, ResolutionB),
          expect_stage(resolve_binding_a,
                       tool_pending_resolution{outcome:ok(ValueA),
                                               status:ok,
                                               output_bytes:_,
                                               elapsed_ms:_},
                       ResolutionA),
          expect_stage(resolve_binding_b,
                       tool_pending_resolution{outcome:ok(ValueB),
                                               status:ok,
                                               output_bytes:_,
                                               elapsed_ms:_},
                       ResolutionB),
          assertion(ValueA.seen =:= 88),
          assertion(ValueB.seen =:= 1088),
          tool_effect_test_support:tool_mutation_count(Count),
          assertion(Count =:= 2),
          rlm_deny(PendingA2.id, test_cleanup, DenialA2),
          expect_stage(deny_unexecuted_binding_a2, ok(_), DenialA2),
          rlm_future_destroy(FutureA),
          rlm_future_destroy(FutureB),
          cleanup_context(ContextA),
          cleanup_context(ContextA2),
          cleanup_context(ContextB),
          tool_registry_destroy(RegistryA),
          tool_registry_destroy(RegistryA2),
          tool_registry_destroy(RegistryB) ),
        cleanup_effect_store(Store)).

/* 12. Missing store retains the dedicated public tool classification. */
test(missing_effect_store_is_classified_correctly,
     [setup(reset_tool_mutations)]) :-
    catch(rlm_effect_store_close, _, true),
    Context = session(tool_effect_missing_store),
    setup_write_registry(Registry),
    rlm_set_authority(Context, dangerous, ok(_)),
    invoke_write(Registry, Context, 121, error(Error), _),
    assertion(Error.kind == effect_store_required),
    assertion(Error.cause.kind == store_not_open),
    tool_effect_test_support:tool_mutation_count(Count),
    assertion(Count =:= 0),
    cleanup_context(Context),
    tool_registry_destroy(Registry).

/* 13. Non-store preparation failures preserve their structured #57 cause. */
test(non_store_prepare_error_is_not_mislabeled_store_required) :-
    rlm_tool:effect_prepare_tool_error(
        effect_error{kind:store_lifecycle_conflict},
        LifecycleError,
        LifecycleStatus),
    assertion(LifecycleError.kind == store_lifecycle_conflict),
    assertion(LifecycleStatus == store_lifecycle_conflict),
    rlm_tool:effect_prepare_tool_error(
        effect_error{kind:legacy_store_requires_migration},
        MigrationError,
        MigrationStatus),
    assertion(MigrationError.kind == legacy_store_requires_migration),
    assertion(MigrationStatus == legacy_store_requires_migration),
    rlm_tool:effect_prepare_tool_error(
        effect_error{kind:invalid_effect_state},
        StateError,
        StateStatus),
    assertion(StateError.kind == invalid_effect_state),
    assertion(StateStatus == invalid_effect_state).

/* 14. Replay traces keep the established scalar fingerprint contract. */
test(effect_replay_trace_fingerprint_shape,
     [setup(reset_tool_mutations)]) :-
    setup_call_cleanup(
        setup_effect_store(Store),
        ( dangerous_context(Context),
          setup_write_registry(Registry),
          invoke_write(Registry, Context, 141, ok(_), FirstTrace),
          assertion(atom(FirstTrace.fingerprint)),
          invoke_write(Registry, Context, 141, ok(_), ReplayTrace),
          assertion(ReplayTrace.status == replayed),
          assertion(ReplayTrace.fingerprint == none),
          assertion(atom(ReplayTrace.fingerprint)),
          assertion(\+ is_dict(ReplayTrace.fingerprint)),
          tool_effect_test_support:tool_mutation_count(Count),
          assertion(Count =:= 1),
          cleanup_context(Context),
          tool_registry_destroy(Registry) ),
        cleanup_effect_store(Store)).

run_tool_crash_phase_one(Ledger, MutationFile) :-
    absolute_file_name('test/tool_effect_crash_phase1.pl', Script,
                       [access(read)]),
    append(['-q', '-s', Script, '--'], [Ledger, MutationFile], Args),
    setup_call_cleanup(
        process_create(path(swipl), Args,
                       [process(Pid), stdout(pipe(Out))]),
        ( read_line_to_string(Out, Marker),
          assertion(Marker == "remote_committed"),
          process_kill(Pid, kill),
          process_wait(Pid, Status),
          assertion(Status = killed(_)) ),
        catch(close(Out), _, true)).

run_tool_crash_phase_two(Ledger, MutationFile) :-
    absolute_file_name('test/tool_effect_crash_phase2.pl', Script,
                       [access(read)]),
    append(['-q', '-s', Script, '--'], [Ledger, MutationFile], Args),
    process_create(path(swipl), Args, [process(Pid)]),
    process_wait(Pid, exit(0)).

cleanup_crash_files([]).
cleanup_crash_files([File|Files]) :-
    catch(delete_file(File), _, true),
    cleanup_crash_files(Files).

:- end_tests(rlm_tool_effect).
