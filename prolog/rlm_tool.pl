:- module(rlm_tool,
          [ tool_registry_create/1,
            tool_registry_destroy/1,
            tool_register/4,
            tool_discover/2,
            tool_lookup/3,
            tool_invoke/7,
            tool_invoke_async/6,
            tool_registry_runtime_tools/3,
            tool_registry_runtime_tools/4,
            capabilities_normalize/2,
            capability_allowed/2,
            capabilities_narrow/3,
            register_project_read_tool/4
          ]).

/** <module> Capability and authority gated tool registry

Trusted host code registers handlers and schemas. Model-selected plans may name
registered tools, but model data never becomes a callable.

The authoritative invocation order is intentionally explicit:

  registered tool
    -> argument/schema normalization
    -> capability authorization
    -> trusted pure preflight/confinement validation
    -> exact normalized operation
    -> host authority decision
    -> execute now OR persist a pending operation

A `tool_handler(Preflight, Execute)` registration may be used by trusted tool
packs that need confinement/target normalization before authority mediation.
Preflight is a pure validator with shape Preflight(+Args,-Normalized,-Details).
Ordinary callable handlers use identity preflight. Neither callable is exposed
through discovery or model-facing schemas.

Latency-bearing invocation remains canonical async-first: tool_invoke_async/6
submits one tool_invoke_execute/6 operation, while tool_invoke/7 starts that same
operation and awaits its Future. Internal plan execution calls the execute ABI
directly, so code already inside an async worker never waits on a nested Future.
Human approval never blocks that worker: approve_diff returns a pending outcome
and relinquishes the worker; approval later schedules only the exact trusted
continuation.
*/

:- use_module(library(crypto)).
:- use_module(library(gensym)).
:- use_module(library(lists)).
:- use_module(library(readutil)).
:- use_module(library(time)).
:- use_module(rlm_async, []).
:- use_module(rlm_authority, []).
:- use_module(rlm_effect, []).
:- use_module(rlm_effect_executor, []).
:- use_module(rlm_effect_authority, []).

:- multifile rlm_effect_executor:effect_adapter_submit/4.
:- multifile tool_registry_destroy_hook/1.

:- dynamic tool_registry_alive/1.
:- dynamic tool_registry_entry/4.

:- discontiguous invoke_after_effect_prepare/19.

/* -------------------------------------------------------------------------
 * Capability model
 * ---------------------------------------------------------------------- */

capabilities_normalize(Capabilities, Outcome) :-
    catch(( must_be_capability_list(Capabilities),
            maplist(must_be_capability, Capabilities),
            sort(Capabilities, Normalized),
            Outcome = ok(Normalized)
          ),
          Exception,
          capability_exception(Exception, Outcome)).

capability_allowed(Capabilities, Capability) :-
    capabilities_normalize(Capabilities, ok(Normalized)),
    must_be_capability(Capability),
    memberchk(Capability, Normalized).

capabilities_narrow(Parent, Requested, Outcome) :-
    capabilities_normalize(Parent, ParentOutcome),
    capabilities_narrow_parent(ParentOutcome, Requested, Outcome).

capabilities_narrow_parent(error(Error), _, error(Error)) :- !.
capabilities_narrow_parent(ok(Parent), Requested, Outcome) :-
    capabilities_normalize(Requested, RequestedOutcome),
    capabilities_narrow_requested(RequestedOutcome, Parent, Outcome).

capabilities_narrow_requested(error(Error), _, error(Error)) :- !.
capabilities_narrow_requested(ok(Requested), Parent, Outcome) :-
    findall(Cap,
            ( member(Cap, Requested),
              \+ memberchk(Cap, Parent)
            ),
            Widening),
    (   Widening == []
    ->  Outcome = ok(Requested)
    ;   Outcome = error(capability_error{
                            kind:widening_denied,
                            requested:Requested,
                            parent:Parent,
                            unauthorized:Widening,
                            message:"child capabilities must be a subset of parent capabilities"
                        })
    ).

must_be_capability_list(Value) :-
    is_list(Value),
    !.
must_be_capability_list(Value) :-
    throw(capability_fault(invalid_capability_list(Value))).

must_be_capability(Capability) :-
    capability_shape(Capability),
    !.
