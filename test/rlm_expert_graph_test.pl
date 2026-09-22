:- begin_tests(rlm_expert_graph).

:- use_module('../prolog/rlm_expert').
:- use_module('../prolog/rlm_expert_graph').
:- use_module('../prolog/rlm_agent').

echo_handler(echo(Value), _Context, succeeded(Value, [symbolic])).

flow_worker(work(echo, Value), Value).

expert_contract(Contract) :-
    Contract = expert_contract{
                   id:echo_expert,
                   version:'1',
                   accepts:[echo/1],
                   produces:result,
                   specialties:[test],
                   applicability:none,
                   priority:10,
                   requires:[],
                   observations:[],
                   effects:[],
                   fallback:none,
                   child_policy:never,
                   limits:expert_limits{max_depth:4,
                                        max_invocations:16},
                   handler:plunit_rlm_expert_graph:echo_handler
               }.

flow_spec(
    graph(expert_agent_flow,
          [ field(expert_result, any, none, replace),
            field(agent_result, any, none, replace)
          ],
          [ node(expert_step, expert_handler),
            node(agent_step, agent_handler)
          ],
          [ edge(start, expert_step),
            edge(expert_step, agent_step),
            edge(agent_step, end)
          ])).

test(flow_graph_runs_symbolic_expert_and_supervised_agent_in_one_scheduler) :-
    expert_registry_create([], ExpertRegistry),
    agent_runtime_create([worker_count(1)], AgentRuntime),
    setup_call_cleanup(
        true,
        flow_graph_case(ExpertRegistry, AgentRuntime),
        ( agent_runtime_destroy(AgentRuntime),
          expert_registry_destroy(ExpertRegistry)
        )).

flow_graph_case(ExpertRegistry, AgentRuntime) :-
    expert_contract(Contract),
    expert_register(ExpertRegistry, Contract, ok(_)),
    agent_spawn(AgentRuntime,
                none,
                agent_spec(flow_worker),
                [],
                ok(Agent)),
    flow_spec(Spec),
    Bindings = [
        expert_id(expert_handler,
                  ExpertRegistry,
                  echo_expert,
                  literal(echo(symbolic_value)),
                  literal(_{capabilities:[]}),
                  expert_result),
        agent(agent_handler,
              AgentRuntime,
              Agent,
              plunit_rlm_expert_graph:flow_worker,
              literal(work(echo, agent_value)),
              agent_result)
    ],
    flow_graph_compile(Spec, Bindings, [], ok(Compiled)),
    flow_graph_run(Compiled, _{}, [], ok(Result)),
    assertion(Result.status == completed),
    ExpertOutcome = Result.state.expert_result,
    assertion(ExpertOutcome.status == succeeded),
    assertion(ExpertOutcome.result == symbolic_value),
    assertion(ExpertOutcome.usage.model_calls =:= 0),
    assertion(Result.state.agent_result == ok(agent_value)).

test(flow_binding_rejects_untrusted_value_spec) :-
    flow_spec(Spec),
    flow_graph_compile(
        Spec,
        [expert(expert_handler,
                fake_registry,
                callable(goal),
                literal(_{capabilities:[]}),
                expert_result)],
        [],
        Outcome),
    Outcome = error(Error),
    assertion(Error.kind == invalid_binding),
    assertion(Error.detail == invalid_value_spec(callable(goal))).

:- end_tests(rlm_expert_graph).
