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
                 retractall(tool_registry_alive(Id))
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

tool_task_metadata(Name0, Options, Metadata) :-
    metadata_ground(Name0, unknown, Name),
    metadata_option(trace_id, Options, none, TraceId),
    metadata_option(session_id, Options, none, SessionId),
    metadata_option(runtime_id, Options, none, RuntimeId),
    metadata_option(agent_id, Options, none, AgentId),
    metadata_option(graph_id, Options, none, GraphId),
    metadata_option(run_id, Options, none, RunId),
    metadata_option(authority_context, Options, none, AuthorityContext),
    Metadata = async_metadata{
                   operation:tool_invoke,
                   tool:Name,
                   trace_id:TraceId,
                   session_id:SessionId,
                   runtime_id:RuntimeId,
                   agent_id:AgentId,
                   graph_id:GraphId,
                   run_id:RunId,
                   authority_context:AuthorityContext
               }.

metadata_option(Name, Options, Default, Value) :-
    (   is_list(Options),
        member(Option, Options),
        nonvar(Option),
        Option =.. [Name, Found],
        ground(Found)
    ->  Value = Found
    ;   Value = Default
    ).

metadata_ground(Value, _, Value) :- ground(Value), !.
metadata_ground(_, Default, Default).

tool_invoke_(Registry,
             Capabilities,
             Name,
             Args,
             Options,
             Outcome,
             Authorization,
             AuthorityMode,
             Status,
             Bytes,
             Fingerprint,
             ApprovalId) :-
    registry_entry(Registry, Name, Schema, Binding, LookupOutcome),
    invoke_after_lookup(LookupOutcome,
                        Registry,
                        Schema,
                        Binding,
                        Capabilities,
                        Args,
                        Options,
                        Outcome,
                        Authorization,
                        AuthorityMode,
                        Status,
                        Bytes,
                        Fingerprint,
                        ApprovalId).

registry_entry(Registry, Name, Schema, Binding, Outcome) :-
    registry_id(Registry, Id),
    (   tool_registry_entry(Id, Name, Schema0, Binding0)
    ->  Schema = Schema0,
        Binding = Binding0,
        Outcome = ok
    ;   Outcome = error(tool_error{
                           phase:lookup,
                           kind:unknown_tool,
                           tool:Name,
                           message:"tool is not registered"
                       })
    ).

invoke_after_lookup(error(Error), _, _, _, _, _, _, error(Error),
                    denied, unknown, unknown_tool, 0, none, none) :- !.
invoke_after_lookup(ok,
                    Registry,
                    Schema,
                    Binding,
                    Capabilities,
                    Args,
                    Options,
                    Outcome,
                    Authorization,
                    AuthorityMode,
                    Status,
                    Bytes,
                    Fingerprint,
                    ApprovalId) :-
    validate_schema(Schema.arguments, Args, args, ArgsOutcome),
    invoke_after_args(ArgsOutcome,
                      Registry,
                      Schema,
                      Binding,
                      Capabilities,
                      Args,
                      Options,
                      Outcome,
                      Authorization,
                      AuthorityMode,
                      Status,
                      Bytes,
                      Fingerprint,
                      ApprovalId).

invoke_after_args(error(Error), _, _, _, _, _, _, error(Error),
                  denied, unknown, malformed_args, 0, none, none) :- !.
invoke_after_args(ok,
                  Registry,
                  Schema,
                  Binding,
                  Capabilities,
                  Args,
                  Options,
                  Outcome,
                  Authorization,
                  AuthorityMode,
                  Status,
                  Bytes,
                  Fingerprint,
                  ApprovalId) :-
    authorize_tool(Capabilities, Schema.capability, CapabilityOutcome),
    invoke_after_capability(CapabilityOutcome,
                            Registry,
                            Schema,
                            Binding,
                            Args,
                            Options,
                            Outcome,
                            Authorization,
                            AuthorityMode,
                            Status,
                            Bytes,
                            Fingerprint,
                            ApprovalId).

authorize_tool(Capabilities, Capability, Outcome) :-
    capabilities_normalize(Capabilities, CapsOutcome),
    authorize_normalized(CapsOutcome, Capability, Outcome).

authorize_normalized(error(Error), _, error(Error)) :- !.
authorize_normalized(ok(Caps), Capability, Outcome) :-
    (   memberchk(Capability, Caps)
    ->  Outcome = ok
    ;   Outcome = denied
    ).

invoke_after_capability(error(Error), _, _, _, _, _, error(ToolError),
                        denied, unknown, invalid_capabilities, 0, none, none) :-
    !,
    ToolError = tool_error{
                    phase:authorize,
                    kind:invalid_capabilities,
                    cause:Error,
                    message:"tool capability set is invalid"
                }.
invoke_after_capability(denied, _, Schema, _, _, _, error(Error),
                        denied, unknown, capability_denied, 0, none, none) :-
    !,
    Error = tool_error{
                phase:authorize,
                kind:capability_denied,
                tool:Schema.name,
                capability:Schema.capability,
                message:"tool capability was not granted"
            }.
invoke_after_capability(ok,
                        Registry,
                        Schema,
                        Binding,
                        Args,
                        Options,
                        Outcome,
                        Authorization,
                        AuthorityMode,
                        Status,
                        Bytes,
                        Fingerprint,
                        ApprovalId) :-
    effective_limits(Schema.limits, Options, Limits),
    preflight_tool(Binding, Args, Limits.time_limit, PreflightOutcome),
    invoke_after_preflight(PreflightOutcome,
                           Registry,
                           Schema,
                           Binding,
                           Options,
                           Limits,
                           Outcome,
                           Authorization,
                           AuthorityMode,
                           Status,
                           Bytes,
                           Fingerprint,
                           ApprovalId).

preflight_tool(tool_binding(Preflight, _), Args, TimeLimit, Outcome) :-
    catch(call_with_time_limit(TimeLimit,
                               call_preflight(Preflight,
                                              Args,
                                              NormalizedArgs0,
                                              Details0)),
          Exception,
          preflight_exception(Exception, Failure)),
    (   var(Failure)
    ->  normalize_authority_value(NormalizedArgs0, NormalizedArgs),
        normalize_authority_value(Details0, Details),
        require_ground_preflight(NormalizedArgs, Details),
        Outcome = ok(NormalizedArgs, Details)
    ;   Outcome = Failure
    ).

call_preflight(Preflight, Args, NormalizedArgs, Details) :-
    (   call(Preflight, Args, NormalizedArgs, Details)
    ->  true
    ;   throw(tool_fault(preflight_failed))
    ).

require_ground_preflight(Args, Details) :-
    ground(Args),
    is_dict(Details),
    ground(Details),
    !.
require_ground_preflight(Args, Details) :-
    throw(tool_fault(invalid_preflight_result(Args, Details))).

preflight_exception(Exception, _) :-
    tool_control_exception(Exception),
    !,
    throw(Exception).
preflight_exception(time_limit_exceeded,
                    error(tool_error{
                              phase:preflight,
                              kind:preflight_timeout,
                              message:"tool preflight exceeded its wall-time limit"
                          })) :- !.
preflight_exception(time_limit_exceeded(_),
                    error(tool_error{
                              phase:preflight,
                              kind:preflight_timeout,
                              message:"tool preflight exceeded its wall-time limit"
                          })) :- !.
