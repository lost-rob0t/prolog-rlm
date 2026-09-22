:- begin_tests(rlm_expert).

:- meta_predicate with_registry(1).

:- use_module(library(yall)).
:- use_module('../prolog/rlm_expert').

echo_handler(echo(Value), _Context, succeeded(Value, [local_symbolic])).

child_handler(child(Value), _Context, succeeded(Value, [child_symbolic])).

parent_handler(parent(Value), Context, succeeded(ChildOutcome, [delegated])) :-
    Registry = Context.expert_registry,
    expert_call(Registry, child(Value), Context, ChildOutcome).

cycle_handler(loop(Value), Context, succeeded(ChildOutcome, [cycle_observed])) :-
    Registry = Context.expert_registry,
    expert_call(Registry, loop(Value), Context, ChildOutcome).

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

with_registry(Goal) :-
    expert_registry_create([], Registry),
    setup_call_cleanup(true,
                       call(Goal, Registry),
                       expert_registry_destroy(Registry)).

test(register_select_and_invoke_are_provider_free) :-
    with_registry(
        [Registry]>>(
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
            assertion(Outcome.usage.cost =:= 0)
        )).

test(symbolic_applicability_changes_selection_without_model) :-
    with_registry(
        [Registry]>>(
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
            assertion(Decision.score =:= 10)
        )).

test(nested_experts_share_runtime_and_stay_zero_model) :-
    with_registry(
        [Registry]>>(
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
            assertion(Events \== [])
        )).

test(parent_depth_limit_remains_shared_ceiling_for_children) :-
    with_registry(
        [Registry]>>(
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
            assertion(ChildOutcome.usage.model_calls =:= 0)
        )).

test(parent_invocation_limit_remains_shared_ceiling_for_children) :-
    with_registry(
        [Registry]>>(
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
            assertion(ChildOutcome.usage.model_calls =:= 0)
        )).

test(recursion_cycle_is_structurally_blocked) :-
    with_registry(
        [Registry]>>(
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
            assertion(Nested.reason = recursion_cycle(_))
        )).

test(plan_native_operations_are_not_experts) :-
    with_registry(
        [Registry]>>(
            contract(native_bad,
                     [run/1],
                     plunit_rlm_expert:echo_handler,
                     0,
                     never,
                     Contract),
            expert_register(Registry, Contract, Outcome),
            assertion(Outcome.status == error),
            assertion(Outcome.error == plan_native_excluded(run/1))
        )).

test(catalog_never_exposes_callable_handlers) :-
    with_registry(
        [Registry]>>(
            contract(echo_expert,
                     [echo/1],
                     plunit_rlm_expert:echo_handler,
                     0,
                     never,
                     Contract),
            expert_register(Registry, Contract, ok(_)),
            expert_catalog(Registry, [Descriptor]),
            assertion(Descriptor.handler == trusted_host),
            assertion(Descriptor.applicability == trusted_host)
        )).

:- end_tests(rlm_expert).
