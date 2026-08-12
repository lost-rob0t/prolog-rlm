:- begin_tests(rlm_agent).

:- use_module('../prolog/rlm_agent').
:- use_module('../prolog/rlm_plan').

worker_handler(work(echo, Value), Value).
worker_handler(work(block, Seconds), done) :-
    sleep(Seconds).
worker_handler(work(crash, Reason), _) :-
    throw(test_worker_crash(Reason)).

test(child_capabilities_are_narrowed) :-
    with_runtime([root_capabilities([tool(read), model(fake)]),
                  worker_handler(plunit_rlm_agent:worker_handler)],
                 child_capabilities_are_narrowed_case).

child_capabilities_are_narrowed_case(Runtime) :-
    agent_spawn(Runtime,
                none,
                agent_spec(root),
                [tool(read), model(fake)],
                ok(Root)),
    agent_spawn(Runtime,
                Root,
                agent_spec(child),
                [tool(read)],
                ok(Child)),
    agent_status(Runtime, Child, ok(Status)),
    assertion(Status.capabilities == [tool(read)]),
    agent_spawn(Runtime,
                Root,
                agent_spec(widening_child),
                [network(arbitrary)],
                Denied),
    assertion(Denied = error(_)),
    Denied = error(Error),
    assertion(Error.kind == capability_denied).

test(twenty_logical_agents_share_zero_idle_workers) :-
    with_runtime([max_agents(32), worker_count(2)],
                 twenty_logical_agents_case).

twenty_logical_agents_case(Runtime) :-
    forall(between(1, 20, N),
           ( format(atom(Name), 'logical_~d', [N]),
             agent_spawn(Runtime, none, agent_spec(Name), [], ok(_))
           )),
    agent_runtime_status(Runtime, Status),
    assertion(Status.agent_count =:= 20),
    assertion(Status.worker_pool_size =:= 2),
    assertion(Status.worker_running =:= 0).

test(mailbox_limit_applies_backpressure) :-
    with_runtime([mailbox_size(1), send_timeout(0.0)],
                 mailbox_backpressure_case).

mailbox_backpressure_case(Runtime) :-
    Runtime = agent_runtime(RunId),
    agent_spawn(Runtime, none, agent_spec(root), [], ok(Root)),
    agent_send(Runtime, Root, checkpoint(RunId, first), [], ok(_)),
    agent_send(Runtime, Root, checkpoint(RunId, second), [], Full),
    Full = error(FullError),
    assertion(FullError.kind == mailbox_full),
    agent_pump(Runtime, Root, [], ok(_)),
    agent_send(Runtime, Root, checkpoint(RunId, second), [], ok(_)).

test(worker_result_returns_through_mailbox) :-
    with_runtime([worker_count(1),
                  worker_handler(plunit_rlm_agent:worker_handler)],
                 worker_result_case).

worker_result_case(Runtime) :-
    Runtime = agent_runtime(RunId),
    agent_spawn(Runtime, none, agent_spec(root), [], ok(Root)),
    agent_send(Runtime,
               Root,
               request(RunId, call_1, work(echo, hello)),
               [],
               ok(_)),
    agent_pump(Runtime, Root, [], Dispatch),
    assertion(Dispatch = ok(_)),
    pump_until_message(Runtime, Root, 20),
    agent_status(Runtime, Root, ok(Status)),
    assertion(Status.status == active),
    assertion(Status.last_result == ok(hello)),
    assertion(Status.pending == []).

test(child_worker_crash_is_observable_by_parent) :-
    with_runtime([worker_count(1),
                  worker_handler(plunit_rlm_agent:worker_handler)],
                 child_crash_case).

child_crash_case(Runtime) :-
    Runtime = agent_runtime(RunId),
    agent_spawn(Runtime, none, agent_spec(parent), [], ok(Parent)),
    agent_spawn(Runtime, Parent, agent_spec(child), [], ok(Child)),
    drain_agent(Runtime, Parent),
    agent_send(Runtime,
               Child,
               request(RunId, crash_1, work(crash, boom)),
               [],
               ok(_)),
    agent_pump(Runtime, Child, [], ok(_)),
    pump_until_message(Runtime, Child, 20),
    agent_status(Runtime, Child, ok(ChildStatus)),
    get_dict(status, ChildStatus, ChildState),
    ChildState = failed(_),
    pump_until_message(Runtime, Parent, 20),
    agent_status(Runtime, Parent, ok(ParentStatus)),
    get_dict(last_result, ParentStatus, ParentLast),
    ParentLast = child_result{child:agent(_), result:error(_)},
    agent_trace(Runtime, Trace),
    member(Event, Trace),
    get_dict(type, Event, child_failure),
    !.

test(parent_cancellation_propagates_to_child_work) :-
    with_runtime([worker_count(1),
                  worker_handler(plunit_rlm_agent:worker_handler)],
                 cancellation_case).

cancellation_case(Runtime) :-
    Runtime = agent_runtime(RunId),
    agent_spawn(Runtime, none, agent_spec(parent), [], ok(Parent)),
    agent_spawn(Runtime, Parent, agent_spec(child), [], ok(Child)),
    agent_send(Runtime,
               Child,
               request(RunId, block_1, work(block, 2.0)),
               [],
               ok(_)),
    agent_pump(Runtime, Child, [], ok(_)),
    agent_cancel(Runtime, Parent, test_cancel, ok(_)),
    agent_status(Runtime, Parent, ok(ParentStatus)),
    agent_status(Runtime, Child, ok(ChildStatus)),
    assertion(ParentStatus.status == cancelled(test_cancel)),
    assertion(ChildStatus.status == cancelled(test_cancel)).