preflight_exception(tool_fault(Fault),
                    error(tool_error{
                              phase:preflight,
                              kind:confinement_denied,
                              detail:Fault,
                              message:"tool preflight or confinement validation failed"
                          })) :- !.
preflight_exception(Exception,
                    error(tool_error{
                              phase:preflight,
                              kind:confinement_denied,
                              exception:Safe,
                              message:"tool preflight or confinement validation failed"
                          })) :-
    safe_exception(Exception, Safe).

invoke_after_preflight(error(Error), _, _, _, _, _, error(Error),
                        denied, unknown, confinement_denied, 0, none, none) :- !.
invoke_after_preflight(ok(NormalizedArgs, Details),
                       Registry,
                       Schema,
                       Binding,
                       Options,
                       Limits,
                       Outcome,
                       Authorization,
                       AuthorityMode,
                       Status,
                       Bytes,
                       Fingerprint,
                       ApprovalId) :-
    tool_authority_context(Registry, Options, Context),
    tool_correlation(Options, Correlation),
    rlm_authority:rlm_authority(Context, AuthorityMode),
    (   Schema.effect == read
    ->  invoke_read_operation(Context,
                              Schema,
                              Binding,
                              NormalizedArgs,
                              Details,
                              Limits,
                              Correlation,
                              Options,
                              Outcome,
                              Authorization,
                              AuthorityMode,
                              Status,
                              Bytes,
                              Fingerprint,
                              ApprovalId)
    ;   invoke_effectful_operation(Context,
                                   Registry,
                                   Schema,
                                   Binding,
                                   NormalizedArgs,
                                   Details,
                                   Limits,
                                   Options,
                                   Correlation,
                                   Outcome,
                                   Authorization,
                                   AuthorityMode,
                                   Status,
                                   Bytes,
                                   Fingerprint,
                                   ApprovalId)
    ).

invoke_read_operation(Context,
                       Schema,
                       Binding,
                       NormalizedArgs,
                       Details,
                       Limits,
                       Correlation,
                       Options,
                       Outcome,
                       Authorization,
                       AuthorityMode,
                       Status,
                       Bytes,
                       Fingerprint,
                       ApprovalId) :-
    Operation = authority_operation{
                    name:Schema.name,
                    effect:Schema.effect,
                    capability:Schema.capability,
                    args:NormalizedArgs,
                    details:Details,
                    correlation:Correlation
                },
    Continuation = rlm_tool:tool_pending_execute(Schema,
                                                 Binding,
                                                 NormalizedArgs,
                                                 Limits,
                                                 Context),
    EditValidator = rlm_tool:tool_edit_validate(Schema,
                                                 Binding,
                                                 Options,
                                                 Limits,
                                                 Context,
                                                 Correlation),
    rlm_authority:rlm_authorize_operation(Context,
                                          Operation,
                                          Continuation,
                                          EditValidator,
                                          AuthorityOutcome),
    invoke_after_authority(AuthorityOutcome,
                           Schema,
                           Binding,
                           NormalizedArgs,
                           Limits,
                           Context,
                           Outcome,
                           Authorization,
                           AuthorityMode,
                           Status,
                           Bytes,
                           Fingerprint,
                           ApprovalId).

invoke_effectful_operation(Context,
                           Registry,
                           Schema,
                           Binding,
                           NormalizedArgs,
                           Details,
                           Limits,
                           Options,
                           Correlation,
                           Outcome,
                           Authorization,
                           AuthorityMode,
                           Status,
                           Bytes,
                           Fingerprint,
                           ApprovalId) :-
    registry_id(Registry, RegistryId),
    tool_effect_request(Schema, NormalizedArgs, Details, Request),
    tool_effect_options(RegistryId, Schema, Binding, Limits,
                        Correlation, EffectOptions),
    (   catch(rlm_effect_executor:effect_prepare(rlm_tool, tool, Request,
                                                EffectOptions, PrepareDecision),
              Exception,
              effect_prepare_exception(Exception, PrepareDecision))
    ->  true
    ;   PrepareDecision = error(effect_error{kind:effect_prepare_failed})
    ),
    invoke_after_effect_prepare(PrepareDecision,
                                Context,
                                Registry,
                                Schema,
                                Binding,
                                NormalizedArgs,
                                Details,
                                Limits,
                                Options,
                                Correlation,
                                Request,
                                EffectOptions,
                                Outcome,
                                Authorization,
                                AuthorityMode,
                                Status,
                                Bytes,
                                Fingerprint,
                                ApprovalId).

effect_prepare_exception(Exception, error(EffectError)) :-
    effect_error_term(Exception, EffectError).

effect_error_term(error(EffectError), EffectError) :- is_dict(EffectError), !.
effect_error_term(effect_fault(Kind),
                  effect_error{kind:Kind}) :- !.
effect_error_term(error(permission_error(_, effect_store, _), _),
                  effect_error{kind:store_lifecycle_conflict}) :- !.
effect_error_term(Exception,
                  effect_error{kind:effect_prepare_failed,
                               detail:Safe}) :-
    safe_exception_term(Exception, Safe).

invoke_after_effect_prepare(error(Error),
                            _Context, _Registry, _Schema, _Binding,
                            _NormalizedArgs, _Details, _Limits, _Options,
                            _Correlation, _Request, _EffectOptions,
                            error(ToolError),
                            denied, _AuthorityMode, Status,
                            0, none, none) :-
    !,
    effect_prepare_tool_error(Error, ToolError, Status).

effect_prepare_tool_error(Error, ToolError, Status) :-
    (   is_dict(Error), get_dict(kind, Error, Kind)
    ->  true
    ;   Kind = effect_prepare_failed
    ),
    effect_prepare_tool_error_kind(Kind, Error, ToolError, Status).

effect_prepare_tool_error_kind(store_not_open, Error,
                               tool_error{
                                   phase:effect,
                                   kind:effect_store_required,
                                   cause:Error,
                                   message:"effectful tool requires an open #57 effect store"
                               },
                               effect_store_required) :-
    !.
effect_prepare_tool_error_kind(Kind, Error,
                               tool_error{
                                   phase:effect,
                                   kind:Kind,
                                   cause:Error,
                                   message:"effectful tool preparation failed"
                               },
                               Kind).

invoke_after_effect_prepare(replay(Observation),
                            _Context, _Registry, Schema, _Binding,
                            _NormalizedArgs, _Details, _Limits, _Options,
                            _Correlation, _Request, _EffectOptions,
                            Outcome,
                            allowed, _AuthorityMode, replayed,
                            Bytes, Fingerprint, none) :-
    !,
    tool_outcome_from_observation(Observation, Schema, Outcome, _Status0, Bytes),
    Fingerprint = none.
invoke_after_effect_prepare(in_progress(Attempt),
                            _Context, _Registry, _Schema, _Binding,
                            _NormalizedArgs, _Details, _Limits, _Options,
                            _Correlation, _Request, _EffectOptions,
                            error(ToolError),
                            pending, _AuthorityMode, effect_in_progress,
                            0, Fingerprint, none) :-
    !,
    Fingerprint = Attempt.fingerprint,
    ToolError = tool_error{
                    phase:effect,
                    kind:effect_in_progress,
                    attempt:Attempt.attempt_id,
                    message:"admitted effect attempt is already in progress"
                }.
