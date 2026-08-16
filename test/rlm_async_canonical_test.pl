:- begin_tests(rlm_async_canonical).

:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_completion', []).
:- use_module('../prolog/rlm_completion_async', []).
:- use_module('../prolog/rlm_chain', []).
:- use_module('../prolog/rlm_chain_async', []).
:- use_module('../prolog/rlm', []).
:- use_module('support/completion_test_support').

:- dynamic tool_call_count/1.
:- dynamic active_count/1.
:- dynamic max_active_count/1.

async_value(Value, Value).

async_sleep(Seconds, Value, Value) :-
    sleep(Seconds).

continuation_wrap(Value, continued(Value)).

callback_to_queue(Queue, Outcome) :-
    thread_send_message(Queue, callback(Outcome)).

reset_tool_calls :-
    retractall(tool_call_count(_)),
    assertz(tool_call_count(0)).

bump_tool_calls :-
    with_mutex(plunit_rlm_async_canonical_tool,
               ( retract(tool_call_count(Count0)),
                 Count is Count0+1,
                 assertz(tool_call_count(Count))
               )).

counted_tool(Args, Result) :-
    bump_tool_calls,
    Result = Args.value.

counted_tool_planner(_, ok(Output)) :-
    Plan = plan([tool(counted_tool,
                      literal(_{value:17}),
                      tool_value),
                 final(var(tool_value))]),
    Output = planner_output{
                 plan:Plan,
                 usage:_{prompt_tokens:1,
                         completion_tokens:1,
                         total_tokens:2,
                         cost:0.0}
             }.

reset_concurrency :-
    retractall(active_count(_)),
    retractall(max_active_count(_)),
    assertz(active_count(0)),
    assertz(max_active_count(0)).

tracked_sleep(Seconds, Value, Value) :-
    setup_call_cleanup(
        concurrency_enter,
        sleep(Seconds),
        concurrency_leave).

concurrency_enter :-
    with_mutex(plunit_rlm_async_canonical_concurrency,
               ( retract(active_count(Active0)),
                 Active is Active0+1,
                 assertz(active_count(Active)),
                 retract(max_active_count(Max0)),
                 Max is max(Max0, Active),
                 assertz(max_active_count(Max))
               )).

concurrency_leave :-
    with_mutex(plunit_rlm_async_canonical_concurrency,
               ( retract(active_count(Active0)),
                 Active is Active0-1,
                 assertz(active_count(Active))
               )).

canonical_submit(Module, AsyncName/AsyncArity, ExecuteName/ExecuteArity) :-
    functor(Head, AsyncName, AsyncArity),
    clause(Module:Head, Body),
    submit_closure(Body, Closure),
    strip_module(Closure, ClosureModule, PlainClosure),
    ClosureModule == Module,
    functor(PlainClosure, ExecuteName, ClosureArity),
    ExecuteArity is ClosureArity+1,
    !.

submit_closure(Body, Closure) :-
    sub_term(SubTerm, Body),
    (   SubTerm = rlm_async_submit(Closure, _, _)
    ;   SubTerm = rlm_async:rlm_async_submit(Closure, _, _)
    ).

sync_calls_async(Module, SyncName/SyncArity, AsyncName/AsyncArity) :-
    functor(Head, SyncName, SyncArity),
    clause(Module:Head, Body),
    sub_term(Call, Body),
    callable(Call),
    strip_module(Call, CallModule0, PlainCall),
    functor(PlainCall, AsyncName, AsyncArity),
    (   CallModule0 == Module
    ;   CallModule0 == user
    ),
    !.

body_contains_qualified(Body, Module, Name, Arity) :-
    sub_term(Module:Goal, Body),
    callable(Goal),
    functor(Goal, Name, Arity).

completion_options([
    planner_handler(completion_test_support:direct_planner),
    capabilities([rlm, model(openrouter)]),
    child_capabilities([rlm, model(openrouter)])
]).

