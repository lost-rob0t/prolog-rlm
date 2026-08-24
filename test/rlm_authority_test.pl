:- begin_tests(rlm_authority).

:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_authority').
:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_effect').

:- dynamic mutation_counter/1.

reset_mutations :-
    retractall(mutation_counter(_)),
    assertz(mutation_counter(0)).

mutation_count(Count) :-
    ( mutation_counter(Count) -> true ; Count = 0 ).

bump_mutation(Value) :-
    with_mutex(plunit_rlm_authority_mutation,
               ( retract(mutation_counter(Current)),
                 Next is Current+1,
                 assertz(mutation_counter(Next)) )),
    Value = Next.

write_tool(Args, json{seen:Value, count:Count}) :-
    Value = Args.value,
    bump_mutation(Count).

read_tool(Args, json{seen:Value}) :-
    Value = Args.value.

write_preflight(Args, Args,
                operation_details{target_path:"fixture://authority-write"}).

rejecting_preflight(_, _, _) :- fail.

write_schema(
    tool_schema{name:authority_write,
                description:"authority mutation fixture",
                capability:tool(authority_write),
                effect:write,
                arguments:_{type:object,
                            required:[value],
                            additional_properties:false,
                            properties:_{value:_{type:integer}}},
                result:_{type:object,
                         required:[seen,count],
                         additional_properties:false,
                         properties:_{seen:_{type:integer},
                                      count:_{type:integer}}},
                limits:_{time_limit:1.0, max_output_bytes:4096}}).

read_schema(
    tool_schema{name:authority_read,
                description:"authority read fixture",
                capability:tool(authority_read),
                effect:read,
                arguments:_{type:object,
                            required:[value],
                            additional_properties:false,
                            properties:_{value:_{type:integer}}},
                result:_{type:object,
                         required:[seen],
                         additional_properties:false,
                         properties:_{seen:_{type:integer}}},
                limits:_{time_limit:1.0, max_output_bytes:4096}}).

confined_schema(
    tool_schema{name:authority_confined,
                description:"hard confinement fixture",
                capability:tool(authority_confined),
                effect:write,
                arguments:_{type:object,
                            required:[],
                            additional_properties:false,
                            properties:_{}},
                result:_{type:object,
                         required:[seen,count],
                         additional_properties:false,
                         properties:_{seen:_{type:integer},
                                      count:_{type:integer}}},
                limits:_{time_limit:1.0, max_output_bytes:4096}}).

setup_write_registry(Registry) :-
    (   catch(rlm_effect_store_id(_), _, fail)
    ->  true
    ;   tmp_file(rlm_authority_effect, File),
        rlm_effect_store_open(File) ),
    tool_registry_create(Registry),
    write_schema(Schema),
    tool_register(Registry,
                  Schema,
                  tool_handler(plunit_rlm_authority:write_preflight,
                               plunit_rlm_authority:write_tool),
                  ok(_)).

setup_read_registry(Registry) :-
    tool_registry_create(Registry),
    read_schema(Schema),
    tool_register(Registry,
                  Schema,
                  plunit_rlm_authority:read_tool,
                  ok(_)).

setup_confined_registry(Registry) :-
    tool_registry_create(Registry),
    confined_schema(Schema),
    tool_register(Registry,
                  Schema,
                  tool_handler(plunit_rlm_authority:rejecting_preflight,
                               plunit_rlm_authority:write_tool),
                  ok(_)).

cleanup_context(Context) :-
    catch(rlm_authority_clear(Context), _, true).

cleanup_registry_context(Registry, Context) :-
    cleanup_context(Context),
    tool_registry_destroy(Registry),
    catch(rlm_effect_store_close, _, true).

invoke_write(Registry, Context, Value, Outcome, Trace) :-
    tool_invoke(Registry,
                [tool(authority_write)],
                authority_write,
                _{value:Value},
                [authority_context(Context)],
                Outcome,
                Trace).

await_approved(ApprovalId, Resolution) :-
    rlm_pending_resolution_async(ApprovalId, ResolutionFuture),
    rlm_approve(ApprovalId, _),
    rlm_future_await(ResolutionFuture, 5.0, Resolution).

set_if_unset_worker(Context) :-
    rlm_set_authority_if_unset(Context, dangerous, _).

spawn_setters(0, _, []) :- !.
spawn_setters(Count, Context, [Thread|Threads]) :-
    Count > 0,
    thread_create(plunit_rlm_authority:set_if_unset_worker(Context),
                  Thread,
                  []),
    Next is Count-1,
    spawn_setters(Next, Context, Threads).

