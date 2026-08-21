:- begin_tests(rlm_subagent).

:- use_module('../prolog/rlm_agent').
:- use_module('../prolog/rlm_subagent').
:- use_module('../prolog/rlm_tool').
:- use_module('support/completion_test_support').

subagent_options([planner_handler(completion_test_support:direct_planner),
                  capabilities([rlm, model(openrouter)]),
                  child_capabilities([rlm, model(openrouter)])]).

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
    tool_invoke(Registry, [tool(rlm_subagent)], rlm_subagent,
                json{query:"Need evidence."}, [], ok(Execution), Trace),
    Envelope = Execution.value,
    assertion(Trace.authorization == allowed),
    assertion(Envelope.status == completed),
    assertion(Envelope.value == "direct-ok"),
    assertion(Envelope.correlation.parent == Parent),
    Envelope.correlation.child = agent(_),
    assertion(Envelope.usage.model_calls =:= 1),
    agent_children(Runtime, Parent, Children),
    assertion(Children == [Envelope.correlation.child]).

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
