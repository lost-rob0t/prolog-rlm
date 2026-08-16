:- begin_tests(rlm_agent_graph_async).

:- use_module(library(time)).
:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_agent').
:- use_module('../prolog/rlm_agent_async', []).
:- use_module('../prolog/rlm_graph').
:- use_module('../prolog/rlm_graph_async', []).

:- dynamic execution_count/2.

reset_count(Key) :-
    retractall(execution_count(Key, _)),
    assertz(execution_count(Key, 0)).

bump_count(Key) :-
    with_mutex(plunit_rlm_agent_graph_async_count,
               ( retract(execution_count(Key, Count0)),
                 Count is Count0+1,
                 assertz(execution_count(Key, Count))
               )).

read_count(Key, Count) :-
    execution_count(Key, Count).

counted_node(Key, Patch, _, _, update(Patch)) :-
    bump_count(Key).

blocking_node(Key, Queue, _, _, update(_{})) :-
    bump_count(Key),
    thread_send_message(Queue, started),
    sleep(5.0).

interrupt_node(Key, _, _, interrupt(needs_resume, _{log:[paused]})) :-
    bump_count(Key).

resume_node(Key, _, Context, update(_{log:[Context.resume]})) :-
    bump_count(Key).

counted_router(Key, _, done) :-
    bump_count(Key).

agent_worker(work(block, Seconds), done) :-
    sleep(Seconds).
agent_worker(work(echo, Value), Value).

block_async(Queue, done) :-
    thread_get_message(Queue, release).

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
    nonvar(SubTerm),
    (   SubTerm = rlm_async_submit(Closure, _, _)
    ;   SubTerm = rlm_async:rlm_async_submit(Closure, _, _)
    ).

sync_calls_async(Module, SyncName/SyncArity, AsyncName/AsyncArity) :-
    functor(Head, SyncName, SyncArity),
    clause(Module:Head, Body),
    body_contains_call(Body, AsyncName, AsyncArity),
    !.

body_contains_call(Body, Name, Arity) :-
    sub_term(Call, Body),
    nonvar(Call),
    source_call_functor(Call, Name, Arity).

source_call_functor(_Module:Goal, Name, Arity) :-
    !,
    callable(Goal),
    functor(Goal, Name, Arity).
source_call_functor(Goal, Name, Arity) :-
    callable(Goal),
    functor(Goal, Name, Arity).

body_contains_qualified(Body, Module, Name, Arity) :-
    sub_term(SubTerm, Body),
    nonvar(SubTerm),
    SubTerm = Module:Goal,
    callable(Goal),
    functor(Goal, Name, Arity).

body_contains_local(Body, Name, Arity) :-
    sub_term(SubTerm, Body),
    nonvar(SubTerm),
    callable(SubTerm),
    functor(SubTerm, Name, Arity).

count_trace_type(Trace, Type, Count) :-
    findall(1,
            ( member(Event, Trace),
              Event.type == Type
            ),
            Ones),
    length(Ones, Count).

trace_types(Trace, Types) :-
    findall(Type,
            ( member(Event, Trace),
              Type = Event.type
            ),
            Types).

count_history_type(History, Type, Count) :-
    findall(1,
            ( member(Event, History),
              Event.type == Type
            ),
            Ones),
    length(Ones, Count).

await_future(Future, Timeout, Outcome) :-
    setup_call_cleanup(
        true,
        rlm_future_await(Future, Timeout, Outcome),
        rlm_future_destroy(Future)).

with_runtime(Options, Goal) :-
    setup_call_cleanup(
        agent_runtime_create(Options, Runtime),
        call(Goal, Runtime),
        agent_runtime_destroy(Runtime)).

basic_schema([
    field(count, integer, 0, sum),
    field(log, list, [], append)
]).