join_threads([]).
join_threads([Thread|Threads]) :-
    thread_join(Thread, true),
    join_threads(Threads).

immediate_task(Value, Value).

/* Core authority -------------------------------------------------------- */

test(unset_defaults_to_approve_diff) :-
    Context = session(authority_default),
    setup_call_cleanup(
        true,
        ( rlm_authority(Context, Mode),
          assertion(Mode == approve_diff) ),
        cleanup_context(Context)).

test(all_canonical_tiers_validate) :-
    Context = session(authority_tiers),
    setup_call_cleanup(
        true,
        forall(member(Mode,
                      [approve_diff, allow_once, allow_session, dangerous]),
               ( rlm_set_authority(Context, Mode, ok(_)),
                 rlm_authority(Context, Actual),
                 assertion(Actual == Mode) )),
        cleanup_context(Context)).

test(yolo_is_not_canonical) :-
    Context = session(authority_no_yolo),
    setup_call_cleanup(
        true,
        ( rlm_set_authority(Context, yolo, error(Error)),
          assertion(Error.kind == invalid_authority_operation),
          rlm_authority(Context, Mode),
          assertion(Mode == approve_diff) ),
        cleanup_context(Context)).

test(set_if_unset_is_atomic_and_idempotent) :-
    Context = session(authority_atomic_set),
    setup_call_cleanup(
        true,
        ( spawn_setters(12, Context, Threads),
          join_threads(Threads),
          rlm_authority(Context, Mode),
          assertion(Mode == dangerous),
          rlm_authority_events(Context, Events),
          include(is_authority_set_event, Events, SetEvents),
          assertion(length(SetEvents, 1)) ),
        cleanup_context(Context)).

is_authority_set_event(Event) :- Event.type == authority_set.

test(child_authority_narrowing_succeeds) :-
    Parent = runtime(authority_parent_narrow),
    Child = agent(authority_parent_narrow, child),
    setup_call_cleanup(
        rlm_set_authority(Parent, dangerous, ok(_)),
        ( rlm_authority_child(Parent, Child, allow_once, ok(Result)),
          assertion(Result.mode == allow_once),
          rlm_authority(Child, Mode),
          assertion(Mode == allow_once) ),
        ( cleanup_context(Child), cleanup_context(Parent) )).

test(child_authority_widening_fails) :-
    Parent = runtime(authority_parent_widen),
    Child = agent(authority_parent_widen, child),
    setup_call_cleanup(
        rlm_set_authority(Parent, allow_once, ok(_)),
        ( rlm_authority_child(Parent, Child, dangerous, error(Error)),
          assertion(Error.kind == widening_denied),
          rlm_authority(Child, Mode),
          assertion(Mode == approve_diff) ),
        ( cleanup_context(Child), cleanup_context(Parent) )).

/* Fingerprints ---------------------------------------------------------- */

test(identical_normalized_operation_has_stable_fingerprint) :-
    Context = session(fingerprint_stable),
    Op = authority_operation{name:write,
                             effect:write,
                             capability:tool(write),
                             args:_{a:1,b:2},
                             details:_{path:"/tmp/a"}},
    rlm_operation_fingerprint(Context, Op, First),
    rlm_operation_fingerprint(Context, Op, Second),
    assertion(First == Second).

test(relevant_payload_change_changes_fingerprint) :-
    Context = session(fingerprint_change),
    Base = authority_operation{name:write,
                               effect:write,
                               capability:tool(write),
                               args:_{value:1}},
    Changed = authority_operation{name:write,
                                  effect:write,
                                  capability:tool(write),
                                  args:_{value:2}},
    rlm_operation_fingerprint(Context, Base, First),
    rlm_operation_fingerprint(Context, Changed, Second),
    assertion(First \== Second).

test(dict_key_order_does_not_change_fingerprint) :-
    Context = session(fingerprint_order),
    dict_create(ArgsA, args, [a-1,b-2]),
    dict_create(ArgsB, args, [b-2,a-1]),
    OpA = authority_operation{name:write,
                              effect:write,
                              capability:tool(write),
                              args:ArgsA},
    OpB = authority_operation{name:write,
                              effect:write,
                              capability:tool(write),
                              args:ArgsB},
    rlm_operation_fingerprint(Context, OpA, First),
    rlm_operation_fingerprint(Context, OpB, Second),
    assertion(First == Second).

/* Tool boundary --------------------------------------------------------- */

