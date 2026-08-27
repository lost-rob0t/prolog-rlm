:- begin_tests(rlm_subagent_deadline).

:- use_module('../prolog/rlm_agent').
:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_subagent').
:- use_module('../prolog/rlm_tool').
:- use_module('support/completion_test_support').

slow_deadline_planner(_, ok(Output)) :-
    sleep(1),
    Output = planner_output{
                 plan:plan([final(literal(unreachable))]),
                 usage:_{prompt_tokens:1,
                         completion_tokens:1,
                         total_tokens:2,
                         cost:0.0}}.

acceptance_fixture(Planner, HostOptions, Runtime, Registry, Parent, Caps) :-
    Caps = [tool(rlm_subagent), rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps), max_agents(3)], Runtime),
    tool_registry_create(Registry),
    agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
    Base = [planner_handler(Planner),
            capabilities([rlm, model(openrouter)]),
            child_capabilities([rlm, model(openrouter)])],
    append(Base, HostOptions, Options),
    rlm_subagent_register(Registry,
                          Runtime,
                          Parent,
                          [rlm, model(openrouter)],
                          text("deadline acceptance"),
                          Options,
                          ok(_)).

cleanup_fixture(Runtime, Registry) :-
    tool_registry_destroy(Registry),
    agent_runtime_destroy(Runtime).

assert_timeout_policy_rejected_without_spawn(Timeout) :-
    acceptance_fixture(completion_test_support:direct_planner,
                       [subagent_timeout_default(0.2),
                        subagent_timeout_max(0.5),
                        subagent_timeout_grace(0.1)],
                       Runtime,
                       Registry,
                       Parent,
                       Caps),
    setup_call_cleanup(
        true,
        ( agent_children(Runtime, Parent, Before),
          tool_invoke(Registry, Caps, rlm_subagent,
                      json{query:"unknown", timeout_seconds:Timeout}, [],
                      ok(Execution), Trace),
          assertion(Trace.status == ok),
          Envelope = Execution.value,
          assertion(Envelope.status == failed),
          assertion(Envelope.error.phase == timeout_policy),
          assertion(Envelope.error.kind == invalid_timeout),
          assertion(Envelope.error.requested =:= Timeout),
          assertion(Envelope.correlation.child == none),
          agent_children(Runtime, Parent, After),
          assertion(After == Before)
        ),
        cleanup_fixture(Runtime, Registry)).

assert_schema_rejected_without_spawn(Args) :-
    acceptance_fixture(completion_test_support:direct_planner,
                       [subagent_timeout_default(0.2),
                        subagent_timeout_max(0.5),
                        subagent_timeout_grace(0.1)],
                       Runtime,
                       Registry,
                       Parent,
                       Caps),
    setup_call_cleanup(
        true,
        ( agent_children(Runtime, Parent, Before),
          tool_invoke(Registry, Caps, rlm_subagent,
                      Args, [], Outcome, Trace),
          assertion(Outcome = error(_)),
          assertion(Trace.status == malformed_args),
          agent_children(Runtime, Parent, After),
          assertion(After == Before)
        ),
        cleanup_fixture(Runtime, Registry)).

test(subagent_timeout_zero_is_rejected_before_spawn) :-
    assert_schema_rejected_without_spawn(
        json{query:"unknown", timeout_seconds:0}).

test(subagent_timeout_negative_is_rejected_before_spawn) :-
    assert_schema_rejected_without_spawn(
        json{query:"unknown", timeout_seconds:(-0.1)}).

test(subagent_timeout_non_number_is_schema_rejected) :-
    assert_schema_rejected_without_spawn(
        json{query:"unknown", timeout_seconds:"forever"}).

test(timeout_policy_is_host_owned) :-
    assert_schema_rejected_without_spawn(
        json{query:"unknown", subagent_timeout_max:999}).