single_graph(Key, Compiled) :-
    basic_schema(Schema),
    Spec = graph(single_graph,
                 Schema,
                 [node(one, one_handler)],
                 [edge(start, one), edge(one, end)]),
    Registry = [handler(one_handler,
                        plunit_rlm_agent_graph_async:counted_node(
                            Key,
                            _{count:1, log:[one]}))],
    graph_compile(Spec, Registry, [], ok(Compiled)).

route_graph(Compiled) :-
    basic_schema(Schema),
    Spec = graph(route_graph,
                 Schema,
                 [node(first, first_handler), node(finish, finish_handler)],
                 [ edge(start, first),
                   conditional(first, route_handler, [route(done, finish)]),
                   edge(finish, end)
                 ]),
    Registry = [ handler(first_handler,
                         plunit_rlm_agent_graph_async:counted_node(
                             route_first,
                             _{count:1, log:[first]})),
                 handler(finish_handler,
                         plunit_rlm_agent_graph_async:counted_node(
                             route_finish,
                             _{count:1, log:[finish]})),
                 router(route_handler,
                        plunit_rlm_agent_graph_async:counted_router(
                            route_router))
               ],
    graph_compile(Spec, Registry, [], ok(Compiled)).

interrupt_graph(Compiled) :-
    basic_schema(Schema),
    Spec = graph(interrupt_async_graph,
                 Schema,
                 [node(wait, wait_handler), node(resume, resume_handler)],
                 [edge(start, wait), edge(wait, resume), edge(resume, end)]),
    Registry = [ handler(wait_handler,
                         plunit_rlm_agent_graph_async:interrupt_node(
                             interrupt_wait)),
                 handler(resume_handler,
                         plunit_rlm_agent_graph_async:resume_node(
                             interrupt_resume))
               ],
    graph_compile(Spec, Registry, [], ok(Compiled)).

blocking_graph(Key, Queue, Compiled) :-
    basic_schema(Schema),
    Spec = graph(blocking_graph,
                 Schema,
                 [node(block, blocker)],
                 [edge(start, block), edge(block, end)]),
    Registry = [handler(blocker,
                        plunit_rlm_agent_graph_async:blocking_node(Key,
                                                                  Queue))],
    graph_compile(Spec, Registry, [], ok(Compiled)).

subgraph_parent(Compiled) :-
    basic_schema(Schema),
    ChildSpec = graph(child_graph,
                      Schema,
                      [node(child, child_handler)],
                      [edge(start, child), edge(child, end)]),
    ChildRegistry = [handler(child_handler,
                             plunit_rlm_agent_graph_async:counted_node(
                                 nested_child,
                                 _{count:1, log:[child]}))],
    graph_compile(ChildSpec, ChildRegistry, [], ok(Child)),
    ParentSpec = graph(parent_graph,
                       Schema,
                       [subgraph(child_step, child_graph)],
                       [edge(start, child_step), edge(child_step, end)]),
    graph_compile(ParentSpec,
                  [subgraph(child_graph, Child)],
                  [],
                  ok(Compiled)).

wait_all_running([], _).
wait_all_running([Future|Futures], Attempts) :-
    Attempts > 0,
    rlm_future_status(Future, Status),
    (   Status.state == running
    ->  wait_all_running(Futures, Attempts)
    ;   sleep(0.005),
        Next is Attempts-1,
        wait_all_running([Future|Futures], Next)
    ).

cancel_and_destroy_futures([]).
cancel_and_destroy_futures([Future|Futures]) :-
    catch(rlm_future_cancel(Future, _), _, true),
    catch(rlm_future_destroy(Future), _, true),
    cancel_and_destroy_futures(Futures).

test(agent_async_surfaces_submit_execute_predicates) :-
    assertion(canonical_submit(rlm_agent,
                               agent_spawn_async/5,
                               agent_spawn_execute/5)),
    assertion(canonical_submit(rlm_agent,
                               agent_send_async/5,
                               agent_send_execute/5)),
    assertion(canonical_submit(rlm_agent,
                               agent_pump_async/4,
                               agent_pump_execute/4)),
    assertion(canonical_submit(rlm_agent,
                               agent_cancel_async/4,
                               agent_cancel_execute/4)).