tool_completion_options([
    planner_handler(plunit_rlm_async_canonical:counted_tool_planner),
    tools([tool(counted_tool,
                plunit_rlm_async_canonical:counted_tool)]),
    capabilities([rlm, model(openrouter), tool(counted_tool)]),
    child_capabilities([model(openrouter)])
]).

test(completion_async_submits_canonical_execute_predicate) :-
    assertion(canonical_submit(rlm_completion,
                               rlm_completion_async/4,
                               rlm_completion_execute/4)),
    assertion(canonical_submit(rlm_completion,
                               llm_query_async/3,
                               llm_query_execute/3)),
    assertion(canonical_submit(rlm_completion,
                               rlm_query_async/4,
                               rlm_query_execute/4)).

test(chain_async_submits_canonical_execute_predicate) :-
    assertion(canonical_submit(rlm_chain,
                               model_complete_async/3,
                               model_complete_execute/3)),
    assertion(canonical_submit(rlm_chain,
                               model_stream_async/4,
                               model_stream_execute/4)),
    assertion(canonical_submit(rlm_chain,
                               chain_invoke_async/4,
                               chain_invoke_execute/4)),
    assertion(canonical_submit(rlm_chain,
                               chain_stream_async/5,
                               chain_stream_execute/5)).

test(sync_completion_surfaces_call_async_surfaces) :-
    assertion(sync_calls_async(rlm_completion,
                               rlm_completion/4,
                               rlm_completion_async/4)),
    assertion(sync_calls_async(rlm_completion,
                               llm_query/3,
                               llm_query_async/3)),
    assertion(sync_calls_async(rlm_completion,
                               rlm_query/4,
                               rlm_query_async/4)).

test(sync_chain_surfaces_call_async_surfaces) :-
    assertion(sync_calls_async(rlm_chain,
                               model_complete/3,
                               model_complete_async/3)),
    assertion(sync_calls_async(rlm_chain,
                               model_stream/4,
                               model_stream_async/4)),
    assertion(sync_calls_async(rlm_chain,
                               chain_invoke/4,
                               chain_invoke_async/4)),
    assertion(sync_calls_async(rlm_chain,
                               chain_stream/5,
                               chain_stream_async/5)).

test(compatibility_async_modules_never_call_sync_public_wrappers) :-
    forall(member(Module-AsyncPI-SyncModule-SyncPI,
                  [ rlm_completion_async-rlm_completion_async/4-
                    rlm_completion-rlm_completion/4,
                    rlm_completion_async-llm_query_async/3-
                    rlm_completion-llm_query/3,
                    rlm_completion_async-rlm_query_async/4-
                    rlm_completion-rlm_query/4,
                    rlm_chain_async-model_complete_async/3-
                    rlm_chain-model_complete/3,
                    rlm_chain_async-model_stream_async/4-
                    rlm_chain-model_stream/4,
                    rlm_chain_async-chain_invoke_async/4-
                    rlm_chain-chain_invoke/4,
                    rlm_chain_async-chain_stream_async/5-
                    rlm_chain-chain_stream/5
                  ]),
           ( AsyncPI = AsyncName/AsyncArity,
             functor(Head, AsyncName, AsyncArity),
             clause(Module:Head, Body),
             SyncPI = SyncName/SyncArity,
             assertion(\+ body_contains_qualified(Body,
                                                  SyncModule,
                                                  SyncName,
                                                  SyncArity))
           )).

test(top_level_async_facade_has_no_legacy_async_to_sync_tasks) :-
    assertion(\+ current_predicate(rlm:public_completion_async_task/4)),
    assertion(\+ current_predicate(rlm:public_query_async_task/4)),
    assertion(sync_calls_async(rlm,
                               rlm_completion/4,
                               rlm_completion_async/4)),
    assertion(sync_calls_async(rlm,
                               rlm_query/4,
                               rlm_query_async/4)).