test(subagent_timeout_does_not_replace_other_completion_budget_fields) :-
    Budget0 = completion_budget{
                  time_limit:9.0,
                  max_total_tokens:17,
                  max_model_calls:3,
                  max_recursion_depth:2,
                  max_concurrent_subcalls:4,
                  max_context_ops:5,
                  max_tool_calls:6,
                  max_output_bytes:7000},
    rlm_subagent:subagent_completion_options(
        [budget(Budget0)],
        0.25,
        ok(Options)),
    member(budget(Budget), Options),
    assertion(abs(Budget.time_limit - 0.25) < 0.000001),
    assertion(Budget.max_total_tokens =:= 17),
    assertion(Budget.max_model_calls =:= 3),
    assertion(Budget.max_recursion_depth =:= 2),
    assertion(Budget.max_concurrent_subcalls =:= 4),
    assertion(Budget.max_context_ops =:= 5),
    assertion(Budget.max_tool_calls =:= 6),
    assertion(Budget.max_output_bytes =:= 7000).

test(subagent_completion_timeout_returns_structured_failed_envelope) :-
    acceptance_fixture(plunit_rlm_subagent_deadline:slow_deadline_planner,
                       [subagent_timeout_default(0.02),
                        subagent_timeout_max(0.1),
                        subagent_timeout_grace(0.05)],
                       Runtime,
                       Registry,
                       _Parent,
                       Caps),
    setup_call_cleanup(
        true,
        ( tool_invoke(Registry, Caps, rlm_subagent,
                      json{query:"unknown"}, [], ok(Execution), _),
          Envelope = Execution.value,
          assertion(Envelope.status == failed),
          assertion(Envelope.error.kind == timeout),
          assertion(Envelope.timeout.source == default),
          assertion(abs(Envelope.timeout.effective_seconds - 0.02) < 0.000001),
          Envelope.correlation.child = Child,
          assertion(Child \== none),
          agent_status(Runtime, Child, ok(Status)),
          assertion(Status.status \== running)
        ),
        cleanup_fixture(Runtime, Registry)).

test(timeout_request_does_not_widen_capabilities) :-
    ParentCaps = [tool(rlm_subagent), tool(secret_fixture),
                  rlm, model(openrouter)],
    ChildCaps = [rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(ParentCaps), max_agents(3)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( agent_spawn(Runtime, none, agent_spec(parent), ParentCaps, ok(Parent)),
          Options = [planner_handler(completion_test_support:direct_planner),
                     capabilities(ParentCaps),
                     child_capabilities(ChildCaps),
                     subagent_timeout_default(0.2),
                     subagent_timeout_max(0.5)],
          rlm_subagent_register(Registry, Runtime, Parent, ChildCaps,
                                text("deadline acceptance"), Options, ok(_)),
          tool_invoke(Registry, ParentCaps, rlm_subagent,
                      json{query:"unknown", timeout_seconds:0.4}, [],
                      ok(Execution), _),
          Envelope = Execution.value,
          assertion(Envelope.status == completed),
          Child = Envelope.correlation.child,
          agent_status(Runtime, Child, ok(ChildStatus)),
          assertion(ChildStatus.capabilities == ChildCaps)
        ),
        cleanup_fixture(Runtime, Registry)).

test(sync_tool_timeout_does_not_depend_on_future_await_timeout) :-
    acceptance_fixture(completion_test_support:direct_planner,
                       [subagent_timeout_default(0.2),
                        subagent_timeout_max(0.5)],
                       Runtime,
                       Registry,
                       _Parent,
                       Caps),
    setup_call_cleanup(
        tool_invoke_async(Registry, Caps, rlm_subagent,
                          json{query:"unknown", timeout_seconds:0.2}, [], Future),
        ( rlm_future_await(Future, 0.000001, WaitOutcome),
          WaitOutcome = error(WaitError),
          assertion(WaitError.kind == timeout),
          rlm_future_await(Future, 1.0, FinalOutcome),
          FinalOutcome = tool_async_result{outcome:ok(Execution), trace:_},
          assertion(Execution.value.status == completed),
          assertion(abs(Execution.value.timeout.effective_seconds - 0.2) < 0.000001)
        ),
        ( rlm_future_destroy(Future),
          cleanup_fixture(Runtime, Registry)
        )).

:- end_tests(rlm_subagent_deadline).