invoke_after_effect_prepare(reconciliation_required(Attempt),
                            _Context, _Registry, _Schema, _Binding,
                            _NormalizedArgs, _Details, _Limits, _Options,
                            _Correlation, _Request, _EffectOptions,
                            error(ToolError),
                            pending, _AuthorityMode, effect_reconciliation_required,
                            0, Fingerprint, none) :-
    !,
    Fingerprint = Attempt.fingerprint,
    ToolError = tool_error{
                    phase:effect,
                    kind:effect_reconciliation_required,
                    attempt:Attempt.attempt_id,
                    message:"uncertain prior effect attempt requires reconciliation"
                }.
invoke_after_effect_prepare(terminal(Attempt),
                            _Context, _Registry, _Schema, _Binding,
                            _NormalizedArgs, _Details, _Limits, _Options,
                            _Correlation, _Request, _EffectOptions,
                            error(ToolError),
                            denied, _AuthorityMode, effect_terminal,
                            0, Fingerprint, none) :-
    !,
    Fingerprint = Attempt.fingerprint,
    ToolError = tool_error{
                    phase:effect,
                    kind:effect_terminal,
                    attempt:Attempt.attempt_id,
                    message:"prior effect attempt is in a terminal state"
                }.
invoke_after_effect_prepare(execute(Ticket),
                            Context,
                            Registry,
                            Schema,
                            Binding,
                            NormalizedArgs,
                            Details,
                            Limits,
                            _Options,
                            Correlation,
                            Request,
                            EffectOptions,
                            Outcome,
                            Authorization,
                            AuthorityMode,
                            Status,
                            Bytes,
                            Fingerprint,
                            ApprovalId) :-
    !,
    BaseOperation = authority_operation{
                        name:Schema.name,
                        effect:Schema.effect,
                        capability:Schema.capability,
                        args:NormalizedArgs,
                        details:Details
                    },
    rlm_effect_authority:effect_authority_operation(Ticket, BaseOperation,
                                                     Correlation, Operation),
    Continuation = rlm_tool:tool_effect_pending_execute(Context,
                                                        Schema,
                                                        Ticket),
    EditValidator = rlm_tool:tool_effect_edit_validate(Context,
                                                       Registry,
                                                       Schema,
                                                       Binding,
                                                       Limits,
                                                       Correlation,
                                                       Request,
                                                       EffectOptions),
    rlm_authority:rlm_authorize_operation(Context,
                                          Operation,
                                          Continuation,
                                          EditValidator,
                                          AuthorityOutcome),
    invoke_after_authority_effect(AuthorityOutcome,
                                  Context,
                                  Schema,
                                  Ticket,
                                  Outcome,
                                  Authorization,
                                  AuthorityMode,
                                  Status,
                                  Bytes,
                                  Fingerprint,
                                  ApprovalId).

invoke_after_authority(error(Error), _, _, _, _, _, error(ToolError),
                       denied, _AuthorityMode, authority_denied, 0, none, none) :-
    !,
    ToolError = tool_error{
                    phase:authority,
                    kind:authority_denied,
                    cause:Error,
                    message:"host authority rejected the normalized tool operation"
                }.
invoke_after_authority(approval_required(Pending), _, _, _, _, _,
                       approval_required(Pending),
                       pending,
                       _AuthorityMode,
                       approval_required,
                       0,
                       Fingerprint,
                       ApprovalId) :-
    !,
    Fingerprint = Pending.fingerprint,
    ApprovalId = Pending.id.
invoke_after_authority(replay(Replay), _, _, _, _, _,
                       Replay,
                       allowed,
                       allow_once,
                       replayed,
                       Bytes,
                       Fingerprint,
                       none) :-
    !,
    replay_metadata(Replay, Bytes, Fingerprint).
invoke_after_authority(execute(Permit),
                       Schema,
                       Binding,
                       Args,
                       Limits,
                       Context,
                       Outcome,
                       allowed,
                       _AuthorityMode,
                       Status,
                       Bytes,
                       Fingerprint,
                       none) :-
    Fingerprint = Permit.fingerprint,
    perform_tool_effect(Schema,
                        Binding,
                        Args,
                        Limits,
                        CoreOutcome,
                        Status,
                        Bytes),
    complete_allow_once(Permit,
                        Context,
                        Fingerprint,
                        CoreOutcome),
    Outcome = CoreOutcome.

complete_allow_once(Permit, Context, Fingerprint, Outcome) :-
    (   Permit.kind == allow_once
    ->  rlm_authority:rlm_authority_complete_once(Context,
                                                  Fingerprint,
                                                  Outcome)
    ;   true
    ).

replay_metadata(ok(tool_execution{trace:Trace}), Bytes, Fingerprint) :-
    !,
    dict_value_default(output_bytes, Trace, 0, Bytes),
    dict_value_default(fingerprint, Trace, none, Fingerprint).
replay_metadata(error(Error), Bytes, Fingerprint) :-
    !,
    (   is_dict(Error), get_dict(trace, Error, Trace)
    ->  dict_value_default(output_bytes, Trace, 0, Bytes),
        dict_value_default(fingerprint, Trace, none, Fingerprint)
    ;   Bytes = 0,
        Fingerprint = none
    ).
replay_metadata(_, 0, none).

tool_pending_execute(Schema, Binding, Args, Limits, _Context, Resolution) :-
    get_time(Start),
    perform_tool_effect(Schema,
                        Binding,
                        Args,
                        Limits,
                        CoreOutcome,
                        Status,
                        Bytes),
    get_time(End),
    ElapsedMs is round((End-Start)*1000),
    Resolution = tool_pending_resolution{
                     outcome:CoreOutcome,
                     status:Status,
                     output_bytes:Bytes,
                     elapsed_ms:ElapsedMs
                 }.

/* The continuation above deliberately does not call tool_invoke/7 or
   tool_invoke_async/6. Approval resumes the already-validated operation at the
   authoritative side-effect boundary exactly once. */

/* -------------------------------------------------------------------------
 * #57 effect-boundary integration for effectful tools
 *
 * Effectful tools (effect \== read) no longer jump from authority to
 * perform_tool_effect. They prepare a durable #57 ticket before authority
 * composition, preserve that exact ground ticket into the authorized
 * continuation, and validate/admit/dispatch/observe that same ticket through
 * rlm_effect_executor on approval. The tool handler itself runs as a static
 * code-owned adapter submit hook. Only a stable code-owned binding digest
 * participates in executable semantics; the ephemeral registry identity
 * remains metadata for live dispatch lookup. Read tools retain the direct
 * fresh-read path above.
 * ---------------------------------------------------------------------- */

invoke_after_authority_effect(error(Error), _Context, _Schema, _Ticket,
                              error(ToolError),
                              denied, _AuthorityMode, authority_denied,
                              0, none, none) :-
    !,
    ToolError = tool_error{
                    phase:authority,
                    kind:authority_denied,
                    cause:Error,
                    message:"host authority rejected the normalized effectful tool operation"
                }.
invoke_after_authority_effect(approval_required(Pending), _Context, _Schema,
                              _Ticket,
                              approval_required(Pending),
                              pending, _AuthorityMode, approval_required,
                              0, Fingerprint, ApprovalId) :-
    !,
    Fingerprint = Pending.fingerprint,
    ApprovalId = Pending.id.
