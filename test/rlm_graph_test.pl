:- begin_tests(rlm_graph).

:- use_module('../prolog/rlm_graph').
:- use_module(library(filesex)).

:- dynamic streamed_event/1.

inc_node(_, _, update(_{count:1, log:[tick]})).
noop_node(_, _, update(_{})).
finish_node(_, _, update(_{approved:true, log:[done]})).
loop_router(State, again) :- State.count < 3, !.
loop_router(_, done).

interrupt_node(_, _, interrupt(needs_approval, _{log:[paused]})).
resume_node(_, Context, update(_{approved:true, log:[Context.resume]})).

always_loop_router(_, again).
blocking_node(_, _, update(_{})) :- sleep(3).

child_inc_node(_, _, update(_{count:2, log:[child]})).
parent_finish_node(_, _, update(_{log:[parent]})).

capture_event(Event) :- assertz(streamed_event(Event)).

basic_schema([
    field(count, integer, 0, sum),
    field(log, list, [], append),
    field(approved, boolean, false, replace)
]).

loop_spec(graph(loop_graph,
                Schema,
                [ node(increment, inc),
                  node(decide, noop),
                  node(finish, finish)
                ],
                [ edge(start, increment),
                  edge(increment, decide),
                  conditional(decide,
                              loop_route,
                              [route(again, increment), route(done, finish)]),
                  edge(finish, end)
                ])) :-
    basic_schema(Schema).

loop_registry([
    handler(inc, plunit_rlm_graph:inc_node),
    handler(noop, plunit_rlm_graph:noop_node),
    handler(finish, plunit_rlm_graph:finish_node),
    router(loop_route, plunit_rlm_graph:loop_router)
]).

interrupt_spec(graph(interrupt_graph,
                     Schema,
                     [ node(wait, wait_handler),
                       node(resume, resume_handler)
                     ],
                     [ edge(start, wait),
                       edge(wait, resume),
                       edge(resume, end)
                     ])) :-
    basic_schema(Schema).

interrupt_registry([
    handler(wait_handler, plunit_rlm_graph:interrupt_node),
    handler(resume_handler, plunit_rlm_graph:resume_node)
]).

test(branching_and_bounded_loop_execute_deterministically) :-
    compile_loop(Compiled),
    setup_call_cleanup(
        graph_backend_open(memory, Backend),
        ( graph_run(Compiled,
                    _{},
                    [backend(Backend), max_visits_per_node(4)],
                    ok(Result)),
          assertion(Result.status == completed),
          assertion(Result.state.count =:= 3),
          assertion(Result.state.log == [tick,tick,tick,done]),
          assertion(Result.state.approved == true),
          assertion(Result.visits.increment =:= 3),
          assertion(Result.visits.decide =:= 3),
          assertion(Result.visits.finish =:= 1),
          assertion(member(Event, Result.history)),
          assertion(Event.type == run_completed)
        ),
        graph_backend_close(Backend)).

test(unreachable_node_is_rejected_before_execution) :-
    basic_schema(Schema),
    Spec = graph(unreachable,
                 Schema,
                 [node(a, a_handler), node(orphan, orphan_handler)],
                 [edge(start, a), edge(a, end), edge(orphan, end)]),
    Registry = [handler(a_handler, plunit_rlm_graph:noop_node),
                handler(orphan_handler, plunit_rlm_graph:noop_node)],
    graph_compile(Spec, Registry, [], Outcome),
    Outcome = error(Error),
    assertion(Error.phase == compile),
    assertion(Error.detail = unreachable_nodes([orphan])).

test(node_without_path_to_end_is_rejected) :-
    basic_schema(Schema),
    Spec = graph(no_end,
                 Schema,
                 [node(loop, loop_handler)],
                 [edge(start, loop), edge(loop, loop)]),
    Registry = [handler(loop_handler, plunit_rlm_graph:noop_node)],
    graph_compile(Spec, Registry, [], Outcome),
    Outcome = error(Error),
    assertion(Error.detail == no_path_to_end(loop)).

test(visit_limit_stops_runtime_loop) :-
    basic_schema(Schema),
    Spec = graph(infinite_runtime_loop,
                 Schema,
                 [node(loop, loop_handler)],
                 [ edge(start, loop),
                   conditional(loop,
                               loop_route,
                               [route(again, loop), route(done, end)])
                 ]),
    Registry = [handler(loop_handler, plunit_rlm_graph:noop_node),
                router(loop_route, plunit_rlm_graph:always_loop_router)],
    graph_compile(Spec, Registry, [], ok(Compiled)),
    graph_run(Compiled,
              _{},
              [max_steps(20), max_visits_per_node(2)],
              Outcome),
    Outcome = error(Error),
    assertion(Error.phase == execute),
    assertion(Error.detail == node_visit_budget_exhausted(loop, 2)).

test(memory_interrupt_and_resume) :-
    compile_interrupt(Compiled),
    setup_call_cleanup(
        graph_backend_open(memory, Backend),
        ( graph_run(Compiled,
                    _{},
                    [backend(Backend), run_id(memory_resume)],
                    ok(Paused)),
          assertion(Paused.status == paused(needs_approval)),
          assertion(Paused.current == resume),
          assertion(Paused.state.log == [paused]),
          graph_checkpoint(Backend, memory_resume, Snapshot),
          assertion(Snapshot.status == paused(needs_approval)),
          graph_resume(Compiled,
                       Backend,
                       memory_resume,
                       approved,
                       [],
                       ok(Completed)),
          assertion(Completed.status == completed),
          assertion(Completed.state.approved == true),
          assertion(Completed.state.log == [paused,approved]),
          graph_history(Backend, memory_resume, History),
          assertion(has_event(interrupted, History)),
          assertion(has_event(resumed, History)),
          assertion(has_event(run_completed, History))
        ),
        graph_backend_close(Backend)).