test(worker_pool_saturation_fails_fast) :-
    with_runtime([worker_count(1),
                  worker_backlog(0),
                  worker_handler(plunit_rlm_agent:worker_handler)],
                 worker_saturation_case).

worker_saturation_case(Runtime) :-
    Runtime = agent_runtime(RunId),
    agent_spawn(Runtime, none, agent_spec(first), [], ok(First)),
    agent_spawn(Runtime, none, agent_spec(second), [], ok(Second)),
    agent_send(Runtime,
               First,
               request(RunId, first_call, work(block, 2.0)),
               [],
               ok(_)),
    agent_pump(Runtime, First, [], ok(_)),
    agent_send(Runtime,
               Second,
               request(RunId, second_call, work(echo, second)),
               [],
               ok(_)),
    agent_pump(Runtime, Second, [], Saturated),
    Saturated = error(Error),
    assertion(Error.kind == worker_pool_saturated),
    agent_status(Runtime, Second, ok(Status)),
    assertion(Status.status = failed(_)).

test(trace_is_bounded) :-
    with_runtime([trace_limit(5), mailbox_size(8)], trace_bound_case).

trace_bound_case(Runtime) :-
    Runtime = agent_runtime(RunId),
    agent_spawn(Runtime, none, agent_spec(root), [], ok(Root)),
    forall(between(1, 6, N),
           ( agent_send(Runtime,
                        Root,
                        checkpoint(RunId, N),
                        [],
                        ok(_)),
             agent_pump(Runtime, Root, [], ok(_))
           )),
    agent_trace(Runtime, Trace),
    length(Trace, Count),
    assertion(Count =< 5),
    last(Trace, Last),
    assertion(Last.type == message_processed).

test(typed_spawn_agent_term_executes_through_closed_tool) :-
    with_runtime([root_capabilities([tool(spawn_agent), tool(read)])],
                 typed_spawn_term_case).

typed_spawn_term_case(Runtime) :-
    agent_spawn(Runtime,
                none,
                agent_spec(root),
                [tool(spawn_agent), tool(read)],
                ok(Root)),
    Plan = plan([
        spawn_agent(agent_spec(child), [tool(read)], child),
        final(var(child))
    ]),
    Caps = [tool(spawn_agent), tool(read)],
    Options = [tools([tool(spawn_agent,
                           rlm_agent:agent_tool_handler(Runtime, Root))])],
    plan_run(Plan, Caps, Options, _{}, ok(Result)),
    Result.value = Child,
    Child = agent(_),
    agent_status(Runtime, Child, ok(Status)),
    assertion(Status.capabilities == [tool(read)]),
    agent_children(Runtime, Root, Children),
    assertion(Children == [Child]).

test(typed_spawn_agent_json_normalizes_and_executes) :-
    with_runtime([root_capabilities([tool(spawn_agent), tool(read)])],
                 typed_spawn_json_case).

typed_spawn_json_case(Runtime) :-
    agent_spawn(Runtime,
                none,
                agent_spec(root),
                [tool(spawn_agent), tool(read)],
                ok(Root)),
    Json = "{\"steps\":[{\"op\":\"spawn_agent\",\"spec\":{\"name\":\"json_child\",\"mode\":\"worker\",\"metadata\":{}},\"capabilities\":[{\"type\":\"tool\",\"name\":\"read\"}],\"bind\":\"child\"},{\"op\":\"final\",\"value\":{\"ref\":\"var\",\"name\":\"child\"}}]}",
    Caps = [tool(spawn_agent), tool(read)],
    Options = [tools([tool(spawn_agent,
                           rlm_agent:agent_tool_handler(Runtime, Root))])],
    plan_run(Json, Caps, Options, _{}, Outcome),
    require_plan_success(typed_spawn_agent_json, Outcome, Result),
    Result.value = Child,
    agent_status(Runtime, Child, ok(Status)),
    assertion(Status.capabilities == [tool(read)]),
    assertion(Status.spec.name == json_child).

test(spawn_agent_capability_denied_before_child_side_effect) :-
    with_runtime([root_capabilities([tool(spawn_agent), tool(read)])],
                 spawn_capability_denied_case).

spawn_capability_denied_case(Runtime) :-
    agent_spawn(Runtime,
                none,
                agent_spec(root),
                [tool(spawn_agent), tool(read)],
                ok(Root)),
    Plan = plan([
        spawn_agent(agent_spec(child), [tool(read)], child),
        final(var(child))
    ]),
    Options = [tools([tool(spawn_agent,
                           rlm_agent:agent_tool_handler(Runtime, Root))])],
    plan_run(Plan, [tool(read)], Options, _{}, error(Error)),
    assertion(Error.kind == capability_denied),
    agent_children(Runtime, Root, Children),
    assertion(Children == []).

require_plan_success(_, ok(Result), Result) :- !.
require_plan_success(Label, Outcome, _) :-
    throw(error(agent_plan_acceptance_failure(Label, Outcome),
                context(plunit_rlm_agent,
                        'typed agent plan did not complete successfully'))).

with_runtime(Options, Goal) :-
    setup_call_cleanup(
        agent_runtime_create(Options, Runtime),
        call(Goal, Runtime),
        agent_runtime_destroy(Runtime)).

pump_until_message(_, _, Attempts) :-
    Attempts =< 0,
    !,
    assertion(fail).
pump_until_message(Runtime, Agent, Attempts) :-
    agent_pump(Runtime, Agent, [timeout(0.1)], Outcome),
    (   Outcome = ok(Pump),
        Pump.status \== idle
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

:- end_tests(rlm_agent).