must_be_capability(Capability) :-
    throw(capability_fault(invalid_capability(Capability))).

capability_shape(rlm).
capability_shape(parallel).
capability_shape(retry).
capability_shape(checkpoint).
capability_shape(tool(Name)) :- capability_name(Name).
capability_shape(context(Name)) :- capability_name(Name).
capability_shape(model(Name)) :- capability_name(Name).
capability_shape(graph(Name)) :- capability_name(Name).
capability_shape(persistence(Name)) :- capability_name(Name).
capability_shape(network(Name)) :- capability_name(Name).
capability_shape(filesystem(Name)) :- capability_name(Name).
capability_shape(process(Name)) :- capability_name(Name).
capability_shape(mcp(Name)) :- capability_name(Name).

capability_name(Name) :-
    atom(Name),
    Name \== ''.

capability_exception(capability_fault(Fault), error(Error)) :-
    !,
    Error = capability_error{
                kind:invalid_capabilities,
                detail:Fault,
                message:"capability set is invalid"
            }.
capability_exception(Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = capability_error{
                kind:capability_error,
                exception:Safe,
                message:"capability processing failed"
            }.

/* -------------------------------------------------------------------------
 * Registry
 * ---------------------------------------------------------------------- */

tool_registry_create(tool_registry(Id)) :-
    with_mutex(rlm_tool_registry,
               ( gensym(registry_, Id),
                 assertz(tool_registry_alive(Id))
               )).

tool_registry_destroy(tool_registry(Id)) :-
    Context = tool_registry(Id),
    catch(rlm_authority:rlm_authority_clear(Context), _, true),
    with_mutex(rlm_tool_registry,
               ( retractall(tool_registry_entry(Id, _, _, _)),
                 retractall(tool_registry_alive(Id, _))
               )),
    run_tool_registry_destroy_hooks(Context).

run_tool_registry_destroy_hooks(Registry) :-
    forall(clause(tool_registry_destroy_hook(Registry), Body),
           catch(call(Body), _, true)).

tool_register(Registry, Schema0, Handler0, Outcome) :-
    catch(tool_register_(Registry, Schema0, Handler0, Outcome),
          Exception,
          tool_api_exception(register, Exception, Outcome)).

tool_register_(Registry, Schema0, Handler0, Outcome) :-
    registry_id(Registry, Id),
    normalize_tool_schema(Schema0, Schema),
    normalize_tool_handler(Handler0, Binding),
    Name = Schema.name,
    with_mutex(rlm_tool_registry,
               register_unique(Id, Name, Schema, Binding, Outcome)).

normalize_tool_handler(tool_handler(Preflight, Handler),
                       tool_binding(Preflight, Handler)) :-
    !,
    require_callable_handler(Preflight),
    require_callable_handler(Handler).
normalize_tool_handler(Handler,
                       tool_binding(rlm_tool:identity_preflight, Handler)) :-
    require_callable_handler(Handler).

require_callable_handler(Handler) :-
    callable(Handler),
    ground(Handler),
    !.
require_callable_handler(Handler) :-
    value_shape(Handler, Shape),
    throw(tool_fault(invalid_handler(Shape))).

identity_preflight(Args0, Args, operation_details{}) :-
    normalize_authority_value(Args0, Args).

register_unique(Id, Name, _, _,
                error(tool_error{
                          phase:register,
                          kind:duplicate_tool,
                          tool:Name,
                          message:"tool name is already registered"
                      })) :-
    tool_registry_entry(Id, Name, _, _),
    !.
register_unique(Id, Name, Schema, Binding, ok(Schema)) :-
    assertz(tool_registry_entry(Id, Name, Schema, Binding)).

tool_discover(Registry, Schemas) :-
    registry_id(Registry, Id),
    findall(Name-Schema,
            tool_registry_entry(Id, Name, Schema, _),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_schemas(Pairs, Schemas).

pairs_schemas([], []).
pairs_schemas([_-Schema|Pairs], [Schema|Schemas]) :-
    pairs_schemas(Pairs, Schemas).

tool_lookup(Registry, Name, Outcome) :-
    catch(tool_lookup_(Registry, Name, Outcome),
          Exception,
          tool_api_exception(lookup, Exception, Outcome)).

tool_lookup_(Registry, Name, Outcome) :-
    registry_id(Registry, Id),
    (   tool_registry_entry(Id, Name, Schema, _)
    ->  Outcome = ok(Schema)
    ;   Outcome = error(tool_error{
                           phase:lookup,
                           kind:unknown_tool,
                           tool:Name,
                           message:"tool is not registered"
                       })
    ).

/* -------------------------------------------------------------------------
 * Invocation
 * ---------------------------------------------------------------------- */

tool_invoke_async(Registry, Capabilities, Name, Args, Options, Future) :-
    tool_task_metadata(Name, Options, Metadata),
    (   tool_inline_approval_admission(Registry,
                                       Capabilities,
                                       Name,
                                       Args,
                                       Options,
                                       Result)
    ->  rlm_async:rlm_future_deferred(Metadata, Future),
        rlm_async:rlm_future_resolve(Future, Result)
    ;   rlm_async:rlm_async_submit(
            rlm_tool:tool_invoke_execute(Registry,
                                         Capabilities,
                                         Name,
                                         Args,
                                         Options),
            Metadata,
            Future)
    ).

tool_inline_approval_admission(Registry,
                               Capabilities,
                               Name,
                               Args,
                               Options,
                               Result) :-
    registry_entry(Registry, Name, Schema, _Binding, ok),
    Schema.effect \== read,
    tool_authority_context(Registry, Options, Context),
    with_mutex(rlm_authority,
               ( rlm_authority:rlm_authority(Context, approve_diff),
                 tool_invoke_execute(Registry,
                                     Capabilities,
                                     Name,
                                     Args,
                                     Options,
                                     Result)
               )).

tool_invoke(Registry, Capabilities, Name, Args, Options, Outcome, Trace) :-
    tool_invoke_async(Registry, Capabilities, Name, Args, Options, Future),
    setup_call_cleanup(
        true,
        rlm_async:rlm_future_await(Future, FutureResult),
        rlm_async:rlm_future_destroy(Future)),
    tool_future_result(FutureResult, Name, Outcome, Trace).

tool_invoke_execute(Registry, Capabilities, Name, Args, Options, Result) :-
    get_time(Start),
    catch(tool_invoke_(Registry,
                       Capabilities,
                       Name,
                       Args,
                       Options,
                       CoreOutcome,
                       Auth,
                       Authority,
                       Status,
                       Bytes,
                       Fingerprint,
                       ApprovalId),
          Exception,
          invoke_exception(Exception,
                           CoreOutcome,
                           Auth,
                           Authority,
                           Status,
                           Bytes,
                           Fingerprint,
                           ApprovalId)),
    get_time(End),
    ElapsedMs is round((End-Start)*1000),
    Trace = tool_trace{
                tool:Name,
                authorization:Auth,
                authority:Authority,
                status:Status,
                fingerprint:Fingerprint,
                approval_id:ApprovalId,
                output_bytes:Bytes,
                elapsed_ms:ElapsedMs
            },
    attach_trace(CoreOutcome, Trace, Outcome),
    Result = tool_async_result{outcome:Outcome, trace:Trace}.

tool_future_result(Result, _, Outcome, Trace) :-
    is_dict(Result, tool_async_result),
    !,
    Outcome = Result.outcome,
    Trace = Result.trace.
tool_future_result(error(Error), Name, error(Error), Trace) :-
    !,
    Trace = tool_trace{
                tool:Name,
                authorization:denied,
                authority:unknown,
                status:async_error,
                fingerprint:none,
                approval_id:none,
                output_bytes:0,
                elapsed_ms:0
            }.
tool_future_result(Other, Name, error(Error), Trace) :-
    value_shape(Other, Shape),
    Error = tool_error{
                phase:invoke,
                kind:invalid_async_result,
                detail:Shape,
                message:"asynchronous tool invocation returned an invalid result"
            },
    Trace = tool_trace{
                tool:Name,
                authorization:denied,
                authority:unknown,
                status:invalid_async_result,
                fingerprint:none,
                approval_id:none,
                output_bytes:0,
                elapsed_ms:0
            }.

/* FILE CONTENT OMITTED IN THIS CALL FOR SAFETY */