test(agent_sync_surfaces_start_async_surfaces) :-
    assertion(sync_calls_async(rlm_agent, agent_spawn/5, agent_spawn_async/5)),
    assertion(sync_calls_async(rlm_agent, agent_send/5, agent_send_async/5)),
    assertion(sync_calls_async(rlm_agent, agent_pump/4, agent_pump_async/4)),
    assertion(sync_calls_async(rlm_agent, agent_cancel/4, agent_cancel_async/4)).

test(agent_compatibility_facade_never_calls_sync_public_wrappers) :-
    forall(member(AsyncPI-SyncPI,
                  [ agent_spawn_async/5-agent_spawn/5,
                    agent_send_async/5-agent_send/5,
                    agent_pump_async/4-agent_pump/4,
                    agent_cancel_async/4-agent_cancel/4
                  ]),
           ( AsyncPI = AsyncName/AsyncArity,
             functor(Head, AsyncName, AsyncArity),
             clause(rlm_agent_async:Head, Body),
             SyncPI = SyncName/SyncArity,
             assertion(\+ body_contains_qualified(Body,
                                                  rlm_agent,
                                                  SyncName,
                                                  SyncArity))
           )).

test(agent_internal_composition_uses_execute_abi) :-
    clause(rlm_agent:agent_plan_handler(_, _, _, _, _), PlanBody),
    assertion(body_contains_local(PlanBody, agent_spawn_execute, 5)),
    assertion(\+ body_contains_local(PlanBody, agent_spawn, 5)),
    functor(CancelHead, cancel_children, 3),
    clause(rlm_agent:CancelHead, CancelBody),
    body_contains_local(CancelBody, agent_cancel_execute, 4),
    assertion(\+ body_contains_local(CancelBody, agent_cancel, 4)).

test(sync_agent_spawn_mutates_once) :-
    with_runtime([], sync_agent_spawn_once_case).

sync_agent_spawn_once_case(Runtime) :-
    agent_spawn(Runtime, none, agent_spec(sync_once), [], ok(_)),
    agent_trace(Runtime, Trace),
    count_trace_type(Trace, spawn, Count),
    assertion(Count =:= 1).

test(async_agent_spawn_mutates_once) :-
    with_runtime([], async_agent_spawn_once_case).

async_agent_spawn_once_case(Runtime) :-
    agent_spawn_async(Runtime, none, agent_spec(async_once), [], Future),
    await_future(Future, 1.0, ok(_)),
    agent_trace(Runtime, Trace),
    count_trace_type(Trace, spawn, Count),
    assertion(Count =:= 1).

test(async_agent_capability_narrowing_has_one_child_side_effect) :-
    with_runtime([root_capabilities([tool(read)])],
                 async_agent_capability_case).

async_agent_capability_case(Runtime) :-
    agent_spawn(Runtime, none, agent_spec(root), [tool(read)], ok(Root)),
    agent_spawn_async(Runtime,
                      Root,
                      agent_spec(child),
                      [tool(read)],
                      Future),
    await_future(Future, 1.0, ok(Child)),
    agent_status(Runtime, Child, ok(Status)),
    assertion(Status.capabilities == [tool(read)]),
    agent_children(Runtime, Root, Children),
    assertion(Children == [Child]).

test(async_agent_mailbox_admission_and_backpressure_happen_once) :-
    with_runtime([mailbox_size(1), send_timeout(0.0)],
                 async_agent_mailbox_case).

