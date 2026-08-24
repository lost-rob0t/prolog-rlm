:- begin_tests(rlm_subagent).

:- meta_predicate with_subagent(3).

:- use_module('../prolog/rlm_agent').
:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_prompt_command').
:- use_module('../prolog/rlm_subagent').
:- use_module('../prolog/rlm_tool').
:- use_module('support/completion_test_support').

subagent_options([planner_handler(completion_test_support:direct_planner),
                  capabilities([rlm, model(openrouter)]),
                  child_capabilities([rlm, model(openrouter)])]).

blocking_planner(Queue, _, _) :-
    thread_send_message(Queue, started),
    thread_get_message(Queue, release).

with_subagent(Goal) :-
    agent_runtime_create([root_capabilities([tool(rlm_subagent),
                                             rlm,
                                             model(openrouter)]),
                          max_agents(3)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( agent_spawn(Runtime, none, agent_spec(parent),
                      [tool(rlm_subagent), rlm, model(openrouter)], ok(Parent)),
          subagent_options(Options),
          rlm_subagent_register(Registry, Runtime, Parent,
                                [rlm, model(openrouter)], text("bounded evidence"),
                                Options, ok(_)),
          call(Goal, Runtime, Registry, Parent)
        ),
        ( tool_registry_destroy(Registry),
          agent_runtime_destroy(Runtime)
        )).

test(canonical_tool_returns_structured_child_envelope,
     [setup(completion_test_support:reset_calls)]) :-
    with_subagent(structured_child_case).

structured_child_case(Runtime, Registry, Parent) :-
    Records = [prompt(short_unknown, "Need evidence."),
               prompt_trigger(short_unknown, unknown),
               prompt_action(short_unknown, delegate_subagent)],
    prompt_command_compile(Records, unknown, ok(Command)),
    Command.command = tool(Tool),
    tool_invoke(Registry, [tool(rlm_subagent)], Tool,
                json{query:Command.text}, [], ok(Execution), Trace),
    Envelope = Execution.value,
    assertion(Trace.authorization == allowed),
    assertion(ground(Envelope)),
    assertion(Envelope.status == completed),
    assertion(Envelope.value == "direct-ok"),
    assertion(Envelope.correlation.parent == Parent),
    Envelope.correlation.child = agent(_),
    assertion(Envelope.usage.model_calls =:= 1),
    agent_children(Runtime, Parent, Children),
    assertion(Children == [Envelope.correlation.child]),
    Child = Envelope.correlation.child,
    agent_status(Runtime, Child, ok(ChildStatus)),
    assertion(ChildStatus.last_result == ok(Envelope)),
    pump_until_child_result(Runtime, Parent, Child, 20),
    agent_status(Runtime, Parent, ok(ParentStatus)),
    assertion(ParentStatus.last_result ==
              child_result{child:Child, result:ok(Envelope)}).

pump_until_child_result(_, _, _, Attempts) :-
    Attempts =< 0,
    !,
    assertion(fail).
pump_until_child_result(Runtime, Parent, Child, Attempts) :-
    agent_pump(Runtime, Parent, [timeout(0.1)], Outcome),
    (   Outcome = ok(Pump),
        Pump.status == processed,
        get_dict(reply, Pump, Reply),
        is_dict(Reply, agent_reply),
        get_dict(kind, Reply, child_result),
        get_dict(child, Reply, Child)
    ->  true
    ;   Next is Attempts-1,
        pump_until_child_result(Runtime, Parent, Child, Next)
    ).

test(parent_cancellation_interrupts_child_completion) :-
    message_queue_create(Queue),
    agent_runtime_create([root_capabilities([tool(rlm_subagent),
                                             rlm,
                                             model(openrouter)]),
                          max_agents(3)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        cancelled_child_completion_case(Runtime, Registry, Queue),
        ( tool_registry_destroy(Registry),
          agent_runtime_destroy(Runtime),
          message_queue_destroy(Queue)
        )).

cancelled_child_completion_case(Runtime, Registry, Queue) :-
    agent_spawn(Runtime, none, agent_spec(parent),
                [tool(rlm_subagent), rlm, model(openrouter)], ok(Parent)),
    Options = [planner_handler(plunit_rlm_subagent:blocking_planner(Queue)),
               capabilities([rlm, model(openrouter)]),
               child_capabilities([rlm, model(openrouter)])],
    rlm_subagent_register(Registry, Runtime, Parent,
                          [rlm, model(openrouter)], text("bounded evidence"),
                          Options, ok(_)),
    tool_invoke_async(Registry, [tool(rlm_subagent)], rlm_subagent,
                      json{query:"Need evidence."}, [], Future),
    thread_get_message(Queue, started, [timeout(1.0)]),
    agent_children(Runtime, Parent, [Child]),
    agent_cancel(Runtime, Parent, test_cancel, ok(_)),
    setup_call_cleanup(
        true,
        rlm_future_await(Future, FutureResult),
        rlm_future_destroy(Future)),
    FutureResult = tool_async_result{outcome:ok(Execution), trace:_},
    Envelope = Execution.value,
    assertion(Envelope.status == failed),
    assertion(Envelope.error.kind == cancelled),
    assertion(Envelope.correlation.child == Child),
    agent_status(Runtime, Child, ok(ChildStatus)),
    assertion(ChildStatus.status == cancelled(test_cancel)).

test(capability_denial_prevents_child_creation) :-
    with_subagent(capability_denial_case).

capability_denial_case(Runtime, Registry, Parent) :-
    agent_children(Runtime, Parent, Before),
    tool_invoke(Registry, [], rlm_subagent,
                json{query:"Need evidence."}, [], error(Error), Trace),
    assertion(Error.kind == capability_denied),
    assertion(Trace.authorization == denied),
    agent_children(Runtime, Parent, After),
    assertion(Before == After).

test(child_capability_widening_is_structured_failure) :-
    agent_runtime_create([root_capabilities([tool(rlm_subagent), rlm])], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( agent_spawn(Runtime, none, agent_spec(parent),
                      [tool(rlm_subagent), rlm], ok(Parent)),
          subagent_options(Options),
          rlm_subagent_register(Registry, Runtime, Parent,
                                [rlm, model(openrouter)], text("ctx"),
                                Options, ok(_)),
          tool_invoke(Registry, [tool(rlm_subagent)], rlm_subagent,
                      json{query:"unknown"}, [], ok(Execution), _),
          Envelope = Execution.value,
          assertion(Envelope.status == failed),
          assertion(Envelope.error.kind == capability_denied),
          assertion(Envelope.correlation.child == none)
        ),
        ( tool_registry_destroy(Registry), agent_runtime_destroy(Runtime) )).

:- end_tests(rlm_subagent).