invoke_after_authority_effect(replay(Replay), _Context, _Schema, _Ticket,
                              Replay,
                              allowed, allow_once, replayed,
                              0, Fingerprint, none) :-
    !,
    replay_metadata(Replay, _Bytes, Fingerprint).
invoke_after_authority_effect(execute(Permit),
                              Context,
                              Schema,
                              Ticket,
                              Outcome,
                              allowed,
                              _AuthorityMode,
                              Status,
                              Bytes,
                              Fingerprint,
                              none) :-
    !,
    Fingerprint = Permit.fingerprint,
    AuthorityRef = authority_ref{context:Context, permit:Permit},
    tool_effect_dispatch(Ticket, AuthorityRef, EffectOutcome),
    tool_outcome_from_effect(EffectOutcome, Schema, Outcome, Status, Bytes),
    complete_allow_once(Permit, Context, Fingerprint, Outcome).

tool_effect_pending_execute(Context, Schema, Ticket, Resolution) :-
    get_time(Start),
    AuthorityRef = authority_ref{context:Context},
    tool_effect_dispatch(Ticket, AuthorityRef, EffectOutcome),
    tool_outcome_from_effect(EffectOutcome, Schema, CoreOutcome, Status, Bytes),
    get_time(End),
    ElapsedMs is round((End-Start)*1000),
    Resolution = tool_pending_resolution{
                     outcome:CoreOutcome,
                     status:Status,
                     output_bytes:Bytes,
                     elapsed_ms:ElapsedMs
                 }.

tool_effect_dispatch(Ticket, AuthorityRef, EffectOutcome) :-
    catch(rlm_effect_executor:effect_execute_prepared(rlm_tool, Ticket,
                                                      AuthorityRef,
                                                      EffectOutcome),
          Exception,
          effect_dispatch_exception(Exception, EffectOutcome)).

effect_dispatch_exception(rlm_async_cancelled(Id), _) :-
    !,
    throw(rlm_async_cancelled(Id)).
effect_dispatch_exception(Exception,
                          effect_result{state:indeterminate,
                                        source:executor_exception,
                                        attempt:none}) :-
    safe_exception_term(Exception, _).

tool_effect_request(Schema, NormalizedArgs, Details, Request) :-
    Request = tool_effect_request{tool:Schema.name,
                                  args:NormalizedArgs,
                                  details:Details}.

tool_effect_options(RegistryId, Schema, Binding, Limits, _Correlation,
                    EffectOptions) :-
    Tool = Schema.name,
    tool_executor_identity(Binding, ExecutorIdentity),
    Semantics = tool_effect_semantics{
                    tool_executor:ExecutorIdentity,
                    effect:Schema.effect,
                    limits:Limits
                },
    EffectOptions = metadata_options{
                        metadata:tool_effect_metadata{
                            registry:RegistryId,
                            tool:Tool,
                            limits:Limits
                        },
                        semantics:Semantics
                    }.

tool_executor_identity(Binding,
                       tool_executor_identity{version:1,
                                              digest:Digest}) :-
    tool_binding_entrypoints(Binding, Descriptor),
    term_string(Descriptor, Serialized,
                [quoted(true), numbervars(true), ignore_ops(true)]),
    crypto_data_hash(Serialized, Hex,
                     [algorithm(sha256), encoding(utf8)]),
    atom_concat('sha256:', Hex, Digest).

tool_binding_entrypoints(tool_binding(Preflight, Handler),
                         tool_executor_descriptor{
                             preflight:PreflightIdentity,
                             handler:HandlerIdentity
                         }) :-
    trusted_callable_entrypoint(Preflight, 3, PreflightIdentity),
    trusted_callable_entrypoint(Handler, 2, HandlerIdentity).

trusted_callable_entrypoint(Callable, AddedArity,
                            predicate_identity{module:Module,
                                               name:Name,
                                               arity:Arity}) :-
    strip_module(Callable, Module, Plain),
    functor(Plain, Name, BoundArity),
    Arity is BoundArity+AddedArity.

tool_outcome_from_effect(EffectOutcome, Schema, Outcome, Status, Bytes) :-
    is_dict(EffectOutcome, effect_result),
    !,
    (   get_dict(state, EffectOutcome, observed),
        get_dict(observation, EffectOutcome, Observation)
    ->  tool_outcome_from_observation(Observation, Schema, Outcome, Status, Bytes)
    ;   get_dict(state, EffectOutcome, indeterminate)
    ->  Bytes = 0,
        Outcome = error(tool_error{
                            phase:effect,
                            kind:effect_indeterminate,
                            message:"effectful tool attempt is indeterminate and requires reconciliation"
                        }),
        Status = indeterminate
    ;   get_dict(state, EffectOutcome, in_progress)
    ->  Bytes = 0,
        Outcome = error(tool_error{
                            phase:effect,
                            kind:effect_in_progress,
                            message:"effectful tool attempt is still running"
                        }),
        Status = effect_in_progress
    ;   get_dict(state, EffectOutcome, terminal)
    ->  Bytes = 0,
        Outcome = error(tool_error{
                            phase:effect,
                            kind:effect_terminal,
                            message:"effectful tool attempt is in a terminal state"
                        }),
        Status = effect_terminal
    ;   Bytes = 0,
        Outcome = error(tool_error{
                            phase:effect,
                            kind:unknown_effect_result,
                            detail:EffectOutcome
                        }),
        Status = unknown_effect_result
    ).
tool_outcome_from_effect(EffectError, _Schema, error(ToolError),
                         effect_error, 0) :-
    is_dict(EffectError, error),
    !,
    ToolError = tool_error{
                    phase:effect,
                    kind:effect_dispatch_failed,
                    cause:EffectError,
                    message:"effectful tool dispatch failed"
                }.
tool_outcome_from_effect(Other, _Schema,
                         error(tool_error{phase:effect,
                                          kind:unknown_effect_result,
                                          detail:Other}),
                         unknown_effect_result, 0).

tool_outcome_from_observation(Observation, _Schema, Outcome, Status, Bytes) :-
    observation_bytes(Observation, Bytes),
    (   Observation.status == succeeded
    ->  get_dict(value, Observation, Value),
        Outcome = ok(Value),
        Status = ok
    ;   get_dict(value, Observation, Value),
        Outcome = error(Value),
        Status = failed
    ).

observation_bytes(Observation, Bytes) :-
    (   get_dict(usage, Observation, Usage),
        get_dict(output_bytes, Usage, Bytes)
    ->  true
    ;   Bytes = 0 ).

tool_observation_from_outcome(ok(Value), _Status, Bytes, Schema,
                              Observation) :-
    !,
    Observation = observation{status:succeeded,
                              value:Value,
                              usage:usage{units:1, output_bytes:Bytes},
                              provenance:rlm_tool,
                              tool:Schema.name}.
tool_observation_from_outcome(error(Error), _Status, Bytes, Schema,
                              Observation) :-
    Observation = observation{status:failed,
                              value:Error,
                              usage:usage{units:1, output_bytes:Bytes},
                              provenance:rlm_tool,
                              tool:Schema.name}.

/* Adapter submit: recover the trusted binding from the live registry, then
   invoke the canonical tool handler boundary. The callable binding is never
   persisted; the registry identity is metadata only and the stable executor
   digest lives in executable semantics. */