async_agent_mailbox_case(Runtime) :-
    Runtime = agent_runtime(RunId),
    agent_spawn(Runtime, none, agent_spec(root), [], ok(Root)),
    agent_send_async(Runtime,
                     Root,
                     checkpoint(RunId, first),
                     [],
                     FirstFuture),
    await_future(FirstFuture, 1.0, ok(_)),
    agent_send_async(Runtime,
                     Root,
                     checkpoint(RunId, second),
                     [],
                     SecondFuture),
    await_future(SecondFuture, 1.0, SecondOutcome),
    SecondOutcome = error(SecondError),
    assertion(SecondError.kind == mailbox_full),
    agent_status(Runtime, Root, ok(Status)),
    assertion(Status.mailbox_size =:= 1),
    agent_trace(Runtime, Trace),
    count_trace_type(Trace, mailbox_enqueued, Enqueued),
    count_trace_type(Trace, mailbox_backpressure, Backpressure),
    assertion(Enqueued =:= 1),
    assertion(Backpressure =:= 1).

test(agent_sync_async_trace_shapes_are_equivalent) :-
    with_runtime([], agent_sync_trace_case),
    with_runtime([], agent_async_trace_case).

agent_sync_trace_case(Runtime) :-
    Runtime = agent_runtime(RunId),
    agent_spawn(Runtime, none, agent_spec(root), [], ok(Root)),
    agent_send(Runtime, Root, checkpoint(RunId, sync), [], ok(_)),
    agent_pump(Runtime, Root, [], ok(_)),
    agent_trace(Runtime, Trace),
    trace_types(Trace, Types),
    nb_setval(agent_sync_trace_types, Types).

agent_async_trace_case(Runtime) :-
    Runtime = agent_runtime(RunId),
    agent_spawn_async(Runtime, none, agent_spec(root), [], SpawnFuture),
    await_future(SpawnFuture, 1.0, ok(Root)),
    agent_send_async(Runtime,
                     Root,
                     checkpoint(RunId, sync),
                     [],
                     SendFuture),
    await_future(SendFuture, 1.0, ok(_)),
    agent_pump_async(Runtime, Root, [], PumpFuture),
    await_future(PumpFuture, 1.0, ok(_)),
    agent_trace(Runtime, Trace),
    trace_types(Trace, Types),
    nb_getval(agent_sync_trace_types, SyncTypes),
    assertion(Types == SyncTypes).

test(agent_await_timeout_does_not_restart_pump) :-
    with_runtime([], agent_timeout_case).

agent_timeout_case(Runtime) :-
    agent_spawn(Runtime, none, agent_spec(root), [], ok(Root)),
    agent_pump_async(Runtime, Root, [timeout(0.20)], Future),
    setup_call_cleanup(
        true,
        ( rlm_future_await(Future, 0.01, TimeoutOutcome),
          TimeoutOutcome = error(TimeoutError),
          assertion(TimeoutError.kind == timeout),
          rlm_future_await(Future, 1.0, ok(Pump)),
          assertion(Pump.status == idle),
          agent_status(Runtime, Root, ok(Status)),
          assertion(Status.processed =:= 0)
        ),
        rlm_future_destroy(Future)).

test(agent_future_cancellation_interrupts_active_pump_without_state_mutation) :-
    with_runtime([], agent_future_cancel_case).

agent_future_cancel_case(Runtime) :-
    agent_spawn(Runtime, none, agent_spec(root), [], ok(Root)),
    agent_pump_async(Runtime, Root, [timeout(5.0)], Future),
    sleep(0.03),
    rlm_future_cancel(Future, ok(cancelled)),
    rlm_future_await(Future, Cancelled),
    Cancelled = error(Error),
    assertion(Error.kind == cancelled),
    rlm_future_destroy(Future),
    agent_status(Runtime, Root, ok(Status)),
    assertion(Status.status == active),
    assertion(Status.processed =:= 0).

test(async_agent_cancel_cleans_owned_child_work) :-
    with_runtime([worker_count(1),
                  worker_handler(plunit_rlm_agent_graph_async:agent_worker)],
                 async_agent_cancel_owned_case).

