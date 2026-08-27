:- begin_tests(rlm_subagent).

:- meta_predicate with_subagent(3).

:- use_module('../prolog/rlm_agent').
:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_authority').
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

tool_planner(Name, _, ok(Output)) :-
    Plan = plan([tool(Name, literal(json{}), result),
                 final(var(result))]),
    Output = planner_output{plan:Plan,
                            usage:_{prompt_tokens:1,
                                    completion_tokens:1,
                                    total_tokens:2,
                                    cost:0.0}}.

parallel_planner(_, ok(Output)) :-
    Branches = [plan([final(literal(first))]),
                plan([final(literal(second))])],
    Plan = plan([parallel(Branches, results),
                 final(var(results))]),
    Output = planner_output{plan:Plan,
                            usage:_{prompt_tokens:1,
                                    completion_tokens:1,
                                    total_tokens:2,
                                    cost:0.0}}.

slow_planner(_, ok(Output)) :-
    sleep(5),
    tool_planner(unused, ignored, ok(Output)).

fixture_tool(_, _{seen:true}).

fixture_tool_schema(Name,
                    tool_schema{name:Name,
                                description:"subagent boundary fixture",
                                capability:tool(Name),
                                effect:read,
                                arguments:_{type:object,
                                            required:[],
                                            additional_properties:false,
                                            properties:_{}},
                                result:_{type:object},
                                limits:_{time_limit:1.0,
                                         max_output_bytes:1024}}).

bounded_subagent(Planner, Budget, Envelope) :-
    Caps = [tool(rlm_subagent), rlm, parallel, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
          Options = [planner_handler(Planner),
                     capabilities([rlm, parallel, model(openrouter)]),
                     child_capabilities([rlm, parallel, model(openrouter)]),
                     budget(Budget)],
          rlm_subagent_register(Registry, Runtime, Parent,
                                [rlm, parallel, model(openrouter)], text("ctx"),
                                Options, ok(_)),
          tool_invoke(Registry, Caps, rlm_subagent,
                      json{query:"unknown"}, [], ok(Execution), _),
          Envelope = Execution.value
        ),
        ( tool_registry_destroy(Registry), agent_runtime_destroy(Runtime) )).

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

test(child_completion_cannot_widen_spawn_capabilities) :-
    ParentCaps = [tool(rlm_subagent), tool(secret_fixture),
                  rlm, model(openrouter)],
    ChildCaps = [rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(ParentCaps)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( agent_spawn(Runtime, none, agent_spec(parent), ParentCaps,
                      ok(Parent)),
          fixture_tool_schema(secret_fixture, SecretSchema),
          tool_register(Registry, SecretSchema,
                        plunit_rlm_subagent:fixture_tool, ok(_)),
          Options = [planner_handler(plunit_rlm_subagent:tool_planner(
                                         secret_fixture)),
                     capabilities(ParentCaps),
                     child_capabilities(ChildCaps),
                     tool_registry(Registry)],
          rlm_subagent_register(Registry, Runtime, Parent, ChildCaps,
                                text("ctx"), Options, ok(_)),
          tool_invoke(Registry, ParentCaps, rlm_subagent,
                      json{query:"unknown"}, [], ok(Execution), _),
          Envelope = Execution.value,
          assertion(Envelope.status == failed),
          assertion(Envelope.error.kind == capability_denied),
          Envelope.correlation.child = Child,
          agent_status(Runtime, Child, ok(ChildStatus)),
          assertion(ChildStatus.capabilities == ChildCaps)
        ),
        ( tool_registry_destroy(Registry), agent_runtime_destroy(Runtime) )).

