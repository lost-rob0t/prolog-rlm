:- module(rlm_expert_graph,
          [ rlm_expert_graph_ready/0,
            flow_registry/2,
            flow_graph_compile/4,
            flow_graph_run/4
          ]).

/** <module> Expert/agent/strange-loop nodes for canonical RLM graphs

This module does not implement a scheduler. It projects expert calls,
supervised logical-agent work and declarative strange-loop runs into the
existing rlm_graph trusted handler registry.

A flow specification is therefore an ordinary rlm_graph graph/4 value. Trusted
host bindings resolve node refs to closures. Graph state remains inert data and
can feed later nodes via state(Key) value specs.
*/

:- use_module(library(lists), [member/2]).
:- use_module(rlm_graph,
              [ graph_compile/4,
                graph_run/4
              ]).
:- use_module(rlm_expert,
              [ expert_call/4,
                expert_invoke/5
              ]).
:- use_module(rlm_agent,
              [ agent_supervised_call/6
              ]).
:- use_module(rlm_strange_loop,
              [ strange_loop_run/4
              ]).

rlm_expert_graph_ready.

/*
Bindings are trusted host configuration:

  expert(Ref, Registry, GoalSpec, ContextSpec, ResultKey)
  expert_id(Ref, Registry, ExpertId, GoalSpec, ContextSpec, ResultKey)
  agent(Ref, Runtime, Agent, Handler, WorkSpec, ResultKey)
  strange_loop(Ref, SnapshotSpec, Hooks, LoopOptions, ResultKey)
  router(Ref, Handler)
  subgraph(Ref, CompiledGraph)

Value specs are literal(Value) or state(Key). They never become callables.
*/

flow_registry(Bindings0, Registry) :-
    must_be_list(Bindings0, bindings),
    maplist(binding_registry_entry, Bindings0, Registry).

flow_graph_compile(Spec, Bindings, Options, Outcome) :-
    catch(( flow_registry(Bindings, Registry),
            graph_compile(Spec, Registry, Options, Outcome)
          ),
          Exception,
          flow_exception(compile, Exception, Outcome)).

flow_graph_run(Compiled, InitialState, Options, Outcome) :-
    graph_run(Compiled, InitialState, Options, Outcome).

binding_registry_entry(
    expert(Ref, Registry, GoalSpec, ContextSpec, ResultKey),
    handler(Ref,
            rlm_expert_graph:expert_auto_node(Registry,
                                              GoalSpec,
                                              ContextSpec,
                                              ResultKey))) :-
    require_id(Ref, binding_ref),
    require_value_spec(GoalSpec),
    require_context_spec(ContextSpec),
    require_id(ResultKey, result_key),
    !.
binding_registry_entry(
    expert_id(Ref,
              Registry,
              ExpertId,
              GoalSpec,
              ContextSpec,
              ResultKey),
    handler(Ref,
            rlm_expert_graph:expert_id_node(Registry,
                                            ExpertId,
                                            GoalSpec,
                                            ContextSpec,
                                            ResultKey))) :-
    require_id(Ref, binding_ref),
    require_id(ExpertId, expert_id),
    require_value_spec(GoalSpec),
    require_context_spec(ContextSpec),
    require_id(ResultKey, result_key),
    !.
binding_registry_entry(
    agent(Ref, Runtime, Agent, Handler, WorkSpec, ResultKey),
    handler(Ref,
            rlm_expert_graph:agent_node(Runtime,
                                        Agent,
                                        Handler,
                                        WorkSpec,
                                        ResultKey))) :-
    require_id(Ref, binding_ref),
    callable(Handler),
    require_value_spec(WorkSpec),
    require_id(ResultKey, result_key),
    !.
binding_registry_entry(
    strange_loop(Ref, SnapshotSpec, Hooks, LoopOptions, ResultKey),
    handler(Ref,
            rlm_expert_graph:strange_loop_node(SnapshotSpec,
                                               Hooks,
                                               LoopOptions,
                                               ResultKey))) :-
    require_id(Ref, binding_ref),
    require_value_spec(SnapshotSpec),
    is_dict(Hooks),
    require_id(ResultKey, result_key),
    !.
binding_registry_entry(router(Ref, Handler), router(Ref, Handler)) :-
    require_id(Ref, binding_ref),
    callable(Handler),
    !.