async_agent_cancel_owned_case(Runtime) :-
    Runtime = agent_runtime(RunId),
    agent_spawn(Runtime, none, agent_spec(parent), [], ok(Parent)),
    agent_spawn(Runtime, Parent, agent_spec(child), [], ok(Child)),
    agent_send(Runtime,
               Child,
               request(RunId, blocking, work(block, 5.0)),
               [],
               ok(_)),
    agent_pump(Runtime, Child, [], ok(_)),
    agent_cancel_async(Runtime, Parent, test_cancel, Future),
    await_future(Future, 1.0, ok(_)),
    agent_status(Runtime, Parent, ok(ParentStatus)),
    agent_status(Runtime, Child, ok(ChildStatus)),
    assertion(ParentStatus.status == cancelled(test_cancel)),
    assertion(ChildStatus.status == cancelled(test_cancel)).

test(agent_host_worker_pool_remains_bounded_and_distinct) :-
    with_runtime([worker_count(2)], agent_pool_bound_case).

agent_pool_bound_case(Runtime) :-
    forall(between(1, 12, N),
           ( format(atom(Name), 'agent_~d', [N]),
             agent_spawn(Runtime, none, agent_spec(Name), [], ok(_))
           )),
    agent_runtime_status(Runtime, Status),
    assertion(Status.agent_count =:= 12),
    assertion(Status.worker_pool_size =:= 2),
    assertion(Status.worker_running =:= 0).

test(agent_future_metadata_is_host_controlled) :-
    with_runtime([], agent_metadata_case).

agent_metadata_case(Runtime) :-
    agent_spawn_async(Runtime, none, agent_spec(root), [], Future),
    setup_call_cleanup(
        true,
        ( rlm_future_metadata(Future, Metadata),
          assertion(Metadata.operation == agent_spawn),
          Runtime = agent_runtime(RuntimeId),
          assertion(Metadata.runtime_id == RuntimeId),
          assertion(Metadata.parent_agent == none),
          rlm_future_await(Future, 1.0, ok(_))
        ),
        rlm_future_destroy(Future)).

test(graph_async_surfaces_submit_execute_predicates) :-
    assertion(canonical_submit(rlm_graph,
                               graph_run_async/4,
                               graph_run_execute/4)),
    assertion(canonical_submit(rlm_graph,
                               graph_resume_async/6,
                               graph_resume_execute/6)).

test(graph_sync_surfaces_start_async_surfaces) :-
    assertion(sync_calls_async(rlm_graph, graph_run/4, graph_run_async/4)),
    assertion(sync_calls_async(rlm_graph, graph_resume/6, graph_resume_async/6)).

test(graph_compatibility_facade_never_calls_sync_public_wrappers) :-
    forall(member(AsyncPI-SyncPI,
                  [ graph_run_async/4-graph_run/4,
                    graph_resume_async/6-graph_resume/6
                  ]),
           ( AsyncPI = AsyncName/AsyncArity,
             functor(Head, AsyncName, AsyncArity),
             clause(rlm_graph_async:Head, Body),
             SyncPI = SyncName/SyncArity,
             assertion(\+ body_contains_qualified(Body,
                                                  rlm_graph,
                                                  SyncName,
                                                  SyncArity))
           )).

test(graph_subgraph_composition_uses_execute_abi) :-
    functor(Head, execute_node, 7),
    clause(rlm_graph:Head, Body),
    body_contains_local(Body, graph_run_execute, 4),
    assertion(\+ body_contains_local(Body, graph_run, 4)).

test(sync_graph_executes_node_once) :-
    reset_count(sync_node),
    single_graph(sync_node, Compiled),
    graph_run(Compiled, _{}, [run_id(sync_once)], ok(Result)),
    read_count(sync_node, Count),
    assertion(Count =:= 1),
    assertion(Result.state.count =:= 1).