rlm_effect_executor:effect_adapter_submit(rlm_tool, Attempt, Request,
                                          observed(Observation)) :-
    get_dict(tool, Request, Name),
    get_dict(args, Request, Args),
    get_dict(metadata, Attempt, Metadata),
    get_dict(registry, Metadata, RegistryId),
    get_dict(limits, Metadata, Limits),
    (   tool_registry_entry(RegistryId, Name, Schema, Binding)
    ->  perform_tool_effect(Schema,
                            Binding,
                            Args,
                            Limits,
                            CoreOutcome,
                            Status,
                            Bytes),
        tool_observation_from_outcome(CoreOutcome, Status, Bytes, Schema,
                                      Observation)
    ;   Observation = observation{status:failed,
                                  value:tool_error{
                                      phase:effect,
                                      kind:tool_not_registered,
                                      tool:Name,
                                      message:"effectful tool binding is not available in this runtime"
                                  },
                                  usage:usage{units:0, output_bytes:0},
                                  provenance:rlm_tool,
                                  tool:Name}
    ).

/* Edit validator for effectful tools: re-normalize the edited payload,
   re-preflight, re-prepare a fresh #57 ticket, and build the new trusted
   continuation from that ticket. The old attempt ticket can never execute. */

tool_effect_edit_validate(Context, Registry, Schema, Binding, Limits,
                          Correlation, _OldRequest, _OldEffectOptions,
                          Edited0, Operation, Continuation) :-
    edited_args(Edited0, EditedArgs),
    validate_schema(Schema.arguments, EditedArgs, args, ok),
    preflight_tool(Binding, EditedArgs, Limits.time_limit,
                   ok(NormalizedArgs, Details)),
    registry_id(Registry, RegistryId),
    tool_effect_request(Schema, NormalizedArgs, Details, Request),
    tool_effect_options(RegistryId, Schema, Binding, Limits,
                        Correlation, EffectOptions),
    rlm_effect_executor:effect_prepare(rlm_tool, tool, Request,
                                       EffectOptions, PrepareDecision),
    (   PrepareDecision = execute(Ticket)
    ->  true
    ;   throw(tool_fault(effect_prepare_failed_for_edit(PrepareDecision)))
    ),
    BaseOperation = authority_operation{
                        name:Schema.name,
                        effect:Schema.effect,
                        capability:Schema.capability,
                        args:NormalizedArgs,
                        details:Details
                    },
    rlm_effect_authority:effect_authority_operation(Ticket, BaseOperation,
                                                     Correlation, Operation),
    Continuation = rlm_tool:tool_effect_pending_execute(Context,
                                                        Schema,
                                                        Ticket).

perform_tool_effect(Schema,
                    tool_binding(_, Handler),
                    Args,
                    Limits,
                    Outcome,
                    Status,
                    Bytes) :-
    call_tool_with_limit(Handler, Args, Limits.time_limit, CallOutcome),
    invoke_after_call(CallOutcome, Schema, Limits, Outcome, Status, Bytes).

call_tool_with_limit(Handler, Args, TimeLimit, Outcome) :-
    catch(call_with_time_limit(TimeLimit,
                               call_tool_handler(Handler, Args, Outcome)),
          Exception,
          timed_tool_exception(Exception, Outcome)).

call_tool_handler(Handler, Args, Outcome) :-
    (   call(Handler, Args, Value)
    ->  Outcome = ok(Value)
    ;   Outcome = error(tool_error{
                            phase:invoke,
                            kind:handler_failed,
                            message:"tool handler failed without returning a value"
                        })
    ).

timed_tool_exception(Exception, _) :-
    tool_control_exception(Exception),
    !,
    throw(Exception).
timed_tool_exception(time_limit_exceeded,
                     error(tool_error{
                               phase:invoke,
                               kind:timeout,
                               message:"tool invocation exceeded its wall-time limit"
                           })) :- !.
timed_tool_exception(time_limit_exceeded(_),
                     error(tool_error{
                               phase:invoke,
                               kind:timeout,
                               message:"tool invocation exceeded its wall-time limit"
                           })) :- !.
timed_tool_exception(Exception,
                     error(tool_error{
                               phase:invoke,
                               kind:handler_exception,
                               exception:Safe,
                               message:"tool handler raised an exception"
                           })) :-
    safe_exception(Exception, Safe).

invoke_after_call(error(Error), _, _, error(Error), Status, 0) :-
    !,
    error_status(Error, Status).
invoke_after_call(ok(Value), Schema, Limits, Outcome, Status, Bytes) :-
    validate_schema(Schema.result, Value, result, ResultOutcome),
    invoke_after_result(ResultOutcome,
                        Value,
                        Schema,
                        Limits,
                        Outcome,
                        Status,
                        Bytes).

invoke_after_result(error(Error), _, _, _, error(Error), invalid_result, 0) :- !.
invoke_after_result(ok, Value, Schema, Limits, Outcome, Status, Bytes) :-
    value_bytes(Value, Bytes0),
    (   Bytes0 =< Limits.max_output_bytes
    ->  Bytes = Bytes0,
        Status = ok,
        Outcome = ok(Value)
    ;   Bytes = Bytes0,
        Status = oversized_output,
        Outcome = error(tool_error{
                            phase:normalize,
                            kind:oversized_output,
                            tool:Schema.name,
                            output_bytes:Bytes0,
                            limit:Limits.max_output_bytes,
                            message:"tool output exceeds its byte limit"
                        })
    ).

error_status(Error, Status) :-
    (   is_dict(Error), get_dict(kind, Error, Kind)
    ->  Status = Kind
    ;   Status = error
    ).

attach_trace(ok(Value), Trace,
             ok(tool_execution{value:Value, trace:Trace})) :- !.
attach_trace(error(Error0), Trace, error(Error)) :-
    !,
    (   is_dict(Error0)
    ->  put_dict(trace, Error0, Trace, Error)
    ;   Error = tool_error{
                    phase:invoke,
                    kind:tool_error,
                    cause:Error0,
                    trace:Trace,
                    message:"tool invocation failed"
                }
    ).
attach_trace(approval_required(Pending0), Trace,
             approval_required(Pending)) :-
    put_dict(trace, Pending0, Trace, Pending).

/* -------------------------------------------------------------------------
 * Exact operation construction, editing and context
 * ---------------------------------------------------------------------- */

tool_edit_validate(Schema,
                   Binding,
                   Options,
                   Limits,
                   Context,
                   Correlation,
                   Edited0,
                   Operation,
                   Continuation) :-
    edited_args(Edited0, EditedArgs),
    validate_schema(Schema.arguments, EditedArgs, args, ok),
    preflight_tool(Binding, EditedArgs, Limits.time_limit,
                   ok(NormalizedArgs, Details)),
    Operation = authority_operation{
                    name:Schema.name,
                    effect:Schema.effect,
                    capability:Schema.capability,
                    args:NormalizedArgs,
                    details:Details,
                    correlation:Correlation
                },
    Continuation = rlm_tool:tool_pending_execute(Schema,
                                                 Binding,
                                                 NormalizedArgs,
                                                 Limits,
                                                 Context),
    (Options = _ -> true).

edited_args(Edited, Args) :-
    is_dict(Edited),
    get_dict(args, Edited, Args),
    !.
edited_args(Args, Args) :- is_dict(Args), !.
edited_args(Edited, _) :- throw(tool_fault(invalid_edited_operation(Edited))).

