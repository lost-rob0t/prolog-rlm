:- module(rlm_expert,
          [ rlm_expert_ready/0,
            expert_register/4, expert_catalog/2, expert_select/4,
            expert_invoke/7, expert_invoke_execute/6 ]).

/** <module> Bounded deterministic experts over the canonical tool registry

This first #377 slice supports trusted, model-free leaf reasoning. Handlers
are host code, never project/model terms. Registration projects an ordinary
read tool, so direct and plan callers reuse the existing tool ABI. It grants
no capability. Recursive experts and metered fallback are not implemented.
*/
:- use_module(library(error)).
:- use_module(library(pairs)).
:- use_module(rlm_closed_data).
:- use_module(rlm_tool).
:- dynamic contract/3.
:- multifile rlm_tool:tool_registry_destroy_hook/1.

rlm_expert_ready :-
    rlm_tool:capabilities_normalize([], ok([])).

rlm_tool:tool_registry_destroy_hook(Registry) :-
    with_mutex(rlm_expert_registry,
               retractall(rlm_expert:contract(Registry, _, _))).

expert_register(Registry, Contract0, Handler, Outcome) :-
    catch(with_mutex(rlm_expert_registry,
                     register(Registry, Contract0, Handler, Outcome)), Exception,
          Outcome = error(expert_error{kind:invalid_contract, detail:Exception})).

register(Registry, Contract0, Handler, Outcome) :-
    closed_data_normalize(Contract0, Contract),
    dict_pairs(Contract, _, Pairs), pairs_keys(Pairs, Keys),
    ( sort([id,version,goal,priority,description,arguments,result,limits], Keys)
    -> true
    ; throw(error(domain_error(expert_contract_fields, Keys), _)) ),
    must_be(atom, Contract.id), must_be(atom, Contract.goal),
    must_be(positive_integer, Contract.version),
    must_be(integer, Contract.priority),
    must_be(positive_integer, Contract.limits.inferences),
    dict_pairs(Contract.limits, _, LimitPairs), pairs_keys(LimitPairs, LimitKeys),
    ( sort([inferences,time_limit,max_output_bytes], LimitKeys) -> true
    ; throw(error(domain_error(expert_limit_fields,LimitKeys),_)) ),
    ( memberchk(Contract.goal, [sync_remote,run,index,delete])
    -> throw(error(domain_error(expert_goal, Contract.goal), _))
    ; true ),
    must_be(callable, Handler), must_be(ground, Handler),
    Schema = tool_schema{name:Contract.id, description:Contract.description,
        capability:tool(Contract.id), effect:read,
        arguments:Contract.arguments, result:Contract.result,
        limits:Contract.limits},
    tool_register(Registry, Schema,
        rlm_expert:bounded_handler(Handler, Contract.limits.inferences), Result),
    ( Result = ok(_)
    -> assertz(contract(Registry, Contract.id, Contract)), Outcome = ok(Contract)
    ; Outcome = Result ).

bounded_handler(Handler, Limit, Arguments, Value) :-
    call_with_inference_limit(once(call(Handler, Arguments, Value)), Limit, Used),
    ( Used == inference_limit_exceeded
    -> throw(error(resource_error(expert_inferences), _))
    ; true ).

expert_catalog(Registry, Catalog) :-
    findall(C, contract(Registry, _, C), Unsorted), sort(Unsorted, Catalog).

expert_select(Registry, Goal, Context, Outcome) :-
    catch(select_expert(Registry, Goal, Context, Outcome), E,
          Outcome=error(expert_error{kind:invalid_selection,detail:E})).

select_expert(Registry, Goal, Context, Outcome) :-
    must_be(atom, Goal),
    capabilities_normalize(Context.capabilities, CapsOutcome),
    ( CapsOutcome=ok(_) -> true
    ; throw(error(domain_error(capabilities,Context.capabilities),_)) ),
    findall(Key-C,
        ( contract(Registry, Id, C), C.goal == Goal,
          memberchk(tool(Id), Context.capabilities),
          Key is -C.priority ), Pairs),
    keysort(Pairs, Sorted), selection(Sorted, Outcome).

selection([], error(expert_error{kind:no_applicable_expert})) :- !.
selection([P-A,P-B|Rest], error(expert_error{kind:ambiguous_expert,
                                          candidates:[A,B|Others]})) :-
    !, findall(C, member(P-C, Rest), Others).
selection([_-C|Rest], ok(expert_decision{selected:C.id, version:C.version,
        reason:goal_and_capability, candidates:[C|Others]})) :-
    pairs_values(Rest, Others).

expert_invoke(Registry, Id, Args, Context, Options, Outcome, Trace) :-
    invocation_ready(Registry, Id, Ready),
    ( Ready == ok
    -> tool_invoke(Registry, Context.capabilities, Id, Args, Options, Outcome, Trace)
    ; Outcome = Ready, Trace = expert_trace{status:blocked, expert:Id} ).

expert_invoke_execute(Registry, Id, Args, Context, Options, Outcome) :-
    invocation_ready(Registry, Id, Ready),
    ( Ready == ok
    -> tool_invoke_execute(Registry, Context.capabilities, Id, Args, Options, Outcome)
    ; Outcome = tool_async_result{outcome:Ready, trace:expert_trace{status:blocked,expert:Id}} ).

invocation_ready(Registry, Id, Ready) :-
    ( contract(Registry, Id, _)
    -> Ready = ok
    ; Ready = error(expert_error{kind:unknown_expert, expert:Id}) ).