test(async_graph_executes_node_once) :-
    reset_count(async_node),
    single_graph(async_node, Compiled),
    graph_run_async(Compiled, _{}, [run_id(async_once)], Future),
    await_future(Future, 1.0, ok(Result)),
    read_count(async_node, Count),
    assertion(Count =:= 1),
    assertion(Result.state.count =:= 1).

test(graph_router_reducer_history_and_checkpoint_are_not_duplicated) :-
    reset_count(route_first),
    reset_count(route_finish),
    reset_count(route_router),
    route_graph(Compiled),
    setup_call_cleanup(
        graph_backend_open(memory, Backend),
        ( graph_run_async(Compiled,
                          _{},
                          [backend(Backend), run_id(route_once)],
                          Future),
          await_future(Future, 1.0, ok(Result)),
          read_count(route_first, FirstCount),
          read_count(route_finish, FinishCount),
          read_count(route_router, RouterCount),
          assertion(FirstCount =:= 1),
          assertion(FinishCount =:= 1),
          assertion(RouterCount =:= 1),
          assertion(Result.state.count =:= 2),
          assertion(Result.state.log == [first,finish]),
          count_history_type(Result.history, node_started, Started),
          count_history_type(Result.history, node_completed, Completed),
          count_history_type(Result.history, edge_selected, Edges),
          assertion(Started =:= 2),
          assertion(Completed =:= 2),
          assertion(Edges =:= 2),
          graph_checkpoint(Backend, route_once, Snapshot),
          assertion(Snapshot.status == completed),
          assertion(Snapshot.event_sequence =:= Result.event_sequence)
        ),
        graph_backend_close(Backend)).

test(graph_sync_async_state_outcome_and_history_are_equivalent) :-
    reset_count(route_first),
    reset_count(route_finish),
    reset_count(route_router),
    route_graph(Compiled),
    setup_call_cleanup(
        graph_backend_open(memory, SyncBackend),
        graph_run(Compiled,
                  _{},
                  [backend(SyncBackend), run_id(equivalent_run)],
                  SyncOutcome),
        graph_backend_close(SyncBackend)),
    reset_count(route_first),
    reset_count(route_finish),
    reset_count(route_router),
    setup_call_cleanup(
        graph_backend_open(memory, AsyncBackend),
        ( graph_run_async(Compiled,
                          _{},
                          [backend(AsyncBackend), run_id(equivalent_run)],
                          Future),
          await_future(Future, 1.0, AsyncOutcome)
        ),
        graph_backend_close(AsyncBackend)),
    assertion(SyncOutcome =@= AsyncOutcome).

test(graph_timeout_does_not_restart_active_node) :-
    reset_count(timeout_node),
    message_queue_create(Queue),
    setup_call_cleanup(
        true,
        ( blocking_graph(timeout_node, Queue, Compiled),
          graph_run_async(Compiled, _{}, [time_limit(0.05)], Future),
          setup_call_cleanup(
              true,
              ( thread_get_message(Queue, started, [timeout(1.0)]),
                rlm_future_await(Future, 1.0, Outcome),
                Outcome = error(Error),
                assertion(Error.kind == timeout),
                read_count(timeout_node, Count),
                assertion(Count =:= 1)
              ),
              rlm_future_destroy(Future))
        ),
        message_queue_destroy(Queue)).

test(graph_future_cancellation_does_not_orphan_active_node) :-
    reset_count(cancel_node),
    message_queue_create(Queue),
    setup_call_cleanup(
        true,
        ( blocking_graph(cancel_node, Queue, Compiled),
          graph_run_async(Compiled, _{}, [time_limit(10.0)], Future),
          setup_call_cleanup(
              true,
              ( thread_get_message(Queue, started, [timeout(1.0)]),
                rlm_future_cancel(Future, ok(cancelled)),
                rlm_future_await(Future, Outcome),
                Outcome = error(Error),
                assertion(Error.kind == cancelled),
                read_count(cancel_node, Count),
                assertion(Count =:= 1)
              ),
              rlm_future_destroy(Future))
        ),
        message_queue_destroy(Queue)).