test(read_only_tool_executes_without_pending_approval) :-
    Context = session(read_without_approval),
    setup_call_cleanup(
        setup_read_registry(Registry),
        ( tool_invoke(Registry,
                      [tool(authority_read)],
                      authority_read,
                      _{value:7},
                      [authority_context(Context)],
                      ok(Execution),
                      Trace),
          assertion(Execution.value.seen =:= 7),
          assertion(Trace.authorization == allowed),
          assertion(Trace.authority == approve_diff),
          rlm_pending_approvals(Context, Pending),
          assertion(Pending == []) ),
        cleanup_registry_context(Registry, Context)).

test(mutating_tool_approve_diff_creates_one_pending_and_zero_mutations,
     [setup(reset_mutations)]) :-
    Context = session(pending_one),
    setup_call_cleanup(
        setup_write_registry(Registry),
        ( invoke_write(Registry, Context, 11,
                       approval_required(Pending), Trace),
          assertion(Trace.status == approval_required),
          assertion(Pending.effect == write),
          rlm_pending_approvals(Context, Approvals),
          assertion(length(Approvals, 1)),
          mutation_count(Count),
          assertion(Count =:= 0) ),
        cleanup_registry_context(Registry, Context)).

test(capability_denial_occurs_before_pending_creation,
     [setup(reset_mutations)]) :-
    Context = session(capability_before_authority),
    setup_call_cleanup(
        setup_write_registry(Registry),
        ( tool_invoke(Registry, [], authority_write, _{value:1},
                      [authority_context(Context)], error(Error), Trace),
          assertion(Error.kind == capability_denied),
          assertion(Trace.authorization == denied),
          rlm_pending_approvals(Context, Pending),
          assertion(Pending == []),
          mutation_count(0) ),
        cleanup_registry_context(Registry, Context)).

test(malformed_schema_input_creates_no_pending) :-
    Context = session(schema_before_authority),
    setup_call_cleanup(
        setup_write_registry(Registry),
        ( tool_invoke(Registry, [tool(authority_write)], authority_write,
                      _{}, [authority_context(Context)], error(Error), Trace),
          assertion(Error.kind == schema_validation_failed),
          assertion(Trace.status == malformed_args),
          rlm_pending_approvals(Context, Pending),
          assertion(Pending == []) ),
        cleanup_registry_context(Registry, Context)).

test(hard_confinement_denial_creates_no_pending) :-
    Context = session(confinement_before_authority),
    setup_call_cleanup(
        setup_confined_registry(Registry),
        ( tool_invoke(Registry, [tool(authority_confined)], authority_confined,
                      _{}, [authority_context(Context)], error(Error), Trace),
          assertion(Error.kind == confinement_denied),
          assertion(Trace.status == confinement_denied),
          rlm_pending_approvals(Context, Pending),
          assertion(Pending == []) ),
        cleanup_registry_context(Registry, Context)).

test(missing_effect_metadata_is_rejected) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( Schema = tool_schema{name:missing_effect,
                               description:"must fail closed",
                               capability:tool(missing_effect),
                               arguments:_{type:object},
                               result:_{type:any},
                               limits:_{time_limit:1.0,
                                        max_output_bytes:1024}},
          tool_register(Registry, Schema,
                        plunit_rlm_authority:read_tool,
                        error(Error)),
          assertion(Error.kind == invalid_tool_operation) ),
        tool_registry_destroy(Registry)).

/* Approve, deny, edit --------------------------------------------------- */

test(approval_executes_exact_target_once,
     [setup(reset_mutations)]) :-
    Context = session(approve_once),
    setup_call_cleanup(
        setup_write_registry(Registry),
        ( invoke_write(Registry, Context, 21,
                       approval_required(Pending), _),
          ApprovalId = Pending.id,
          await_approved(ApprovalId, Resolution),
          Resolution.outcome = ok(Value),
          assertion(Value.seen =:= 21),
          mutation_count(Count),
          assertion(Count =:= 1),
          rlm_approve(ApprovalId, error(Stale)),
          assertion(Stale.kind == approval_not_pending),
          mutation_count(StillOne),
          assertion(StillOne =:= 1) ),
        cleanup_registry_context(Registry, Context)).

