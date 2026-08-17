:- begin_tests(rlm_authority_lifecycle).

:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_authority').
:- use_module('../prolog/rlm_tool').

:- dynamic lifecycle_mutations/1.

reset_lifecycle_mutations :-
    retractall(lifecycle_mutations(_)),
    assertz(lifecycle_mutations(0)).

lifecycle_mutation_count(Count) :-
    ( lifecycle_mutations(Count) -> true ; Count = 0 ).

lifecycle_write(Args, json{seen:Seen, count:Count}) :-
    Seen = Args.value,
    with_mutex(plunit_rlm_authority_lifecycle_mutation,
               ( retract(lifecycle_mutations(Current)),
                 Count is Current+1,
                 assertz(lifecycle_mutations(Count)) )).

lifecycle_preflight(Args, Args,
                    operation_details{target_path:"fixture://authority-lifecycle"}).

lifecycle_schema(
    tool_schema{name:lifecycle_write,
                description:"authority lifecycle mutation fixture",
                capability:tool(lifecycle_write),
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

setup_lifecycle_registry(Registry) :-
    tool_registry_create(Registry),
    lifecycle_schema(Schema),
    tool_register(Registry,
                  Schema,
                  tool_handler(plunit_rlm_authority_lifecycle:lifecycle_preflight,
                               plunit_rlm_authority_lifecycle:lifecycle_write),
                  ok(_)).

cleanup_lifecycle(Registry, Context) :-
    catch(rlm_authority_clear(Context), _, true),
    catch(tool_registry_destroy(Registry), _, true).

invoke_lifecycle_pending(Registry, Context, Value, Pending) :-
    tool_invoke(Registry,
                [tool(lifecycle_write)],
                lifecycle_write,
                _{value:Value},
                [authority_context(Context)],
                approval_required(Pending),
                _).

scheduler_blocker(Gate, released) :-
    thread_get_message(Gate, release).

spawn_scheduler_blockers(_, 0, []) :- !.
spawn_scheduler_blockers(Gate, Count, [Future|Futures]) :-
    Count > 0,
    rlm_async_submit(
        plunit_rlm_authority_lifecycle:scheduler_blocker(Gate),
        async_metadata{operation:authority_test_blocker},
        Future),
    Next is Count-1,
    spawn_scheduler_blockers(Gate, Next, Futures).

wait_for_running(Target) :-
    wait_for_running(Target, 400).

wait_for_running(Target, Attempts) :-
    rlm_async_runtime_status(Status),
    (   Status.running >= Target
    ->  true
    ;   Attempts > 0,
        sleep(0.005),
        Next is Attempts-1,
        wait_for_running(Target, Next)
    ).

release_blockers(_, 0) :- !.
release_blockers(Gate, Count) :-
    Count > 0,
    thread_send_message(Gate, release),
    Next is Count-1,
    release_blockers(Gate, Next).

await_blocker(Future) :-
    rlm_future_await(Future, 2.0, released),
    rlm_future_destroy(Future).

race_wait(Start) :- thread_get_message(Start, go).

race_approve(Start, ApprovalId) :-
    race_wait(Start),
    rlm_approve(ApprovalId, _).

race_cancel(Start, Context) :-
    race_wait(Start),
    rlm_pending_cancel_owner(Context, concurrent_owner_cancel).

run_approve_cancel_race(Registry, Context, Iteration) :-
    lifecycle_mutation_count(Before),
    invoke_lifecycle_pending(Registry, Context, Iteration, Pending),
    rlm_pending_resolution_async(Pending.id, ResolutionFuture),
    message_queue_create(Start, [max_size(2)]),
    setup_call_cleanup(
        ( thread_create(
              plunit_rlm_authority_lifecycle:race_approve(Start, Pending.id),
              Approver, []),
          thread_create(
              plunit_rlm_authority_lifecycle:race_cancel(Start, Context),
              Canceller, []) ),
        ( thread_send_message(Start, go),
          thread_send_message(Start, go),
          thread_join(Approver, _),
          thread_join(Canceller, _),
          rlm_future_await(ResolutionFuture, 2.0, _),
          lifecycle_mutation_count(After),
          Delta is After-Before,
          assertion(Delta >= 0),
          assertion(Delta =< 1),
          ( rlm_pending_approval(Context, Pending.id, Record)
          -> assertion(memberchk(Record.state,
                                 [resolved, denied, cancelled]))
          ;  true ) ),
        catch(message_queue_destroy(Start), _, true)).

run_races(_, _, 0) :- !.
run_races(Registry, Context, Count) :-
    Count > 0,
    run_approve_cancel_race(Registry, Context, Count),
    Next is Count-1,
    run_races(Registry, Context, Next).

create_and_deny(Registry, Context, Value, ApprovalId) :-
    invoke_lifecycle_pending(Registry, Context, Value, Pending),
    ApprovalId = Pending.id,
    rlm_deny(ApprovalId, retention_fixture, ok(_)).

create_denied_range(_, _, Current, Last, []) :-
    Current > Last,
    !.
create_denied_range(Registry, Context, Current, Last, [Id|Ids]) :-
    create_and_deny(Registry, Context, Current, Id),
    Next is Current+1,
    create_denied_range(Registry, Context, Next, Last, Ids).

edit_chain(_, _, 0, Pending, Pending) :- !.
edit_chain(Registry, Context, Count, Pending0, Pending) :-
    Count > 0,
    Value is 1000+Count,
    rlm_edit(Pending0.id,
             _{args:_{value:Value}},
             ok(Edit)),
    Pending1 = Edit.approval,
    Next is Count-1,
    ( Registry = Registry, Context = Context -> true ),
    edit_chain(Registry, Context, Next, Pending1, Pending).

terminal_record_id(Context, Id) :-
    rlm_authority:authority_pending(Id, Context, Record),
    memberchk(Record.state, [resolved, denied, superseded, cancelled]).

assert_terminal_controls_released(Context) :-
    findall(Id, terminal_record_id(Context, Id), Ids),
    forall(member(Id, Ids),
           assertion(\+ rlm_authority:authority_pending_control(
                             Id, _, _, _, _))).

assert_terminal_bound(Context, Expected) :-
    findall(Id, terminal_record_id(Context, Id), Ids),
    length(Ids, Expected),
    findall(Id,
            rlm_authority:authority_terminal_resolution(Id, Context, _),
            ResolutionIds),
    length(ResolutionIds, Expected),
    assert_terminal_controls_released(Context).

expect_pruned_resolution(ApprovalId) :-
    catch(rlm_pending_resolution_async(ApprovalId, _),
          error(existence_error(rlm_pending_operation, ApprovalId), _),
          Missing = true),
    assertion(Missing == true).

/* #63: cancellation linearizability ------------------------------------ */

test(cancel_queued_approved_execution_never_mutates_after_workers_release,
     [setup(reset_lifecycle_mutations)]) :-
    Context = agent(authority_linearizable_runtime, queued_child),
    setup_lifecycle_registry(Registry),
    message_queue_create(BlockGate, [max_size(8)]),
    setup_call_cleanup(
        spawn_scheduler_blockers(BlockGate, 8, Blockers),
        ( wait_for_running(8),
          invoke_lifecycle_pending(Registry, Context, 1, Pending),
          rlm_pending_resolution_async(Pending.id, ResolutionFuture),
          rlm_approve(Pending.id, ok(_)),
          rlm_pending_approval(Context, Pending.id, Scheduled),
          assertion(Scheduled.state == scheduled),
          rlm_pending_cancel_owner(Context, scheduler_saturated_cancel),
          rlm_future_await(ResolutionFuture, 2.0, Resolution),
          Resolution = error(Cancelled),
          assertion(Cancelled.kind == cancelled),
          assertion(Cancelled.before_execution_claim == true),
          release_blockers(BlockGate, 8),
          maplist(await_blocker, Blockers),
          sleep(0.02),
          lifecycle_mutation_count(Mutations),
          assertion(Mutations =:= 0),
          rlm_pending_approval(Context, Pending.id, Terminal),
          assertion(Terminal.state == cancelled) ),
        ( release_blockers(BlockGate, 8),
          maplist(catch_destroy_future, Blockers),
          catch(message_queue_destroy(BlockGate), _, true),
          cleanup_lifecycle(Registry, Context) )).

catch_destroy_future(Future) :-
    catch(rlm_future_cancel(Future, _), _, true),
    catch(rlm_future_destroy(Future), _, true).

test(concurrent_approve_cancel_race_resolves_once_and_mutates_at_most_once,
     [setup(reset_lifecycle_mutations)]) :-
    Context = agent(authority_linearizable_runtime, race_child),
    setup_call_cleanup(
        setup_lifecycle_registry(Registry),
        run_races(Registry, Context, 24),
        cleanup_lifecycle(Registry, Context)).

/* #64: bounded terminal state ------------------------------------------ */

test(terminal_history_and_resolution_futures_are_bounded,
     [setup(reset_lifecycle_mutations)]) :-
    Context = session(authority_terminal_bound),
    setup_call_cleanup(
        setup_lifecycle_registry(Registry),
        ( create_denied_range(Registry, Context, 1, 80, Ids),
          Ids = [First|_],
          assert_terminal_bound(Context, 64),
          assertion(\+ rlm_pending_approval(Context, First, _)),
          expect_pruned_resolution(First),
          rlm_approve(First, error(ApprovalError)),
          assertion(ApprovalError.kind == invalid_authority_operation) ),
        cleanup_lifecycle(Registry, Context)).

test(edit_supersede_chain_releases_private_controls_and_prunes_old_history,
     [setup(reset_lifecycle_mutations)]) :-
    Context = session(authority_edit_retention),
    setup_call_cleanup(
        setup_lifecycle_registry(Registry),
        ( invoke_lifecycle_pending(Registry, Context, 900, First),
          FirstId = First.id,
          edit_chain(Registry, Context, 80, First, Final),
          assert_terminal_bound(Context, 64),
          assertion(\+ rlm_pending_approval(Context, FirstId, _)),
          expect_pruned_resolution(FirstId),
          rlm_deny(Final.id, finish_edit_chain, ok(_)),
          assert_terminal_bound(Context, 64) ),
        cleanup_lifecycle(Registry, Context)).

:- end_tests(rlm_authority_lifecycle).
