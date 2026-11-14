:- module(rlm_expert_tool, [expert_tool_register/5]).

/** <module> Provider-free experts projected into the canonical tool registry

Trusted hosts bind one accepted goal indicator to a named read tool. Calls carry
only an argument vector, never a registry, goal functor, handler or capability.
The frozen registry generation prevents a later registration from silently
changing the authority or meaning of an already advertised tool.
*/
:- use_module(library(error)).
:- use_module(library(lists)).
:- use_module(rlm_closed_data).
:- use_module(rlm_expert).
:- use_module(rlm_tool).

expert_tool_register(Tools, Experts, Id, Projection0, Outcome) :-
    catch(register_projection(Tools, Experts, Id, Projection0, Outcome),
          Error,
          Outcome = error(expert_tool_error{kind:invalid_projection,detail:Error})).

register_projection(Tools, Experts, Id, Projection0, Outcome) :-
    closed_data_normalize(Projection0, Projection),
    must_be(dict, Projection),
    dict_pairs(Projection, _, Pairs),
    forall(member(Key-_, Pairs),
           (memberchk(Key,[name,goal,description,limits]) -> true
            ; throw(error(domain_error(expert_projection_field,Key),_)))),
    expert_lookup(Experts, Id, Lookup),
    ( Lookup = ok(Descriptor) -> true
    ; throw(error(expert_lookup_failed(Lookup),_)) ),
    ( Descriptor.effects == [], memberchk(Descriptor.fallback,[none,no_fallback])
    -> true
    ; throw(error(domain_error(provider_free_read_expert,Id),_)) ),
    Indicator = Projection.goal,
    ( memberchk(Indicator,Descriptor.accepts) -> true
    ; throw(error(domain_error(accepted_expert_goal,Indicator),_)) ),
    Indicator = Functor/Arity,
    projection_limits(Projection, Limits, Inferences),
    Schema = tool_schema{name:Projection.name,description:Projection.description,
        capability:tool(Projection.name),requires:Descriptor.requires,effect:read,
        arguments:_{type:object,required:[arguments],additional_properties:false,
                    properties:_{arguments:_{type:array,items:_{type:any}}}},
        result:_{type:any},limits:Limits},
    Binding = binding(Experts,Id,Descriptor.registry_generation,Functor,Arity,
                      Descriptor.requires,Inferences),
    tool_register(Tools,Schema,
        tool_handler(rlm_expert_tool:projection_preflight(Binding),
                     rlm_expert_tool:projection_execute(Binding)),Outcome).

projection_limits(Projection, Limits, Inferences) :-
    ( get_dict(limits,Projection,L) -> must_be(dict,L) ; L=limits{} ),
    dict_pairs(L,_,Pairs),
    forall(member(Key-_,Pairs),
           (memberchk(Key,[time_limit,max_output_bytes,inferences]) -> true
            ; throw(error(domain_error(expert_tool_limit,Key),_)))),
    ( get_dict(inferences,L,Inferences) -> true ; Inferences=100000 ),
    must_be(positive_integer,Inferences),
    ( get_dict(time_limit,L,Time) -> true ; Time=1.0 ),
    ( get_dict(max_output_bytes,L,Bytes) -> true ; Bytes=16384 ),
    Limits=tool_limits{time_limit:Time,max_output_bytes:Bytes}.

projection_preflight(Binding, Args0, Args, operation_details{}) :-
    closed_data_normalize(Args0,Args),
    Binding=binding(_,_,_,_,Arity,_,_),
    get_dict(arguments,Args,Values), must_be(list,Values),
    ( length(Values,Arity) -> true
    ; throw(error(domain_error(expert_argument_arity,Values),_)) ),
    projection_current(Binding).

projection_current(binding(Experts,_,Expected,_,_,_,_)) :-
    ( expert_registry_generation(Experts,Current), Current =:= Expected -> true
    ; throw(error(permission_error(invoke,stale_expert_projection,Expected),_)) ).

projection_execute(Binding, Args, Outcome) :-
    projection_current(Binding),
    Binding=binding(Experts,Id,Generation,Functor,_,Caps,Inferences),
    Goal=..[Functor|Args.arguments],
    % The ordinary tool gate checked every required capability before preflight.
    % Only this fixed, minimal subset is passed onward, never model context.
    call_with_inference_limit(
        expert_invoke(Experts,Id,Goal,
            expert_context{capabilities:Caps,expected_registry_generation:Generation},Outcome),
        Inferences,Used),
    ( Used == inference_limit_exceeded
    -> throw(error(resource_error(expert_inferences),_))
    ; true ).