test(denial_executes_nothing_and_records_reason,
     [setup(reset_mutations)]) :-
    Context = session(deny_pending),
    setup_call_cleanup(
        setup_write_registry(Registry),
        ( invoke_write(Registry, Context, 31,
                       approval_required(Pending), _),
          ApprovalId = Pending.id,
          rlm_pending_resolution_async(ApprovalId, ResolutionFuture),
          rlm_deny(ApprovalId, host_policy_denied, ok(Denied)),
          get_dict(state, Denied, DeniedState),
          assertion(DeniedState == denied),
          rlm_future_await(ResolutionFuture, 1.0, Resolution),
          Resolution = denied(AuthorityDenial),
          get_dict(reason, AuthorityDenial, DenialReason),
          assertion(DenialReason == host_policy_denied),
          mutation_count(Count),
          assertion(Count =:= 0),
          rlm_authority_events(Context, Events),
          member(Event, Events),
          get_dict(type, Event, approval_denied),
          get_dict(reason, Event, EventReason),
          assertion(EventReason == host_policy_denied) ),
        cleanup_registry_context(Registry, Context)).

test(edit_creates_new_id_and_fingerprint_and_stale_approval_fails,
     [setup(reset_mutations)]) :-
    Context = session(edit_pending),
    setup_call_cleanup(
        setup_write_registry(Registry),
        ( invoke_write(Registry, Context, 41,
                       approval_required(Old), _),
          rlm_edit(Old.id, _{args:_{value:42}}, ok(Edit)),
          assertion(Edit.id \== Old.id),
          assertion(Edit.fingerprint \== Old.fingerprint),
          rlm_approve(Old.id, error(Stale)),
          assertion(Stale.kind == approval_not_pending),
          await_approved(Edit.id, Resolution),
          Resolution.outcome = ok(Value),
          assertion(Value.seen =:= 42),
          mutation_count(Count),
          assertion(Count =:= 1) ),
        cleanup_registry_context(Registry, Context)).

/* Tier semantics -------------------------------------------------------- */

test(allow_once_is_consumed_once_and_retry_does_not_reexecute,
     [setup(reset_mutations)]) :-
    Context = session(allow_once_retry),
    setup_call_cleanup(
        setup_write_registry(Registry),
        ( rlm_set_authority(Context, allow_once, ok(_)),
          invoke_write(Registry, Context, 51, ok(First), FirstTrace),
          assertion(First.value.seen =:= 51),
          assertion(FirstTrace.authority == allow_once),
          mutation_count(FirstCount),
          assertion(FirstCount =:= 1),
          invoke_write(Registry, Context, 51, ok(Replay), _),
          assertion(Replay.value.seen =:= 51),
          mutation_count(ReplayCount),
          assertion(ReplayCount =:= 1),
          rlm_authority(Context, Mode),
          assertion(Mode == approve_diff) ),
        cleanup_registry_context(Registry, Context)).

test(concurrent_allow_once_exact_attempts_execute_at_most_once,
     [setup(reset_mutations)]) :-
    Context = session(allow_once_race),
    setup_call_cleanup(
        setup_write_registry(Registry),
        ( rlm_set_authority(Context, allow_once, ok(_)),
          tool_invoke_async(Registry, [tool(authority_write)], authority_write,
                            _{value:61}, [authority_context(Context)], First),
          tool_invoke_async(Registry, [tool(authority_write)], authority_write,
                            _{value:61}, [authority_context(Context)], Second),
          rlm_future_await(First, 2.0, _),
          rlm_future_await(Second, 2.0, _),
          mutation_count(Count),
          assertion(Count =:= 1),
          rlm_future_destroy(First),
          rlm_future_destroy(Second) ),
        cleanup_registry_context(Registry, Context)).

test(allow_session_is_scoped_to_one_context_and_teardown_invalidates) :-
    First = session(allow_session_first),
    Second = session(allow_session_second),
    setup_call_cleanup(
        setup_write_registry(Registry),
        ( rlm_set_authority(First, allow_session, ok(_)),
          invoke_write(Registry, First, 71, ok(_), _),
          invoke_write(Registry, Second, 72, approval_required(_), _),
          rlm_authority_clear(First),
          rlm_authority(First, Reset),
          assertion(Reset == approve_diff),
          rlm_authority(Second, Other),
          assertion(Other == approve_diff) ),
        ( cleanup_context(First),
          cleanup_context(Second),
          tool_registry_destroy(Registry) )).