tool_authority_context(Registry, Options, Context) :-
    (   option_ground(authority_context, Options, Explicit), Explicit \== none
    ->  Context = Explicit
    ;   rlm_async:rlm_async_current_metadata(Current),
        metadata_context(Current, CurrentContext),
        CurrentContext \== none
    ->  Context = CurrentContext
    ;   option_ground(session_id, Options, Session), Session \== none
    ->  Context = session(Session)
    ;   option_ground(runtime_id, Options, Runtime), Runtime \== none
    ->  Context = runtime(Runtime)
    ;   Registry = tool_registry(Id),
        Context = tool_registry(Id)
    ).

metadata_context(Current, Context) :-
    is_dict(Current),
    get_dict(authority_context, Current, Found),
    Found \== none,
    !,
    Context = Found.
metadata_context(Current, session(Session)) :-
    is_dict(Current),
    get_dict(session_id, Current, Session),
    Session \== none,
    !.
metadata_context(Current, agent(Runtime, Agent)) :-
    is_dict(Current),
    get_dict(runtime_id, Current, Runtime),
    get_dict(agent_id, Current, Agent),
    Runtime \== none,
    Agent \== none,
    !.
metadata_context(Current, graph(Runtime, Graph, Run)) :-
    is_dict(Current),
    get_dict(runtime_id, Current, Runtime),
    get_dict(graph_id, Current, Graph),
    get_dict(run_id, Current, Run),
    Runtime \== none,
    Graph \== none,
    Run \== none,
    !.
metadata_context(Current, runtime(Runtime)) :-
    is_dict(Current),
    get_dict(runtime_id, Current, Runtime),
    Runtime \== none,
    !.
metadata_context(_, none).

tool_correlation(Options, Correlation) :-
    rlm_async:rlm_async_current_metadata(Current),
    correlation_field(trace_id, Options, Current, TraceId),
    correlation_field(session_id, Options, Current, SessionId),
    correlation_field(runtime_id, Options, Current, RuntimeId),
    correlation_field(agent_id, Options, Current, AgentId),
    correlation_field(graph_id, Options, Current, GraphId),
    correlation_field(run_id, Options, Current, RunId),
    Correlation = correlation{trace_id:TraceId,
                              session_id:SessionId,
                              runtime_id:RuntimeId,
                              agent_id:AgentId,
                              graph_id:GraphId,
                              run_id:RunId}.

correlation_field(Name, Options, Current, Value) :-
    (   option_ground(Name, Options, Found), Found \== none
    ->  Value = Found
    ;   is_dict(Current), get_dict(Name, Current, CurrentFound)
    ->  Value = CurrentFound
    ;   Value = none
    ).

option_ground(Name, Options, Value) :-
    metadata_option(Name, Options, none, Value).

/* -------------------------------------------------------------------------
 * Plan-runtime adapter
 * ---------------------------------------------------------------------- */

tool_registry_runtime_tools(Registry, Capabilities, Tools) :-
    tool_registry_runtime_tools(Registry, Capabilities, [], Tools).

tool_registry_runtime_tools(Registry, Capabilities, InvocationOptions, Tools) :-
    registry_id(Registry, Id),
    findall(tool(Name,
                 rlm_tool:registry_plan_handler(Registry,
                                                Capabilities,
                                                InvocationOptions,
                                                Name)),
            tool_registry_entry(Id, Name, _, _),
            Tools).

registry_plan_handler(Registry, Capabilities, InvocationOptions, Name, Args,
                      Envelope) :-
    tool_invoke_execute(Registry,
                        Capabilities,
                        Name,
                        Args,
                        InvocationOptions,
                        Result),
    Outcome = Result.outcome,
    Trace = Result.trace,
    plan_envelope(Outcome, Trace, Envelope).

plan_envelope(ok(Execution), Trace,
              tool_result{value:Execution.value,
                          authorization:Trace.authorization,
                          authority:Trace.authority,
                          status:Trace.status,
                          fingerprint:Trace.fingerprint,
                          approval_id:Trace.approval_id,
                          output_bytes:Trace.output_bytes,
                          elapsed_ms:Trace.elapsed_ms}) :- !.
plan_envelope(approval_required(Pending), Trace,
              tool_result{value:Pending,
                          authorization:pending,
                          authority:Trace.authority,
                          status:approval_required,
                          fingerprint:Trace.fingerprint,
                          approval_id:Trace.approval_id,
                          output_bytes:0,
                          elapsed_ms:Trace.elapsed_ms}) :- !.
plan_envelope(error(Error), _, _) :-
    throw(error(rlm_tool(Error), _)).

/* -------------------------------------------------------------------------
 * Built-in read-only project tool
 * ---------------------------------------------------------------------- */

register_project_read_tool(Registry, Root0, Options, Outcome) :-
    catch(register_project_read_tool_(Registry, Root0, Options, Outcome),
          Exception,
          tool_api_exception(register_project_read, Exception, Outcome)).

register_project_read_tool_(Registry, Root0, Options, Outcome) :-
    normalize_root(Root0, Root),
    option_value(max_file_bytes, Options, 8192, MaxFileBytes),
    option_value(time_limit, Options, 1.0, TimeLimit),
    require_positive_integer(MaxFileBytes, max_file_bytes),
    require_positive_number(TimeLimit, time_limit),
    project_read_schema(MaxFileBytes, TimeLimit, Schema),
    Preflight = rlm_tool:project_read_preflight(Root, MaxFileBytes),
    Handler = rlm_tool:project_read_handler,
    tool_register(Registry,
                  Schema,
                  tool_handler(Preflight, Handler),
                  Outcome).

project_read_schema(MaxBytes, TimeLimit, Schema) :-
    MaxOutputBytes is MaxBytes+1024,
    Schema = tool_schema{
                 name:project_read,
                 description:"Read one UTF-8 regular file beneath an explicitly registered project root",
                 capability:tool(project_read),
                 effect:read,
                 arguments:_{
                     type:object,
                     required:[path],
                     additional_properties:false,
                     properties:_{path:_{type:string}}
                 },
                 result:_{
                     type:object,
                     required:[path,content,bytes,truncated],
                     additional_properties:false,
                     properties:_{
                         path:_{type:string},
                         content:_{type:string},
                         bytes:_{type:integer},
                         truncated:_{type:boolean}
                     }
                 },
                 limits:tool_limits{
                     time_limit:TimeLimit,
                     max_output_bytes:MaxOutputBytes
                 }
             }.

project_read_preflight(Root, MaxFileBytes, Args,
                       json{path:Relative, absolute:Absolute, bytes:Size},
                       operation_details{target_path:Absolute,
                                         project_root:Root}) :-
    get_dict(path, Args, Path0),
    text_string(Path0, Relative),
    safe_relative_path(Relative, Segments),
    reject_symlink_components(Root, Segments),
    absolute_file_name(Relative,
                       Absolute,
                       [ relative_to(Root),
                         access(read),
                         file_type(regular),
                         file_errors(fail),
                         solutions(first)
                       ]),
    path_within_root(Root, Absolute),
    size_file(Absolute, Size),
    Size =< MaxFileBytes.

project_read_handler(Args, Result) :-
    Relative = Args.path,
    Absolute = Args.absolute,
    Size = Args.bytes,
    setup_call_cleanup(open(Absolute, read, Stream, [encoding(utf8)]),
                       read_string(Stream, _, Content),
                       close(Stream)),
    Result = json{path:Relative,
                  content:Content,
                  bytes:Size,
                  truncated:false}.