test(sync_completion_executes_planner_once,
     [setup(completion_test_support:reset_calls)]) :-
    completion_options(Options),
    rlm_completion:rlm_completion("once",
                                  text("ctx"),
                                  Options,
                                  Outcome),
    Outcome = ok(Result),
    assertion(Result.value == "direct-ok"),
    completion_test_support:planner_calls(Calls),
    assertion(Calls =:= 1).

test(async_completion_executes_planner_once,
     [setup(completion_test_support:reset_calls)]) :-
    completion_options(Options),
    rlm_completion:rlm_completion_async("once",
                                        text("ctx"),
                                        Options,
                                        Future),
    setup_call_cleanup(
        true,
        ( rlm_future_await(Future, 2.0, Outcome),
          Outcome = ok(Result),
          assertion(Result.value == "direct-ok"),
          completion_test_support:planner_calls(Calls),
          assertion(Calls =:= 1)
        ),
        rlm_future_destroy(Future)).

test(sync_and_async_completion_outcomes_accounting_and_trace_match) :-
    completion_options(Options),
    completion_test_support:reset_calls,
    rlm_completion:rlm_completion("equivalent",
                                  text("ctx"),
                                  Options,
                                  SyncOutcome),
    completion_test_support:planner_calls(SyncCalls),
    completion_test_support:reset_calls,
    rlm_completion:rlm_completion_async("equivalent",
                                        text("ctx"),
                                        Options,
                                        Future),
    setup_call_cleanup(
        true,
        rlm_future_await(Future, 2.0, AsyncOutcome),
        rlm_future_destroy(Future)),
    completion_test_support:planner_calls(AsyncCalls),
    assertion(SyncCalls =:= 1),
    assertion(AsyncCalls =:= 1),
    assertion(SyncOutcome == AsyncOutcome).

test(sync_and_async_llm_query_outcomes_accounting_and_trace_match) :-
    Options = [model_handler(completion_test_support:fake_model)],
    completion_test_support:reset_calls,
    rlm_completion:llm_query("same", Options, SyncOutcome),
    completion_test_support:model_calls(SyncCalls),
    completion_test_support:reset_calls,
    rlm_completion:llm_query_async("same", Options, Future),
    setup_call_cleanup(
        true,
        rlm_future_await(Future, 2.0, AsyncOutcome),
        rlm_future_destroy(Future)),
    completion_test_support:model_calls(AsyncCalls),
    assertion(SyncCalls =:= 1),
    assertion(AsyncCalls =:= 1),
    assertion(SyncOutcome == AsyncOutcome).

test(tool_effect_executes_once_for_sync_and_async_completion) :-
    tool_completion_options(Options),
    reset_tool_calls,
    rlm_completion:rlm_completion("tool once",
                                  text("ctx"),
                                  Options,
                                  SyncOutcome),
    tool_call_count(SyncCalls),
    reset_tool_calls,
    rlm_completion:rlm_completion_async("tool once",
                                        text("ctx"),
                                        Options,
                                        Future),
    setup_call_cleanup(
        true,
        rlm_future_await(Future, 2.0, AsyncOutcome),
        rlm_future_destroy(Future)),
    tool_call_count(AsyncCalls),
    assertion(SyncCalls =:= 1),
    assertion(AsyncCalls =:= 1),
    assertion(SyncOutcome == AsyncOutcome).

test(timeout_during_active_completion_does_not_restart_model,
     [setup(completion_test_support:reset_calls)]) :-
    message_queue_create(Queue),
    setup_call_cleanup(
        rlm_completion:llm_query_async(
            "slow",
            [model_handler(completion_test_support:slow_model_started(Queue))],
            Future),
        ( thread_get_message(Queue, started, [timeout(2.0)]),
          rlm_future_await(Future, 0.001, TimeoutOutcome),
          TimeoutOutcome = error(TimeoutError),
          assertion(TimeoutError.kind == timeout),
          completion_test_support:model_calls(CallsAfterTimeout),
          assertion(CallsAfterTimeout =:= 1),
          rlm_future_cancel(Future, CancelOutcome),
          assertion(CancelOutcome == ok(cancelled)),
          rlm_future_await(Future, CancelledOutcome),
          CancelledOutcome = error(CancelError),
          assertion(CancelError.kind == cancelled),
          completion_test_support:model_calls(FinalCalls),
          assertion(FinalCalls =:= 1)
        ),
        ( rlm_future_destroy(Future),
          message_queue_destroy(Queue)
        )).