test(dangerous_bypasses_only_approval_not_capability_schema_or_confinement,
     [setup(reset_mutations)]) :-
    Context = session(dangerous_hard_boundaries),
    setup_call_cleanup(
        setup_write_registry(Registry),
        ( rlm_set_authority(Context, dangerous, ok(_)),
          invoke_write(Registry, Context, 81, ok(_), Trace),
          assertion(Trace.authority == dangerous),
          mutation_count(One),
          assertion(One =:= 1),
          tool_invoke(Registry, [], authority_write, _{value:82},
                      [authority_context(Context)], error(CapError), _),
          assertion(CapError.kind == capability_denied),
          tool_invoke(Registry, [tool(authority_write)], authority_write, _{},
                      [authority_context(Context)], error(SchemaError), _),
          assertion(SchemaError.kind == schema_validation_failed) ),
        cleanup_registry_context(Registry, Context)),
    setup_call_cleanup(
        setup_confined_registry(Confined),
        ( rlm_set_authority(Context, dangerous, ok(_)),
          tool_invoke(Confined, [tool(authority_confined)], authority_confined,
                      _{}, [authority_context(Context)],
                      error(ConfinementError), _),
          assertion(ConfinementError.kind == confinement_denied) ),
        cleanup_registry_context(Confined, Context)).

/* Async pending contract ------------------------------------------------ */

test(sync_and_async_authority_decisions_are_equivalent,
     [setup(reset_mutations)]) :-
    SyncContext = session(sync_authority),
    AsyncContext = session(async_authority),
    setup_call_cleanup(
        setup_write_registry(Registry),
        ( invoke_write(Registry, SyncContext, 91,
                       approval_required(SyncPending), SyncTrace),
          tool_invoke_async(Registry, [tool(authority_write)], authority_write,
                            _{value:91}, [authority_context(AsyncContext)], Future),
          rlm_future_await(Future, 2.0, AsyncResult),
          rlm_future_destroy(Future),
          AsyncResult.outcome = approval_required(AsyncPending),
          AsyncTrace = AsyncResult.trace,
          assertion(SyncTrace.status == AsyncTrace.status),
          assertion(SyncTrace.authorization == AsyncTrace.authorization),
          assertion(SyncPending.effect == AsyncPending.effect),
          assertion(SyncPending.operation.name == AsyncPending.operation.name),
          mutation_count(Count),
          assertion(Count =:= 0) ),
        ( cleanup_context(SyncContext),
          cleanup_context(AsyncContext),
          tool_registry_destroy(Registry) )).

test(pending_human_approvals_use_no_shared_workers_and_do_not_starve_work,
     [setup(reset_mutations)]) :-
    Context = session(pending_no_workers),
    setup_call_cleanup(
        setup_write_registry(Registry),
        ( findall(Future,
                  ( between(1, 24, Value),
                    tool_invoke_async(Registry,
                                      [tool(authority_write)],
                                      authority_write,
                                      _{value:Value},
                                      [authority_context(Context)],
                                      Future) ),
                  ToolFutures),
          maplist(await_tool_future, ToolFutures),
          maplist(rlm_future_destroy, ToolFutures),
          rlm_async_runtime_status(Before),
          assertion(Before.running =:= 0),
          assertion(Before.queued =:= 0),
          findall(Future,
                  ( between(1, 16, Value),
                    rlm_async_submit(
                        plunit_rlm_authority:immediate_task(Value),
                        Future) ),
                  WorkFutures),
          maplist(await_plain_future, WorkFutures),
          maplist(rlm_future_destroy, WorkFutures),
          mutation_count(Count),
          assertion(Count =:= 0),
          rlm_pending_approvals(Context, Pending),
          assertion(length(Pending, 24)) ),
        cleanup_registry_context(Registry, Context)).

await_tool_future(Future) :-
    rlm_future_await(Future, 2.0, Result),
    assertion(Result.outcome = approval_required(_)).

await_plain_future(Future) :-
    rlm_future_await(Future, 1.0, Value),
    assertion(integer(Value)).

test(owner_cancellation_resolves_pending_without_target_mutation,
     [setup(reset_mutations)]) :-
    Context = agent(runtime_cancel, child_cancel),
    setup_call_cleanup(
        setup_write_registry(Registry),
        ( invoke_write(Registry, Context, 101,
                       approval_required(Pending), _),
          rlm_pending_resolution_async(Pending.id, ResolutionFuture),
          rlm_pending_cancel_owner(Context, parent_cancelled),
          rlm_future_await(ResolutionFuture, 1.0, Resolution),
          Resolution = denied(Denial),
          assertion(Denial.reason == cancelled(parent_cancelled)),
          mutation_count(Count),
          assertion(Count =:= 0),
          rlm_pending_approval(Context, Pending.id, Record),
          assertion(Record.state == denied) ),
        cleanup_registry_context(Registry, Context)).

:- end_tests(rlm_authority).