test(persistent_checkpoint_survives_detach_and_reattach) :-
    compile_interrupt(Compiled),
    tmp_file(graph_checkpoint, File),
    setup_call_cleanup(
        true,
        persistent_resume_case(File, Compiled),
        cleanup_persist_file(File)).

persistent_resume_case(File, Compiled) :-
    graph_backend_open(persist(File), Backend1),
    graph_run(Compiled,
              _{},
              [backend(Backend1), run_id(persist_resume)],
              ok(Paused)),
    assertion(Paused.status == paused(needs_approval)),
    graph_backend_close(Backend1),
    graph_backend_open(persist(File), Backend2),
    graph_checkpoint(Backend2, persist_resume, Reloaded),
    assertion(Reloaded.status == paused(needs_approval)),
    graph_resume(Compiled,
                 Backend2,
                 persist_resume,
                 approved_after_restart,
                 [],
                 ok(Completed)),
    assertion(Completed.status == completed),
    assertion(Completed.state.log == [paused,approved_after_restart]),
    graph_backend_close(Backend2).

test(event_stream_receives_ordered_events) :-
    retractall(streamed_event(_)),
    compile_loop(Compiled),
    graph_run(Compiled,
              _{},
              [event_handler(plunit_rlm_graph:capture_event)],
              ok(Result)),
    findall(Event, streamed_event(Event), Events),
    assertion(Events \== []),
    maplist(event_sequence, Events, Sequences),
    msort(Sequences, Sequences),
    assertion(last_type(run_completed, Events)),
    assertion(Result.status == completed).

test(wall_time_interrupts_blocking_node) :-
    basic_schema(Schema),
    Spec = graph(timeout_graph,
                 Schema,
                 [node(block, blocker)],
                 [edge(start, block), edge(block, end)]),
    Registry = [handler(blocker, plunit_rlm_graph:blocking_node)],
    graph_compile(Spec, Registry, [], ok(Compiled)),
    graph_run(Compiled, _{}, [time_limit(0.05)], Outcome),
    Outcome = error(Error),
    assertion(Error.kind == timeout).

test(cancellation_interrupts_running_node) :-
    basic_schema(Schema),
    Spec = graph(cancel_graph,
                 Schema,
                 [node(block, blocker)],
                 [edge(start, block), edge(block, end)]),
    Registry = [handler(blocker, plunit_rlm_graph:blocking_node)],
    graph_compile(Spec, Registry, [], ok(Compiled)),
    graph_cancellation_token(Token),
    message_queue_create(Queue),
    setup_call_cleanup(
        thread_create(( graph_run(Compiled,
                                  _{},
                                  [cancellation_token(Token), time_limit(5.0)],
                                  ThreadOutcome),
                        thread_send_message(Queue, ThreadOutcome)
                      ),
                      Thread,
                      []),
        ( sleep(0.05),
          graph_cancel(Token),
          thread_get_message(Queue, Outcome, [timeout(2.0)]),
          Outcome = error(Error),
          assertion(Error.kind == cancelled),
          thread_join(Thread, _)
        ),
        message_queue_destroy(Queue)).

test(subgraph_applies_reducer_deltas) :-
    basic_schema(Schema),
    ChildSpec = graph(child_graph,
                      Schema,
                      [node(child_inc, child_handler)],
                      [edge(start, child_inc), edge(child_inc, end)]),
    ChildRegistry = [handler(child_handler,
                             plunit_rlm_graph:child_inc_node)],
    graph_compile(ChildSpec, ChildRegistry, [], ok(Child)),
    ParentSpec = graph(parent_graph,
                       Schema,
                       [ subgraph(child_step, child_graph),
                         node(parent_finish, parent_handler)
                       ],
                       [ edge(start, child_step),
                         edge(child_step, parent_finish),
                         edge(parent_finish, end)
                       ]),
    ParentRegistry = [subgraph(child_graph, Child),
                      handler(parent_handler,
                              plunit_rlm_graph:parent_finish_node)],
    graph_compile(ParentSpec, ParentRegistry, [], ok(Parent)),
    graph_run(Parent, _{}, [], ok(Result)),
    assertion(Result.state.count =:= 2),
    assertion(Result.state.log == [child,parent]).

compile_loop(Compiled) :-
    loop_spec(Spec),
    loop_registry(Registry),
    graph_compile(Spec, Registry, [], ok(Compiled)).

compile_interrupt(Compiled) :-
    interrupt_spec(Spec),
    interrupt_registry(Registry),
    graph_compile(Spec, Registry, [], ok(Compiled)).

has_event(Type, Events) :-
    member(Event, Events),
    Event.type == Type,
    !.

last_type(Type, Events) :-
    last(Events, Event),
    Event.type == Type.

event_sequence(Event, Sequence) :- Sequence = Event.sequence.

cleanup_persist_file(File) :-
    catch(graph_backend_close(graph_backend(persist, File)), _, true),
    (   exists_file(File)
    ->  delete_file(File)
    ;   true
    ).

:- end_tests(rlm_graph).