test(child_completion_uses_child_authority_context) :-
    Caps = [tool(rlm_subagent), tool(authority_probe),
            rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps),
                          authority(approve_diff)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( rlm_set_authority(Registry, dangerous, ok(_)),
          agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
          fixture_tool_schema(authority_probe, ProbeSchema),
          tool_register(Registry, ProbeSchema,
                        plunit_rlm_subagent:fixture_tool, ok(_)),
          Options = [planner_handler(plunit_rlm_subagent:tool_planner(
                                         authority_probe)),
                     capabilities(Caps),
                     child_capabilities([rlm, model(openrouter)]),
                     authority_context(Registry),
                     runtime_id(forged_runtime),
                     agent_id(forged_agent),
                     tool_registry(Registry)],
          ChildCaps = [tool(authority_probe), rlm, model(openrouter)],
          rlm_subagent_register(Registry, Runtime, Parent, ChildCaps,
                                text("ctx"), Options, ok(_)),
          tool_invoke(Registry, Caps, rlm_subagent,
                      json{query:"unknown"}, [], ok(Execution), _),
          Envelope = Execution.value,
          assertion(Envelope.status == completed),
          assertion(Envelope.value.authority == approve_diff),
          Child = Envelope.correlation.child,
          Runtime = agent_runtime(RuntimeId),
          Child = agent(ChildId),
          Correlation = correlation{trace_id:none,
                                    session_id:none,
                                    runtime_id:RuntimeId,
                                    agent_id:ChildId,
                                    graph_id:none,
                                    run_id:none},
          Operation = authority_operation{name:authority_probe,
                                          effect:read,
                                          capability:tool(authority_probe),
                                          args:json{},
                                          details:operation_details{},
                                          correlation:Correlation},
          rlm_operation_fingerprint(agent(RuntimeId, ChildId),
                                    Operation,
                                    ExpectedFingerprint),
          assertion(Envelope.value.fingerprint == ExpectedFingerprint),
          agent_status(Runtime, Child, ok(ChildStatus)),
          assertion(ChildStatus.authority == approve_diff)
        ),
        ( tool_registry_destroy(Registry), agent_runtime_destroy(Runtime) )).

test(unbounded_recursive_subagent_registration_fails_closed) :-
    Caps = [tool(rlm_subagent), rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
          subagent_options(Options),
          rlm_subagent_register(Registry, Runtime, Parent, Caps,
                                text("ctx"), Options, error(Error)),
          assertion(Error.kind == unbounded_recursive_delegation),
          tool_lookup(Registry, rlm_subagent, error(LookupError)),
          assertion(LookupError.kind == unknown_tool)
        ),
        ( tool_registry_destroy(Registry), agent_runtime_destroy(Runtime) )).

test(agent_limit_is_structured_before_child_execution) :-
    Caps = [tool(rlm_subagent), rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps), max_agents(1)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
          subagent_options(Options),
          rlm_subagent_register(Registry, Runtime, Parent,
                                [rlm, model(openrouter)], text("ctx"),
                                Options, ok(_)),
          tool_invoke(Registry, Caps, rlm_subagent,
                      json{query:"unknown"}, [], ok(Execution), _),
          Envelope = Execution.value,
          assertion(Envelope.status == failed),
          assertion(Envelope.error.kind == agent_limit_reached),
          assertion(Envelope.correlation.child == none)
        ),
        ( tool_registry_destroy(Registry), agent_runtime_destroy(Runtime) )).

test(child_completion_enforces_recursive_depth_budget) :-
    bounded_subagent(completion_test_support:depth_two_planner,
                     completion_budget{max_recursion_depth:1},
                     Envelope),
    assertion(Envelope.status == failed),
    assertion(Envelope.error.kind == recursive_plan_rejected),
    assertion(Envelope.error.detail = recursion_depth_exceeded(2, 1)).

test(child_completion_enforces_parallel_width_budget) :-
    bounded_subagent(plunit_rlm_subagent:parallel_planner,
                     completion_budget{max_concurrent_subcalls:1},
                     Envelope),
    assertion(Envelope.status == failed),
    assertion(Envelope.error.kind == budget_exceeded),
    assertion(Envelope.error.budget == parallel),
    assertion(Envelope.error.estimated =:= 2),
    assertion(Envelope.error.limit =:= 1).

test(child_completion_enforces_token_budget) :-
    bounded_subagent(completion_test_support:direct_planner,
                     completion_budget{max_total_tokens:1},
                     Envelope),
    assertion(Envelope.status == failed),
    assertion(Envelope.error.kind == token_budget_exceeded).

test(child_completion_enforces_wall_time_budget) :-
    bounded_subagent(plunit_rlm_subagent:slow_planner,
                     completion_budget{time_limit:0.02},
                     Envelope),
    assertion(Envelope.status == failed),
    assertion(Envelope.error.kind == timeout).

