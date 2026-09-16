:- module(rlm_expert,
          [ expert_registry_create/1,
            expert_registry_destroy/1,
            expert_register/3,
            expert_catalog/2,
            expert_select/4,
            expert_invoke/5,
            expert_call/4,
            rlm_expert_ready/0
          ]).

/** <module> Trusted symbolic expert registry, selection, and local invocation

This first expert substrate is intentionally local. Trusted host code registers
handlers; goal and context are inert data. Selection never invokes a provider.
An expert handler has the signature Handler(+Goal,+Context,-Value). Handlers
must be fully module-qualified and registered by trusted host code. A handler
that needs an effect must call the existing typed capability/authority/effect
boundary itself; registration does not grant authority.

The registry does not yet project into plan/direct mode or implement nested
invocation lineage. Those callers must not treat this local result as a final
verification receipt.
*/

:- use_module(library(uuid)).
:- use_module(library(lists)).
:- use_module(library(time)).
:- use_module(rlm_plan_graph, [plan_native_op/1]).
:- use_module(rlm_tool, [capabilities_normalize/2]).

:- dynamic registry_alive/1.
:- dynamic registry_entry/3.

rlm_expert_ready.

expert_registry_create(expert_registry(Id)) :-
    uuid(Id),
    with_mutex(rlm_expert_registry, assertz(registry_alive(Id))).

expert_registry_destroy(expert_registry(Id)) :-
    with_mutex(rlm_expert_registry,
               ( retractall(registry_entry(Id, _, _)),
                 retractall(registry_alive(Id)) )).

expert_register(Registry, Contract, Outcome) :-
    catch(register_checked(Registry, Contract, Outcome),
          expert_fault(Kind, Detail),
          Outcome = error(expert_error{kind:Kind, detail:Detail})).

register_checked(Registry, Contract, Outcome) :-
    registry_id(Registry, RegistryId),
    contract_checked(Contract),
    Contract.id = ExpertId,
    with_mutex(rlm_expert_registry,
               (   registry_entry(RegistryId, ExpertId, _)
               ->  Outcome = error(expert_error{kind:duplicate_expert,
                                                detail:ExpertId})
               ;   assertz(registry_entry(RegistryId, ExpertId, Contract)),
                   Outcome = ok(ExpertId)
               )).

contract_checked(Contract) :-
    ( is_dict(Contract, expert_contract),
      get_dict(id, Contract, Id), atom(Id),
      get_dict(version, Contract, Version), ground(Version),
      get_dict(goal, Contract, Goal), ground(Goal), Goal = Op/Arity,
      atom(Op), integer(Arity), Arity >= 0,
      get_dict(priority, Contract, Priority), integer(Priority),
      get_dict(requires, Contract, Requires),
      capabilities_normalize(Requires, ok(_)),
      get_dict(handler, Contract, Handler),
      Handler = Module:Callable, atom(Module), callable(Callable)
    -> true
    ;  throw(expert_fault(invalid_contract, Contract))
    ),
    ( plan_native_op(Goal)
    -> throw(expert_fault(plan_native_excluded, Goal))
    ;  true
    ).

expert_catalog(Registry, Catalog) :-
    registry_id(Registry, Id),
    with_mutex(rlm_expert_registry,
               findall(ExpertId-Metadata,
                       ( registry_entry(Id, ExpertId, Contract),
                         metadata(Contract, Metadata) ),
                       Pairs)),
    keysort(Pairs, Sorted),
    pairs_values(Sorted, Catalog).

metadata(Contract, expert_metadata{id:Id, version:Version, goal:Goal,
                                   priority:Priority, requires:Requires}) :-
    Id = Contract.id,
    Version = Contract.version,
    Goal = Contract.goal,
    Priority = Contract.priority,
    Requires = Contract.requires.

expert_select(Registry, Goal, Context, Outcome) :-
    catch(select_checked(Registry, Goal, Context, Outcome),
          expert_fault(Kind, Detail),
          Outcome = error(expert_error{kind:Kind, detail:Detail})).