binding_registry_entry(subgraph(Ref, Compiled), subgraph(Ref, Compiled)) :-
    require_id(Ref, binding_ref),
    !.
binding_registry_entry(Binding, _) :-
    throw(flow_fault(invalid_binding(Binding))).

expert_auto_node(Registry,
                 GoalSpec,
                 ContextSpec,
                 ResultKey,
                 State,
                 _GraphContext,
                 update(Patch)) :-
    resolve_value_spec(GoalSpec, State, Goal),
    resolve_context_spec(ContextSpec, State, Context),
    expert_call(Registry, Goal, Context, Outcome),
    singleton_patch(ResultKey, Outcome, Patch).

expert_id_node(Registry,
               ExpertId,
               GoalSpec,
               ContextSpec,
               ResultKey,
               State,
               _GraphContext,
               update(Patch)) :-
    resolve_value_spec(GoalSpec, State, Goal),
    resolve_context_spec(ContextSpec, State, Context),
    expert_invoke(Registry, ExpertId, Goal, Context, Outcome),
    singleton_patch(ResultKey, Outcome, Patch).

agent_node(Runtime,
           Agent,
           Handler,
           WorkSpec,
           ResultKey,
           State,
           _GraphContext,
           update(Patch)) :-
    resolve_value_spec(WorkSpec, State, Work),
    agent_supervised_call(Runtime,
                          Agent,
                          Handler,
                          Work,
                          [],
                          Outcome),
    singleton_patch(ResultKey, Outcome, Patch).

strange_loop_node(SnapshotSpec,
                  Hooks,
                  LoopOptions,
                  ResultKey,
                  State,
                  _GraphContext,
                  update(Patch)) :-
    resolve_value_spec(SnapshotSpec, State, Snapshot),
    strange_loop_run(Snapshot, Hooks, LoopOptions, Outcome),
    singleton_patch(ResultKey, Outcome, Patch).

require_value_spec(literal(Value)) :-
    safe_data(Value),
    !.
require_value_spec(state(Key)) :-
    require_id(Key, state_key),
    !.
require_value_spec(Spec) :-
    throw(flow_fault(invalid_value_spec(Spec))).

resolve_value_spec(literal(Value), _, Value).
resolve_value_spec(state(Key), State, Value) :-
    (   get_dict(Key, State, Value)
    ->  true
    ;   throw(flow_fault(missing_state_value(Key)))
    ).

require_context_spec(literal(Context)) :-
    is_dict(Context),
    safe_data(Context),
    !.
require_context_spec(state(Key)) :-
    require_id(Key, state_key),
    !.
require_context_spec(Spec) :-
    throw(flow_fault(invalid_context_spec(Spec))).

resolve_context_spec(literal(Context), _, Context).
resolve_context_spec(state(Key), State, Context) :-
    (   get_dict(Key, State, Context),
        is_dict(Context)
    ->  true
    ;   throw(flow_fault(missing_or_invalid_context(Key)))
    ).

singleton_patch(Key, Value, Patch) :-
    put_dict(Key, graph_patch{}, Value, Patch).

must_be_list(Value, _) :-
    is_list(Value),
    !.
must_be_list(Value, Label) :-
    throw(flow_fault(expected_list(Label, Value))).

require_id(Value, _) :-
    atom(Value),
    Value \== '',
    !.
require_id(Value, Label) :-
    throw(flow_fault(invalid_id(Label, Value))).

safe_data(Value) :-
    ground(Value),
    acyclic_term(Value),
    (   atomic(Value)
    ->  true
    ;   is_list(Value)
    ->  forall(member(Item, Value), safe_data(Item))
    ;   is_dict(Value)
    ->  dict_pairs(Value, _, Pairs),
        forall(member(Key-Item, Pairs),
               (atom(Key), safe_data(Item)))
    ;   compound(Value),
        Value =.. [_|Args],
        forall(member(Arg, Args), safe_data(Arg))
    ).

flow_exception(_Phase,
               flow_fault(Fault),
               error(flow_graph_error{kind:invalid_binding,
                                      detail:Fault})) :-
    !.
flow_exception(Phase,
               Exception,
               error(flow_graph_error{kind:exception,
                                      phase:Phase,
                                      detail:Safe})) :-
    (   safe_data(Exception)
    ->  Safe = Exception
    ;   term_string(Exception,
                    Safe,
                    [quoted(true), max_depth(8)])
    ).