% Issue #175: task-deadline policy must be resolved before child spawn and the
% same effective task deadline must be observable through the canonical tool.
test(subagent_schema_exposes_optional_timeout_seconds) :-
    Caps = [tool(rlm_subagent), rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
          subagent_options(Options),
          rlm_subagent_register(Registry, Runtime, Parent,
                                [rlm, model(openrouter)], text("ctx"),
                                Options, ok(_)),
          tool_lookup(Registry, rlm_subagent, ok(Schema)),
          assertion(Schema.arguments.required == [query]),
          get_dict(timeout_seconds, Schema.arguments.properties, TimeoutSchema),
          assertion(TimeoutSchema.type == number)
        ),
        ( tool_registry_destroy(Registry), agent_runtime_destroy(Runtime) )).

test(outer_tool_limit_covers_host_maximum_plus_grace) :-
    Caps = [tool(rlm_subagent), rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
          subagent_options(Base),
          append(Base,
                 [subagent_timeout_default(0.2),
                  subagent_timeout_max(0.5),
                  subagent_timeout_grace(0.1)],
                 Options),
          rlm_subagent_register(Registry, Runtime, Parent,
                                [rlm, model(openrouter)], text("ctx"),
                                Options, ok(_)),
          tool_lookup(Registry, rlm_subagent, ok(Schema)),
          assertion(abs(Schema.limits.time_limit - 0.6) < 0.000001)
        ),
        ( tool_registry_destroy(Registry), agent_runtime_destroy(Runtime) )).

test(subagent_timeout_omitted_uses_host_default,
     [setup(completion_test_support:reset_calls)]) :-
    Caps = [tool(rlm_subagent), rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps), max_agents(3)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
          subagent_options(Base),
          append(Base,
                 [subagent_timeout_default(0.2),
                  subagent_timeout_max(0.5),
                  subagent_timeout_grace(0.1)],
                 Options),
          rlm_subagent_register(Registry, Runtime, Parent,
                                [rlm, model(openrouter)], text("ctx"),
                                Options, ok(_)),
          tool_invoke(Registry, Caps, rlm_subagent,
                      json{query:"unknown"}, [], ok(Execution), _),
          Envelope = Execution.value,
          assertion(Envelope.status == completed),
          assertion(Envelope.timeout.source == default),
          assertion(Envelope.timeout.requested_seconds == none),
          assertion(abs(Envelope.timeout.effective_seconds - 0.2) < 0.000001)
        ),
        ( tool_registry_destroy(Registry), agent_runtime_destroy(Runtime) )).

test(subagent_timeout_explicit_override_is_honored,
     [setup(completion_test_support:reset_calls)]) :-
    Caps = [tool(rlm_subagent), rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps), max_agents(3)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
          subagent_options(Base),
          append(Base,
                 [subagent_timeout_default(0.2),
                  subagent_timeout_max(0.5),
                  subagent_timeout_grace(0.1)],
                 Options),
          rlm_subagent_register(Registry, Runtime, Parent,
                                [rlm, model(openrouter)], text("ctx"),
                                Options, ok(_)),
          tool_invoke(Registry, Caps, rlm_subagent,
                      json{query:"unknown", timeout_seconds:0.4}, [],
                      ok(Execution), _),
          Envelope = Execution.value,
          assertion(Envelope.status == completed),
          assertion(Envelope.timeout.source == model_request),
          assertion(abs(Envelope.timeout.requested_seconds - 0.4) < 0.000001),
          assertion(abs(Envelope.timeout.effective_seconds - 0.4) < 0.000001)
        ),
        ( tool_registry_destroy(Registry), agent_runtime_destroy(Runtime) )).

test(subagent_timeout_above_host_max_is_rejected_before_spawn) :-
    Caps = [tool(rlm_subagent), rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps), max_agents(3)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
          subagent_options(Base),
          append(Base,
                 [subagent_timeout_default(0.2),
                  subagent_timeout_max(0.5),
                  subagent_timeout_grace(0.1)],
                 Options),
          rlm_subagent_register(Registry, Runtime, Parent,
                                [rlm, model(openrouter)], text("ctx"),
                                Options, ok(_)),
          agent_children(Runtime, Parent, Before),
          tool_invoke(Registry, Caps, rlm_subagent,
                      json{query:"unknown", timeout_seconds:0.6}, [],
                      ok(Execution), _),
          Envelope = Execution.value,
          assertion(Envelope.status == failed),
          assertion(Envelope.error.kind == timeout_exceeds_maximum),
          assertion(Envelope.correlation.child == none),
          agent_children(Runtime, Parent, After),
          assertion(Before == After)
        ),
        ( tool_registry_destroy(Registry), agent_runtime_destroy(Runtime) )).

:- end_tests(rlm_subagent).