test(graph_token_cancellation_reaches_active_async_graph) :-
    reset_count(token_cancel_node),
    message_queue_create(Queue),
    graph_cancellation_token(Token),
    setup_call_cleanup(
        true,
        ( blocking_graph(token_cancel_node, Queue, Compiled),
          graph_run_async(Compiled,
                          _{},
                          [cancellation_token(Token), time_limit(10.0)],
                          Future),
          setup_call_cleanup(
              true,
              ( thread_get_message(Queue, started, [timeout(1.0)]),
                graph_cancel(Token),
                rlm_future_await(Future, 1.0, Outcome),
                Outcome = error(Error),
                assertion(Error.kind == cancelled)
              ),
              rlm_future_destroy(Future))
        ),
        message_queue_destroy(Queue)).

test(graph_resume_does_not_repeat_precheckpoint_node) :-
    reset_count(interrupt_wait),
    reset_count(interrupt_resume),
    interrupt_graph(Compiled),
    setup_call_cleanup(
        graph_backend_open(memory, Backend),
        ( graph_run_async(Compiled,
                          _{},
                          [backend(Backend), run_id(resume_once)],
                          RunFuture),
          await_future(RunFuture, 1.0, ok(Paused)),
          assertion(Paused.status == paused(needs_resume)),
          read_count(interrupt_wait, WaitBefore),
          assertion(WaitBefore =:= 1),
          graph_resume_async(Compiled,
                             Backend,
                             resume_once,
                             approved,
                             [],
                             ResumeFuture),
          await_future(ResumeFuture, 1.0, ok(Completed)),
          assertion(Completed.status == completed),
          read_count(interrupt_wait, WaitAfter),
          read_count(interrupt_resume, ResumeCount),
          assertion(WaitAfter =:= 1),
          assertion(ResumeCount =:= 1),
          count_history_type(Completed.history, node_completed, NodeCompleted),
          assertion(NodeCompleted =:= 2)
        ),
        graph_backend_close(Backend)).

test(graph_future_metadata_carries_graph_and_run_identity) :-
    reset_count(metadata_node),
    single_graph(metadata_node, Compiled),
    graph_run_async(Compiled,
                    _{},
                    [run_id(metadata_run),
                     trace_id(trace_54),
                     session_id(session_54)],
                    Future),
    setup_call_cleanup(
        true,
        ( rlm_future_metadata(Future, Metadata),
          assertion(Metadata.operation == graph_run),
          assertion(Metadata.graph_id == single_graph),
          assertion(Metadata.graph_run_id == metadata_run),
          assertion(Metadata.trace_id == trace_54),
          assertion(Metadata.session_id == session_54),
          rlm_future_await(Future, 1.0, ok(_))
        ),
        rlm_future_destroy(Future)).

test(subgraph_execute_abi_avoids_nested_future_deadlock_under_saturation) :-
    reset_count(nested_child),
    message_queue_create(Queue),
    setup_call_cleanup(
        ( findall(Future,
                  ( between(1, 7, _),
                    rlm_async_submit(
                        plunit_rlm_agent_graph_async:block_async(Queue),
                        Future)
                  ),
                  Blockers),
          wait_all_running(Blockers, 400)
        ),
        ( subgraph_parent(Compiled),
          graph_run_async(Compiled, _{}, [run_id(no_nested_wait)], GraphFuture),
          setup_call_cleanup(
              true,
              ( rlm_future_await(GraphFuture, 0.75, GraphOutcome),
                GraphOutcome = ok(Result),
                assertion(Result.status == completed),
                read_count(nested_child, ChildCount),
                assertion(ChildCount =:= 1)
              ),
              rlm_future_destroy(GraphFuture))
        ),
        ( cancel_and_destroy_futures(Blockers),
          message_queue_destroy(Queue)
        )).

:- end_tests(rlm_agent_graph_async).
