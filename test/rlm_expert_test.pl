:- begin_tests(rlm_expert).

:- use_module('../prolog/rlm_expert').

:- dynamic stale_child_dispatches/1.

echo_handler(echo(Value), _Context, succeeded(Value, [local_symbolic])).

child_handler(child(Value), _Context, succeeded(Value, [child_symbolic])).

stale_counting_child_handler(child(Value),
                             _Context,
                             succeeded(Value, [child_symbolic])) :-
    retract(stale_child_dispatches(Count0)),
    Count is Count0+1,
    assertz(stale_child_dispatches(Count)).

parent_handler(parent(Value), Context, succeeded(ChildOutcome, [delegated])) :-
    Registry = Context.expert_registry,
    expert_call(Registry, child(Value), Context, ChildOutcome).

stale_parent_handler(parent(Value),
                     Context,
                     succeeded(ChildOutcome, [delegated])) :-
    Registry = Context.expert_registry,
    contract(nested_generation_bump,
             [nested_generation_bump/0],
             plunit_rlm_expert:echo_handler,
             0,
             never,
             Bump),
    expert_register(Registry, Bump, ok(_)),
    expert_call(Registry, child(Value), Context, ChildOutcome).

cycle_handler(loop(Value), Context, succeeded(ChildOutcome, [cycle_observed])) :-
    Registry = Context.expert_registry,
    expert_call(Registry, loop(Value), Context, ChildOutcome).

stale_generation_handler(echo(Value), Context, succeeded(Value, [stale_generation])) :-
    Registry = Context.expert_registry,
    contract(generation_bump,
             [generation_bump/0],
             plunit_rlm_expert:echo_handler,
             0,
             never,
             Bump),
    expert_register(Registry, Bump, ok(_)).

specific_applicability(echo(special), _Context, applicable(10, exact_special)).
specific_applicability(echo(_), _Context, not_applicable(not_special)).

contract(Id, Accepts, Handler, Priority, ChildPolicy, Contract) :-
    Contract = expert_contract{
                   id:Id,
                   version:'1',
                   accepts:Accepts,
                   produces:result,
                   specialties:[test],
                   applicability:none,
                   priority:Priority,
                   requires:[],
                   observations:[],
                   effects:[],
                   fallback:none,
                   child_policy:ChildPolicy,
                   limits:expert_limits{max_depth:8,
                                        max_invocations:32},
                   handler:Handler
               }.

with_limits(Contract0, MaxDepth, MaxInvocations, Contract) :-
    put_dict(limits,
             Contract0,
             expert_limits{max_depth:MaxDepth,
                           max_invocations:MaxInvocations},
             Contract).

with_registry(Case) :-
    expert_registry_create([], Registry),
    setup_call_cleanup(true,
                       call(Case, Registry),
                       expert_registry_destroy(Registry)).

register_select_and_invoke_case(Registry) :-
    contract(echo_low,
             [echo/1],
             plunit_rlm_expert:echo_handler,
             1,
             never,
             Low),
    contract(echo_high,
             [echo/1],
             plunit_rlm_expert:echo_handler,
             5,
             never,
             High),
    expert_register(Registry, Low, ok(_)),
    expert_register(Registry, High, ok(_)),
    expert_select(Registry,
                  echo(hello),
                  _{capabilities:[]},
                  Decision),
    assertion(Decision.status == selected),
    assertion(Decision.expert_id == echo_high),
    expert_call(Registry,
                echo(hello),
                _{capabilities:[]},
                Outcome),
    assertion(Outcome.status == succeeded),
    assertion(Outcome.result == hello),
    assertion(Outcome.usage.model_calls =:= 0),
    assertion(Outcome.usage.cost =:= 0).

test(register_select_and_invoke_are_provider_free) :-
    with_registry(register_select_and_invoke_case).

symbolic_applicability_case(Registry) :-
    contract(generic,
             [echo/1],
             plunit_rlm_expert:echo_handler,
             5,
             never,
             Generic),
    contract(special,
             [echo/1],
             plunit_rlm_expert:echo_handler,
             0,
             never,
             Special0),
    put_dict(applicability,
             Special0,
             plunit_rlm_expert:specific_applicability,
             Special),
    expert_register(Registry, Generic, ok(_)),
    expert_register(Registry, Special, ok(_)),
    expert_select(Registry,
                  echo(special),
                  _{capabilities:[]},
                  Decision),
    assertion(Decision.expert_id == special),
    assertion(Decision.score =:= 10).

test(symbolic_applicability_changes_selection_without_model) :-
    with_registry(symbolic_applicability_case).

nested_experts_case(Registry) :-
    contract(child_expert,
             [child/1],
             plunit_rlm_expert:child_handler,
             10,
             never,
             Child),
    contract(parent_expert,
             [parent/1],
             plunit_rlm_expert:parent_handler,
             10,
             children,
             Parent),
    expert_register(Registry, Child, ok(_)),
    expert_register(Registry, Parent, ok(_)),
    expert_call(Registry,
                parent(payload),
                _{capabilities:[]},
                ParentOutcome),
    assertion(ParentOutcome.status == succeeded),
    ChildOutcome = ParentOutcome.result,
    assertion(ChildOutcome.status == succeeded),
    assertion(ChildOutcome.result == payload),
    assertion(ChildOutcome.usage.model_calls =:= 0),
    expert_invocations(Registry, Events),
    assertion(Events \== []).

test(nested_experts_share_runtime_and_stay_zero_model) :-
    with_registry(nested_experts_case).