normalize_root(Root0, Root) :-
    absolute_file_name(Root0,
                       Root0Abs,
                       [ file_type(directory),
                         access(read),
                         file_errors(fail),
                         solutions(first)
                       ]),
    strip_trailing_slash(Root0Abs, Root).

safe_relative_path(Path, Segments) :-
    string(Path),
    Path \== "",
    \+ sub_string(Path, 0, 1, _, "/"),
    \+ sub_string(Path, _, _, _, "\\"),
    \+ sub_string(Path, _, _, _, "\u0000"),
    split_string(Path, "/", "", Segments),
    Segments \== [],
    maplist(safe_path_segment, Segments).

safe_path_segment(Segment) :-
    Segment \== "",
    Segment \== ".",
    Segment \== "..".

reject_symlink_components(Root, Segments) :-
    reject_symlink_components_(Segments, Root).

reject_symlink_components_([], _).
reject_symlink_components_([Segment|Segments], Parent) :-
    atom_string(SegmentAtom, Segment),
    directory_file_path(Parent, SegmentAtom, Candidate),
    \+ read_link(Candidate, _, _),
    reject_symlink_components_(Segments, Candidate).

path_within_root('/', Absolute) :-
    sub_atom(Absolute, 0, 1, _, '/'),
    !.
path_within_root(Root, Absolute) :-
    atom_concat(Root, '/', Prefix),
    sub_atom(Absolute, 0, _, _, Prefix).

strip_trailing_slash('/', '/') :- !.
strip_trailing_slash(Path0, Path) :-
    (   atom_concat(Path, '/', Path0), Path \== ''
    ->  true
    ;   Path = Path0
    ).

/* -------------------------------------------------------------------------
 * Schema validation
 * ---------------------------------------------------------------------- */

normalize_tool_schema(Schema0, Schema) :-
    require_schema_container(Schema0),
    require_schema_key(Schema0, name, Name),
    require_tool_name(Name),
    require_schema_key(Schema0, capability, Capability),
    must_be_capability(Capability),
    require_matching_tool_capability(Name, Capability),
    require_schema_key(Schema0, effect, Effect),
    require_effect(Effect),
    require_schema_key(Schema0, arguments, Arguments0),
    require_schema_key(Schema0, result, Result0),
    validate_schema_definition(Arguments0),
    validate_schema_definition(Result0),
    normalize_authority_value(Arguments0, Arguments),
    normalize_authority_value(Result0, Result),
    schema_description(Schema0, Description),
    schema_limits(Schema0, Limits),
    Schema = tool_schema{
                 name:Name,
                 description:Description,
                 capability:Capability,
                 effect:Effect,
                 arguments:Arguments,
                 result:Result,
                 limits:Limits
             }.

require_effect(Effect) :-
    rlm_authority:rlm_effect_class(Effect),
    !.
require_effect(Effect) :-
    throw(tool_fault(invalid_effect_class(Effect))).

require_schema_container(Schema) :- is_dict(Schema), !.
require_schema_container(Schema) :-
    throw(tool_fault(invalid_schema_container(Schema))).

require_tool_name(Name) :- atom(Name), Name \== '', !.
require_tool_name(Name) :- throw(tool_fault(invalid_tool_name(Name))).

require_matching_tool_capability(Name, tool(Name)) :- !.
require_matching_tool_capability(Name, Capability) :-
    throw(tool_fault(tool_capability_mismatch(Name, Capability))).

schema_description(Schema, Description) :-
    (   get_dict(description, Schema, Value)
    ->  ( text_string(Value, Description)
        -> true
        ;  throw(tool_fault(invalid_description(Value)))
        )
    ;   Description = ""
    ).

schema_limits(Schema, Limits) :-
    (   get_dict(limits, Schema, Limits0)
    ->  require_limits_dict(Limits0)
    ;   Limits0 = _{}
    ),
    limit_value(time_limit, Limits0, 1.0, TimeLimit),
    limit_value(max_output_bytes, Limits0, 4096, MaxBytes),
    require_positive_number(TimeLimit, time_limit),
    require_positive_integer(MaxBytes, max_output_bytes),
    Limits = tool_limits{time_limit:TimeLimit,
                         max_output_bytes:MaxBytes}.

require_limits_dict(Limits) :- is_dict(Limits), !.
require_limits_dict(Limits) :- throw(tool_fault(invalid_limits(Limits))).

validate_schema_definition(Schema) :-
    (   is_dict(Schema),
        get_dict(type, Schema, Type),
        memberchk(Type, [any,string,integer,number,boolean,list,array,object])
    ->  validate_schema_definition_type(Type, Schema)
    ;   throw(tool_fault(invalid_schema(Schema)))
    ).

validate_schema_definition_type(object, Schema) :-
    !,
    validate_object_schema_properties(Schema),
    validate_object_schema_required(Schema).
validate_schema_definition_type(list, Schema) :-
    !,
    (   get_dict(items, Schema, ItemSchema)
    ->  validate_schema_definition(ItemSchema)
    ;   true
    ).
validate_schema_definition_type(array, Schema) :-
    !,
    (   get_dict(items, Schema, ItemSchema)
    ->  validate_schema_definition(ItemSchema)
    ;   true
    ).
validate_schema_definition_type(_, _).

validate_object_schema_properties(Schema) :-
    (   get_dict(properties, Schema, Properties)
    ->  ( is_dict(Properties)
        -> dict_pairs(Properties, _, Pairs),
           maplist(validate_property_schema, Pairs)
        ;  throw(tool_fault(invalid_properties(Properties)))
        )
    ;   true
    ).

validate_object_schema_required(Schema) :-
    (   get_dict(required, Schema, Required)
    ->  ( is_list(Required), maplist(atom, Required)
        -> true
        ;  throw(tool_fault(invalid_required_fields(Required)))
        )
    ;   true
    ).

validate_property_schema(_-Schema) :- validate_schema_definition(Schema).

validate_schema(Schema, Value, Path, Outcome) :-
    catch(( validate_schema_value(Schema, Value, Path), Outcome = ok ),
          tool_fault(Fault),
          schema_fault(Path, Fault, Outcome)).

validate_schema_value(Schema, Value, Path) :-
    get_dict(type, Schema, Type),
    validate_type(Type, Schema, Value, Path).

validate_type(any, _, _, _) :- !.
validate_type(string, _, Value, _) :- text_string(Value, _), !.
validate_type(integer, _, Value, _) :- integer(Value), !.
validate_type(number, _, Value, _) :- number(Value), !.
validate_type(boolean, _, Value, _) :- memberchk(Value, [true,false]), !.
validate_type(list, Schema, Value, Path) :-
    is_list(Value),
    !,
    (   get_dict(items, Schema, ItemSchema)
    ->  validate_list_items(Value, ItemSchema, Path, 0)
    ;   true
    ).
validate_type(array, Schema, Value, Path) :-
    is_list(Value),
    !,
    (   get_dict(items, Schema, ItemSchema)
    ->  validate_list_items(Value, ItemSchema, Path, 0)
    ;   true
    ).
validate_type(object, Schema, Value, Path) :-
    is_dict(Value),
    !,
    validate_object(Schema, Value, Path).
