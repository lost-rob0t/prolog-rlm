:- begin_tests(rlm_subagent_supervision).

:- use_module('../prolog/rlm_agent').
:- use_module('../prolog/rlm_async').

worker_handler(work(echo, Value), Value).
blocking_handler(Queue, work(block), _) :-
    thread_send_message(Queue, started),
    thread_get_message(Queue, release).

test(supervised_call_uses_child_owned_worker) :-
    setup_call_cleanup(
        agent_runtime_create([worker_count(1)], Runtime),
        supervised_call_uses_child_owned_worker_case(Runtime),
        agent_runtime_destroy(Runtime)).

supervised_call_uses_child_owned_worker_case(Runtime) :-
    agent_spawn(Runtime, none, agent_spec(parent), [], ok(Parent)),
    agent_spawn(Runtime, Parent, agent_spec(child), [], ok(Child)),
    drain_agent(Runtime, Parent),
    agent_supervised_call(Runtime,
                          Child,
                          plunit_rlm_subagent_supervision:worker_handler,
                          work(echo, evidence),
                          [timeout(1.0)],
                          ok(evidence)),
    agent_status(Runtime, Child, ok(ChildStatus)),
    assertion(ChildStatus.last_result == ok(evidence)),
    pump_until_message(Runtime, Parent, 20),
    agent_status(Runtime, Parent, ok(ParentStatus)),
    assertion(ParentStatus.last_result ==
              child_result{child:Child, result:ok(evidence)}).

test(parent_cancellation_interrupts_supervised_call) :-
    message_queue_create(Queue),
    setup_call_cleanup(
        agent_runtime_create([worker_count(1)], Runtime),
        parent_cancellation_interrupts_supervised_call_case(Runtime, Queue),
        ( agent_runtime_destroy(Runtime),
          message_queue_destroy(Queue)
        )).

parent_cancellation_interrupts_supervised_call_case(Runtime, Queue) :-
    agent_spawn(Runtime, none, agent_spec(parent), [], ok(Parent)),
    agent_spawn(Runtime, Parent, agent_spec(child), [], ok(Child)),
    drain_agent(Runtime, Parent),
    agent_supervised_call_async(
        Runtime,
        Child,
        plunit_rlm_subagent_supervision:blocking_handler(Queue),
        work(block),
        [timeout(5.0)],
        Future),
    thread_get_message(Queue, started, [timeout(1.0)]),
    agent_cancel(Runtime, Parent, test_cancel, ok(_)),
    setup_call_cleanup(
        true,
        rlm_future_await(Future, Outcome),
        rlm_future_destroy(Future)),
    Outcome = error(Error),
    assertion(Error.kind == cancelled),
    agent_status(Runtime, Child, ok(ChildStatus)),
    assertion(ChildStatus.status == cancelled(test_cancel)).

test(successful_child_worker_result_reaches_parent) :-
    setup_call_cleanup(
        agent_runtime_create([worker_count(1),
                              worker_handler(plunit_rlm_subagent_supervision:worker_handler)],
                             Runtime),
        successful_child_worker_result_reaches_parent_case(Runtime),
        agent_runtime_destroy(Runtime)).

successful_child_worker_result_reaches_parent_case(Runtime) :-
    Runtime = agent_runtime(RunId),
    agent_spawn(Runtime, none, agent_spec(parent), [], ok(Parent)),
    agent_spawn(Runtime, Parent, agent_spec(child), [], ok(Child)),
    drain_agent(Runtime, Parent),
    agent_send(Runtime,
               Child,
               request(RunId, child_call, work(echo, evidence)),
               [],
               ok(_)),
    agent_pump(Runtime, Child, [], ok(Dispatch)),
    assertion(Dispatch.status == dispatched),
    pump_until_message(Runtime, Child, 20),
    pump_until_message(Runtime, Parent, 20),
    agent_status(Runtime, Parent, ok(ParentStatus)),
    assertion(ParentStatus.last_result ==
              child_result{child:Child, result:ok(evidence)}),
    agent_trace(Runtime, Trace),
    include(child_result_event_for(Parent, Child), Trace, ChildResultEvents),
    assertion(ChildResultEvents = [_]).

child_result_event_for(Parent, Child, Event) :-
    Event.type == child_result,
    Event.parent == Parent,
    Event.child == Child,
    Event.result == ok(evidence).

test(parent_mailbox_backpressure_is_not_reported_as_delivery) :-
    setup_call_cleanup(
        agent_runtime_create([worker_count(1),
                              mailbox_size(1),
                              worker_handler(plunit_rlm_subagent_supervision:worker_handler)],
                             Runtime),
        parent_mailbox_backpressure_case(Runtime),
        agent_runtime_destroy(Runtime)).

parent_mailbox_backpressure_case(Runtime) :-
    Runtime = agent_runtime(RunId),
    agent_spawn(Runtime, none, agent_spec(parent), [], ok(Parent)),
    agent_spawn(Runtime, Parent, agent_spec(child), [], ok(Child)),
    agent_send(Runtime,
               Child,
               request(RunId, child_call, work(echo, evidence)),
               [],
               ok(_)),
    agent_pump(Runtime, Child, [], ok(Dispatch)),
    assertion(Dispatch.status == dispatched),
    pump_until_message(Runtime, Child, 20),
    agent_trace(Runtime, Trace),
    include(child_result_backpressure_for(Parent, Child), Trace, Backpressure),
    assertion(Backpressure = [_]),
    assertion(\+ ( member(Event, Trace),
                    child_result_event_for(Parent, Child, Event) )).

child_result_backpressure_for(Parent, Child, Event) :-
    Event.type == child_result_backpressure,
    Event.parent == Parent,
    Event.child == Child,
    Event.result == ok(evidence),
    Event.cause == error(mailbox_full).

pump_until_message(_, _, Attempts) :-
    Attempts =< 0,
    !,
    assertion(fail).
pump_until_message(Runtime, Agent, Attempts) :-
    agent_pump(Runtime, Agent, [timeout(0.1)], Outcome),
    (   Outcome = ok(Pump), Pump.status \== idle
    ->  true
    ;   Next is Attempts-1,
        pump_until_message(Runtime, Agent, Next)
    ).

drain_agent(Runtime, Agent) :-
    agent_pump(Runtime, Agent, [], Outcome),
    (   Outcome = ok(Pump), Pump.status == idle
    ->  true
    ;   drain_agent(Runtime, Agent)
    ).

:- end_tests(rlm_subagent_supervision).