parent_depth_limit_case(Registry) :-
    contract(child_expert,
             [child/1],
             plunit_rlm_expert:child_handler,
             10,
             never,
             Child),
    contract(parent_expert,
             [parent/1],
             plunit_rlm_expert:parent_handler,
             10,
             children,
             Parent0),
    with_limits(Parent0, 1, 32, Parent),
    expert_register(Registry, Child, ok(_)),
    expert_register(Registry, Parent, ok(_)),
    expert_call(Registry,
                parent(payload),
                _{capabilities:[]},
                ParentOutcome),
    assertion(ParentOutcome.status == succeeded),
    ChildOutcome = ParentOutcome.result,
    assertion(ChildOutcome.status == error),
    assertion(ChildOutcome.error == depth_exceeded(2, 1)),
    assertion(ChildOutcome.usage.model_calls =:= 0).

test(parent_depth_limit_remains_shared_ceiling_for_children) :-
    with_registry(parent_depth_limit_case).

parent_invocation_limit_case(Registry) :-
    contract(child_expert,
             [child/1],
             plunit_rlm_expert:child_handler,
             10,
             never,
             Child),
    contract(parent_expert,
             [parent/1],
             plunit_rlm_expert:parent_handler,
             10,
             children,
             Parent0),
    with_limits(Parent0, 8, 1, Parent),
    expert_register(Registry, Child, ok(_)),
    expert_register(Registry, Parent, ok(_)),
    expert_call(Registry,
                parent(payload),
                _{capabilities:[]},
                ParentOutcome),
    assertion(ParentOutcome.status == succeeded),
    ChildOutcome = ParentOutcome.result,
    assertion(ChildOutcome.status == error),
    assertion(ChildOutcome.error == invocation_budget_exceeded(2, 1)),
    assertion(ChildOutcome.usage.model_calls =:= 0).

test(parent_invocation_limit_remains_shared_ceiling_for_children) :-
    with_registry(parent_invocation_limit_case).

stale_generation_result_case(Registry) :-
    contract(stale_expert,
             [echo/1],
             plunit_rlm_expert:stale_generation_handler,
             10,
             never,
             Contract),
    expert_register(Registry, Contract, ok(_)),
    expert_registry_generation(Registry, StartedGeneration),
    expert_call(Registry,
                echo(payload),
                _{capabilities:[]},
                Outcome),
    expert_registry_generation(Registry, CurrentGeneration),
    assertion(CurrentGeneration > StartedGeneration),
    assertion(Outcome.status == blocked),
    assertion(Outcome.reason == stale_registry_generation(StartedGeneration,
                                                           CurrentGeneration)),
    assertion(Outcome.usage.model_calls =:= 0).

test(result_is_rejected_when_registry_generation_changes_during_handler) :-
    with_registry(stale_generation_result_case).

stale_generation_nested_admission_case(Registry) :-
    contract(child_expert,
             [child/1],
             plunit_rlm_expert:stale_counting_child_handler,
             10,
             never,
             Child),
    contract(parent_expert,
             [parent/1],
             plunit_rlm_expert:stale_parent_handler,
             10,
             children,
             Parent),
    expert_register(Registry, Child, ok(_)),
    expert_register(Registry, Parent, ok(_)),
    retractall(stale_child_dispatches(_)),
    assertz(stale_child_dispatches(0)),
    setup_call_cleanup(
        true,
        ( expert_registry_generation(Registry, StartedGeneration),
          expert_call(Registry,
                      parent(payload),
                      _{capabilities:[]},
                      Outcome),
          expert_registry_generation(Registry, CurrentGeneration),
          assertion(CurrentGeneration > StartedGeneration),
          assertion(Outcome.status == blocked),
          assertion(Outcome.reason == stale_registry_generation(StartedGeneration,
                                                                 CurrentGeneration)),
          assertion(Outcome.usage.model_calls =:= 0),
          stale_child_dispatches(Dispatches),
          assertion(Dispatches =:= 0)
        ),
        retractall(stale_child_dispatches(_))).

test(stale_parent_generation_blocks_child_before_dispatch) :-
    with_registry(stale_generation_nested_admission_case).

recursion_cycle_case(Registry) :-
    contract(loop_expert,
             [loop/1],
             plunit_rlm_expert:cycle_handler,
             10,
             children,
             Contract),
    expert_register(Registry, Contract, ok(_)),
    expert_call(Registry,
                loop(value),
                _{capabilities:[]},
                Outcome),
    assertion(Outcome.status == succeeded),
    Nested = Outcome.result,
    assertion(Nested.status == blocked),
    assertion(Nested.reason = recursion_cycle(_)).

test(recursion_cycle_is_structurally_blocked) :-
    with_registry(recursion_cycle_case).

plan_native_case(Registry) :-
    contract(native_bad,
             [run/1],
             plunit_rlm_expert:echo_handler,
             0,
             never,
             Contract),
    expert_register(Registry, Contract, Outcome),
    assertion(Outcome.status == error),
    assertion(Outcome.error == plan_native_excluded(run/1)).

test(plan_native_operations_are_not_experts) :-
    with_registry(plan_native_case).

catalog_case(Registry) :-
    contract(echo_expert,
             [echo/1],
             plunit_rlm_expert:echo_handler,
             0,
             never,
             Contract),
    expert_register(Registry, Contract, ok(_)),
    expert_catalog(Registry, [Descriptor]),
    assertion(Descriptor.handler == trusted_host),
    assertion(Descriptor.applicability == trusted_host).

test(catalog_never_exposes_callable_handlers) :-
    with_registry(catalog_case).

:- end_tests(rlm_expert).