validate_type(Type, _, Value, Path) :-
    throw(tool_fault(schema_type_mismatch(Path, Type, Value))).

validate_list_items([], _, _, _).
validate_list_items([Value|Values], Schema, Path, Index) :-
    validate_schema_value(Schema, Value, Path-Index),
    Next is Index+1,
    validate_list_items(Values, Schema, Path, Next).

validate_object(Schema, Value, Path) :-
    (   get_dict(required, Schema, Required)
    ->  maplist(require_object_key(Value, Path), Required)
    ;   true
    ),
    (   get_dict(properties, Schema, Properties)
    ->  validate_object_properties(Properties, Value, Path),
        validate_additional_properties(Schema, Properties, Value, Path)
    ;   true
    ).

require_object_key(Value, Path, Key) :-
    (   get_dict(Key, Value, _)
    ->  true
    ;   throw(tool_fault(missing_required_field(Path, Key)))
    ).

validate_object_properties(Properties, Value, Path) :-
    dict_pairs(Properties, _, Pairs),
    maplist(validate_present_property(Value, Path), Pairs).

validate_present_property(Value, Path, Key-Schema) :-
    (   get_dict(Key, Value, FieldValue)
    ->  validate_schema_value(Schema, FieldValue, Path-Key)
    ;   true
    ).

validate_additional_properties(Schema, Properties, Value, Path) :-
    (   get_dict(additional_properties, Schema, false)
    ->  dict_keys(Properties, Allowed),
        dict_keys(Value, Actual),
        subtract(Actual, Allowed, Extra),
        ( Extra == []
        -> true
        ;  throw(tool_fault(unexpected_fields(Path, Extra)))
        )
    ;   true
    ).

schema_fault(Path, Fault,
             error(tool_error{
                       phase:schema,
                       kind:schema_validation_failed,
                       path:Path,
                       detail:Fault,
                       message:"tool value does not match its declared schema"
                   })).

/* -------------------------------------------------------------------------
 * Authority-value normalization and helpers
 * ---------------------------------------------------------------------- */

normalize_authority_value(Value, _) :-
    var(Value),
    !,
    throw(tool_fault(nonground_authority_value)).
normalize_authority_value(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, Tag0, Pairs0),
    normalize_dict_tag(Tag0, Tag),
    maplist(normalize_authority_pair, Pairs0, Pairs),
    dict_pairs(Value, Tag, Pairs).
normalize_authority_value(Value0, Value) :-
    is_list(Value0),
    !,
    maplist(normalize_authority_value, Value0, Value).
normalize_authority_value(Value0, Value) :-
    compound(Value0),
    !,
    Value0 =.. [Functor|Args0],
    maplist(normalize_authority_value, Args0, Args),
    Value =.. [Functor|Args].
normalize_authority_value(Value, Value) :- atomic(Value), !.
normalize_authority_value(Value, _) :-
    throw(tool_fault(invalid_authority_value(Value))).

normalize_dict_tag(Tag0, json) :- var(Tag0), !.
normalize_dict_tag(Tag, Tag) :- atom(Tag), !.
normalize_dict_tag(Tag, _) :- throw(tool_fault(invalid_dict_tag(Tag))).

normalize_authority_pair(Key-Value0, Key-Value) :-
    normalize_authority_value(Value0, Value).

registry_id(tool_registry(Id), Id) :- tool_registry_alive(Id), !.
registry_id(Registry, _) :-
    throw(tool_fault(invalid_or_stale_registry(Registry))).

require_schema_key(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(tool_fault(missing_schema_field(Key)))
    ).

effective_limits(Spec, Options,
                 tool_limits{time_limit:TimeLimit,
                             max_output_bytes:MaxBytes}) :-
    option_value(time_limit, Options, Spec.time_limit, RequestedTime),
    option_value(max_output_bytes, Options, Spec.max_output_bytes,
                 RequestedBytes),
    require_positive_number(RequestedTime, time_limit),
    require_positive_integer(RequestedBytes, max_output_bytes),
    TimeLimit is min(Spec.time_limit, RequestedTime),
    MaxBytes is min(Spec.max_output_bytes, RequestedBytes).

limit_value(Key, Dict, Default, Value) :-
    (   is_dict(Dict), get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

option_value(Name, Options, Default, Value) :-
    (   is_list(Options),
        member(Option, Options),
        nonvar(Option),
        Option =.. [Name, Found]
    ->  Value = Found
    ;   Value = Default
    ).

require_positive_integer(Value, _) :- integer(Value), Value > 0, !.
require_positive_integer(Value, Field) :-
    throw(tool_fault(invalid_positive_integer(Field, Value))).

require_positive_number(Value, _) :- number(Value), Value > 0, !.
require_positive_number(Value, Field) :-
    throw(tool_fault(invalid_positive_number(Field, Value))).

text_string(Value, String) :- string(Value), !, String = Value.
text_string(Value, String) :- atom(Value), !, atom_string(Value, String).

value_bytes(Value, Bytes) :-
    term_string(Value, Text, [quoted(true), numbervars(true)]),
    string_bytes(Text, Octets, utf8),
    length(Octets, Bytes).

value_shape(Value, Shape) :-
    (   var(Value) -> Shape = variable
    ;   is_dict(Value) -> Shape = dict
    ;   is_list(Value) -> Shape = list
    ;   compound(Value) -> functor(Value, Name, Arity), Shape = Name/Arity
    ;   atom(Value) -> Shape = atom
    ;   string(Value) -> Shape = string
    ;   number(Value) -> Shape = number
    ;   Shape = other
    ).

dict_value_default(Key, Dict, Default, Value) :-
    (   is_dict(Dict), get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

tool_api_exception(Phase, tool_fault(Fault), error(Error)) :-
    !,
    Error = tool_error{
                phase:Phase,
                kind:invalid_tool_operation,
                detail:Fault,
                message:"tool operation is invalid"
            }.
tool_api_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = tool_error{
                phase:Phase,
                kind:tool_runtime_error,
                exception:Safe,
                message:"tool operation failed"
            }.

invoke_exception(Exception, _, _, _, _, _, _, _) :-
    tool_control_exception(Exception),
    !,
    throw(Exception).
invoke_exception(tool_fault(Fault), error(Error), denied, unknown,
                 invalid_tool, 0, none, none) :-
    !,
    Error = tool_error{
                phase:invoke,
                kind:invalid_tool_operation,
                detail:Fault,
                message:"tool invocation is invalid"
            }.
invoke_exception(capability_fault(Fault), error(Error), denied, unknown,
                 invalid_capabilities, 0, none, none) :-
    !,
    Error = tool_error{
                phase:authorize,
                kind:invalid_capabilities,
                detail:Fault,
                message:"tool capability set is invalid"
            }.
invoke_exception(Exception, error(Error), denied, unknown,
                 runtime_error, 0, none, none) :-
    safe_exception(Exception, Safe),
    Error = tool_error{
                phase:invoke,
                kind:tool_runtime_error,
                exception:Safe,
                message:"tool invocation failed"
            }.

tool_control_exception(rlm_async_cancelled(_)).
tool_control_exception(rlm_cancelled(_)).
tool_control_exception(chain_cancelled(_)).
tool_control_exception(graph_cancelled(_)).
tool_control_exception(cancelled(_)).
tool_control_exception('$aborted').
tool_control_exception(abort).

safe_exception(Exception, Safe) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).