select_checked(Registry, Goal, Context, Outcome) :-
    registry_id(Registry, Id),
    context_checked(Goal, Context, Capabilities),
    with_mutex(rlm_expert_registry,
               findall(ExpertId-Candidate,
                       ( registry_entry(Id, ExpertId, Contract),
                         candidate(Contract, Goal, Capabilities, Candidate) ),
                       Pairs)),
    keysort(Pairs, Sorted),
    pairs_values(Sorted, Candidates),
    findall(Priority-ExpertId,
            ( member(C, Candidates), C.reason == eligible,
              Priority = C.priority, ExpertId = C.id ),
            Eligible),
    selection_outcome(Eligible, Candidates, Outcome).

selection_outcome([], Candidates,
                  error(expert_error{kind:no_eligible_expert,
                                     candidates:Candidates})) :- !.
selection_outcome(Eligible, Candidates, Outcome) :-
    Eligible \== [],
    findall(P, member(P-_, Eligible), Priorities),
    max_list(Priorities, Max),
    findall(Id, member(Max-Id, Eligible), Top),
    ( Top = [Only]
    -> Outcome = ok(expert_decision{expert_id:Only,
                                    priority:Max, candidates:Candidates})
    ;  Outcome = error(expert_error{kind:ambiguous_experts,
                                    experts:Top, candidates:Candidates})
    ).

candidate(Contract, Goal, Capabilities,
          expert_candidate{id:Id, version:Version, priority:Priority,
                           reason:Reason}) :-
    Id = Contract.id,
    Version = Contract.version,
    Priority = Contract.priority,
    ( goal_shape(Goal, Contract.goal)
    -> findall(Cap,
               ( member(Cap, Contract.requires),
                 \+ memberchk(Cap, Capabilities) ),
               Missing),
       ( Missing == [] -> Reason = eligible
       ; Reason = missing_capability(Missing) )
    ; Reason = goal_mismatch
    ).

goal_shape(Goal, Op/Arity) :-
    compound_name_arity(Goal, Op, Arity).

expert_call(Registry, Goal, Context, Outcome) :-
    expert_select(Registry, Goal, Context, Decision),
    ( Decision = ok(Selected)
    -> expert_invoke(Registry, Selected.expert_id, Goal, Context, Outcome)
    ; Outcome = Decision ).

expert_invoke(Registry, ExpertId, Goal, Context, Outcome) :-
    catch(invoke_checked(Registry, ExpertId, Goal, Context, Outcome),
          expert_fault(Kind, Detail),
          Outcome = error(expert_error{kind:Kind, detail:Detail})).

invoke_checked(Registry, ExpertId, Goal, Context, Outcome) :-
    registry_id(Registry, Id),
    context_checked(Goal, Context, Capabilities),
    with_mutex(rlm_expert_registry,
               ( registry_entry(Id, ExpertId, Contract)
               -> true
               ;  throw(expert_fault(unknown_expert, ExpertId)) )),
    candidate(Contract, Goal, Capabilities, Candidate),
    ( Candidate.reason == eligible
    -> Handler = Contract.handler,
       catch(( call_with_time_limit(
                   5,
                   call_with_inference_limit(
                       once(call(Handler, Goal, Context, Value)),
                       100000, LimitStatus))
             -> ( LimitStatus == inference_limit_exceeded
                -> Outcome = error(expert_error{kind:work_limit_exceeded,
                                                detail:ExpertId})
                ;  Outcome = ok(expert_result{expert_id:ExpertId,
                                              version:Contract.version,
                                              value:Value}) )
             ;  Outcome = error(expert_error{kind:handler_failed,
                                             detail:ExpertId}) ),
             Exception,
             Outcome = error(expert_error{kind:handler_exception,
                                          detail:Exception}))
    ; Outcome = error(expert_error{kind:not_applicable,
                                   candidate:Candidate}) ).

context_checked(Goal, Context, Caps) :-
    ( ground(Goal), acyclic_term(Goal),
      is_dict(Context),
      get_dict(capabilities, Context, Capabilities),
      capabilities_normalize(Capabilities, ok(Caps))
    -> true
    ;  throw(expert_fault(invalid_call, call(Goal, Context)))
    ).

registry_id(expert_registry(Id), Id) :-
    registry_alive(Id), !.
registry_id(Registry, _) :-
    throw(expert_fault(invalid_registry, Registry)).