test(future_metadata_carries_trace_session_and_operation) :-
    rlm_async_submit(async_sleep(0.02, done),
                     async_metadata{operation:test_operation,
                                    trace_id:trace_54,
                                    session_id:session_54},
                     Future),
    setup_call_cleanup(
        true,
        ( rlm_future_metadata(Future, Metadata),
          assertion(Metadata.operation == test_operation),
          assertion(Metadata.trace_id == trace_54),
          assertion(Metadata.session_id == session_54),
          assertion(Metadata.parent_task == none),
          assertion(atom(Metadata.id)),
          rlm_future_await(Future, 1.0, done)
        ),
        rlm_future_destroy(Future)).

test(on_complete_callback_runs_exactly_once) :-
    message_queue_create(Queue),
    setup_call_cleanup(
        rlm_async_submit(async_sleep(0.02, done), Future),
        ( rlm_future_on_complete(
              Future,
              plunit_rlm_async_canonical:callback_to_queue(Queue)),
          rlm_future_await(Future, 1.0, done),
          thread_get_message(Queue, callback(done), [timeout(1.0)]),
          assertion(\+ thread_get_message(Queue, _, [timeout(0.05)]))
        ),
        ( rlm_future_destroy(Future),
          message_queue_destroy(Queue)
        )).

test(continuation_runs_once_and_records_parent_task) :-
    rlm_async_submit(async_value(answer), Parent),
    setup_call_cleanup(
        ( rlm_future_then(
              Parent,
              plunit_rlm_async_canonical:continuation_wrap,
              Child),
          Parent = rlm_future(ParentId)
        ),
        ( rlm_future_metadata(Child, Metadata),
          assertion(Metadata.operation == continuation),
          assertion(Metadata.parent_task == ParentId),
          rlm_future_await(Child, 1.0, ChildOutcome),
          assertion(ChildOutcome == continued(answer))
        ),
        ( rlm_future_destroy(Child),
          rlm_future_destroy(Parent)
        )).

test(parent_cancellation_propagates_to_continuation) :-
    rlm_async_submit(async_sleep(5.0, never), Parent),
    setup_call_cleanup(
        rlm_future_then(Parent,
                        plunit_rlm_async_canonical:continuation_wrap,
                        Child),
        ( rlm_future_cancel(Parent, CancelOutcome),
          assertion(CancelOutcome == ok(cancelled)),
          rlm_future_await(Child, ChildOutcome),
          ChildOutcome = error(Error),
          assertion(Error.kind == cancelled)
        ),
        ( rlm_future_destroy(Child),
          rlm_future_destroy(Parent)
        )).

test(concurrent_tasks_never_exceed_bounded_worker_pool,
     [setup(reset_concurrency)]) :-
    rlm_async_runtime_status(Status),
    WorkerCount = Status.worker_count,
    TaskCount is WorkerCount+4,
    numlist(1, TaskCount, Values),
    findall(Future,
            ( member(Value, Values),
              rlm_async_submit(tracked_sleep(0.05, Value), Future)
            ),
            Futures),
    setup_call_cleanup(
        true,
        ( rlm_future_all(Futures, Outcomes),
          assertion(Outcomes == Values),
          max_active_count(MaxActive),
          assertion(MaxActive > 0),
          assertion(MaxActive =< WorkerCount)
        ),
        maplist(rlm_future_destroy, Futures)).

:- end_tests(rlm_async_canonical).
