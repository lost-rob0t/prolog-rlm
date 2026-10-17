:- module(rlm_zara_runtime,
          [ zara_runtime_protocol/1,
            zara_runtime_descriptor/1,
            zara_runtime_health/1,
            zara_runtime_execute/2,
            zara_runtime_cancel/2,
            zara_runtime_pending/3,
            zara_runtime_approval/5,
            zara_runtime_approval_status/4,
            zara_runtime_resume/4,
            zara_runtime_set_profiles/1,
            zara_runtime_set_host_tools/2,
            zara_runtime_set_host_callback/4,
            zara_runtime_set_host_callback/5,
            zara_runtime_set_bootstrap_token/1,
            zara_runtime_server_start/1,
            zara_runtime_server_stop/0
          ]).

/** <module> ZARA-RUNTIME/1 adapter for Prolog-RLM

This module is a transport adapter over the public Prolog-RLM runtime.  It does
not own a second planner/provider/tool stack.  The HTTP facade binds to
localhost only and accepts provider credentials by environment-variable name;
literal secrets are never accepted on the wire.

The first bridge slice is buffered HTTP plus request cancellation.  The
descriptor therefore reports streaming=false until the ordered event/SSE
surface is implemented and tested.
*/

:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_open)).
:- use_module(library(http/json)).
:- use_module(library(lists)).
:- use_module(library(uri)).
:- use_module(library(uuid)).
:- use_module(rlm).
:- use_module(rlm_tool, []).
:- use_module(rlm_effect, []).
:- use_module(rlm_authority, []).
:- use_module(rlm_async, []).
:- use_module(rlm_chain,
              [ openrouter_provider/2,
                openai_compatible_provider/4,
                default_openrouter_model/1
              ]).

:- dynamic zara_server_port/1.
:- dynamic zara_request_token/2.
:- dynamic zara_runtime_profile/1.
:- dynamic zara_host_registry/1.
:- dynamic zara_host_token/1.
:- dynamic zara_host_callback/5.
:- dynamic zara_bootstrap_token/1.
:- dynamic zara_retained_registry/3.
:- dynamic zara_retained_completion/4.

:- http_handler(root('zara-runtime/v1/discover'),
                zara_discover_handler,
                [method(get)]).
:- http_handler(root('zara-runtime/v1/health'),
                zara_health_handler,
                [method(get)]).
:- http_handler(root('zara-runtime/v1/generate'),
                zara_generate_handler,
                [method(post)]).
:- http_handler(root('zara-runtime/v1/cancel'),
                zara_cancel_handler,
                [method(post)]).
:- http_handler(root('zara-runtime/v1/host-config'),
                zara_host_config_handler,
                [method(post)]).
:- http_handler(root('zara-runtime/v1/host-pending'),
                zara_host_pending_handler,
                [method(post)]).
:- http_handler(root('zara-runtime/v1/host-approval'),
                zara_host_approval_handler,
                [method(post)]).
:- http_handler(root('zara-runtime/v1/host-approval-status'),
                zara_host_approval_status_handler,
                [method(post)]).
:- http_handler(root('zara-runtime/v1/resume'),
                zara_resume_handler,
                [method(post)]).

zara_runtime_protocol("ZARA-RUNTIME/1").

zara_runtime_descriptor(Descriptor) :-
    rlm:rlm_version(Version0),
    text_string(Version0, Version),
    zara_runtime_protocol(Protocol),
    findall(Profile, zara_runtime_profile(Profile), Profiles),
    Descriptor = _{
        id:"prolog-rlm",
        display_name:"Prolog-RLM",
        protocol:Protocol,
        runtime_version:Version,
        implementation_version:Version,
        installed:true,
        available:true,
        health:"ready",
        locality:"local_sidecar",
        transport:"loopback_http",
        capabilities:["direct", "rlm", "context.inline", "cancel", "trace"],
        profiles:Profiles,
        provider_control:"runtime",
        model_control:"runtime",
        supports_streaming:false,
        supports_cancel:true,
        supports_context_handles:false,
        supports_host_tools:HostTools,
        provenance:"prolog-rlm:local"
    },
    ( (zara_host_registry(_) ; zara_host_callback(_, _, _, _, _))
    -> HostTools = true
    ;  HostTools = false
    ).

zara_runtime_health(Health) :-
    zara_runtime_descriptor(Descriptor),
    Health = _{
        protocol:Descriptor.protocol,
        runtime_id:Descriptor.id,
        health:Descriptor.health,
        available:Descriptor.available
    }.

zara_runtime_execute(Request, Reply) :-
    catch(zara_runtime_execute_(Request, Reply),
          Error,
          zara_exception_reply(Request, Error, Reply)).

zara_runtime_execute_(Request, Reply) :-
    require_request_dict(Request),
    require_protocol(Request),
    request_id(Request, RequestId),
    request_mode(Request, Mode),
    request_prompt(Request, Prompt),
    request_context(Request, Context),
    request_provider(Request, ProviderName, Provider),
    request_budget(Request, Budget, MaxTokens),
    rlm:rlm_cancellation_token(Token),
    setup_call_cleanup(
        register_request(RequestId, Token),
        ( request_host_tools(RequestId, Request,
                             ToolRegistry, ToolCapabilities),
          setup_call_cleanup(
              true,
              execute_mode(Mode,
                     RequestId,
                     Prompt,
                     Context,
                     ProviderName,
                     Provider,
                     Budget,
                     MaxTokens,
                     ToolRegistry,
                     ToolCapabilities,
                     Token,
                     Reply),
              release_host_registry(RequestId, ToolRegistry)) ),
        unregister_request(RequestId, Token)).

zara_runtime_set_host_tools("", []) :-
    !,
    with_mutex(zara_runtime_host_tools,
               replace_host_registry(none, none)).
zara_runtime_set_host_tools(Token0, Specs) :-
    require_host_token(Token0, Token),
    ( is_list(Specs), Specs \== [],
      length(Specs, Count), Count =< 16
    -> true
    ;  throw(zara_runtime_fault(invalid_host_tools))
    ),
    rlm_tool:tool_registry_create(Registry),
    catch(( maplist(register_host_spec(Registry), Specs),
            with_mutex(zara_runtime_host_tools,
                       replace_host_registry(Registry, Token))
          ),
          Error,
          ( rlm_tool:tool_registry_destroy(Registry), throw(Error) )).

zara_runtime_set_host_callback(Token0, Endpoint0, Generation, Schemas) :-
    zara_runtime_set_host_callback(Token0, Endpoint0, none,
                                   Generation, Schemas).

zara_runtime_set_host_callback(Token0, Endpoint0, EffectEndpoint0,
                               Generation, Schemas) :-
    require_host_token(Token0, Token),
    require_callback_endpoint(Endpoint0, Endpoint),
    require_effect_endpoint(EffectEndpoint0, EffectEndpoint),
    ( integer(Generation), Generation >= 0,
      is_list(Schemas), Schemas \== [],
      length(Schemas, Count), Count =< 16
    -> true
    ;  throw(zara_runtime_fault(invalid_host_callback))
    ),
    validate_callback_schemas(Schemas),
    require_effect_store(Schemas, EffectEndpoint),
    with_mutex(zara_runtime_host_tools,
               ( replace_host_registry(none, none),
                 assertz(zara_host_callback(Token, Endpoint, EffectEndpoint,
                                            Generation, Schemas)),
                 assertz(zara_host_token(Token))
               )).

zara_runtime_set_bootstrap_token("") :-
    !,
    retractall(zara_bootstrap_token(_)).
zara_runtime_set_bootstrap_token(Token0) :-
    require_host_token(Token0, Token),
    with_mutex(zara_runtime_host_tools,
               ( retractall(zara_bootstrap_token(_)),
                 assertz(zara_bootstrap_token(Token))
               )).

validate_callback_schemas(Schemas) :-
    rlm_tool:tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        maplist(validate_callback_schema(Registry), Schemas),
        rlm_tool:tool_registry_destroy(Registry)).

require_effect_store(Schemas, EffectEndpoint) :-
    ( member(Schema, Schemas), Schema.effect \== read
    -> ( EffectEndpoint == none
       -> throw(zara_runtime_fault(invalid_host_effect_endpoint))
       ;  rlm_effect:rlm_effect_store_attached(_)
       -> true
       ;  throw(zara_runtime_fault(effect_store_required))
       )
    ; true
    ).

validate_callback_schema(Registry, Schema) :-
    rlm_tool:tool_register(Registry, Schema,
                           rlm_zara_runtime:callback_unreachable,
                           ok(_)),
    !.
validate_callback_schema(_, _) :-
    throw(zara_runtime_fault(invalid_host_callback_schema)).

callback_unreachable(_, _) :-
    throw(zara_runtime_fault(host_callback_unavailable)).

require_host_token(Token0, Token) :-
    normalize_identifier(host_token, Token0, Token),
    string_length(Token, Length),
    ( Length >= 16,
      string_codes(Token, Codes),
      maplist(host_token_code, Codes)
    -> true
    ;  throw(zara_runtime_fault(invalid_host_token))
    ).

require_callback_endpoint(Endpoint0, Endpoint) :-
    text_string(Endpoint0, Endpoint),
    uri_components(Endpoint,
                   uri_components(http, Authority,
                                  '/zara-host-tool/v1/read', Search, Fragment)),
    var(Search), var(Fragment),
    uri_authority_components(Authority,
                             uri_authority(User, Password,
                                           '127.0.0.1', Port)),
    var(User), var(Password),
    integer(Port), Port >= 1, Port =< 65535,
    !.
require_callback_endpoint(_, _) :-
    throw(zara_runtime_fault(invalid_host_callback_endpoint)).

require_effect_endpoint(none, none) :- !.
require_effect_endpoint(Endpoint0, Endpoint) :-
    text_string(Endpoint0, Endpoint),
    uri_components(Endpoint,
                   uri_components(http, Authority,
                                  '/zara-host-tool/v1/effect', Search, Fragment)),
    var(Search), var(Fragment),
    uri_authority_components(Authority,
                             uri_authority(User, Password,
                                           '127.0.0.1', Port)),
    var(User), var(Password),
    integer(Port), Port >= 1, Port =< 65535,
    !.
require_effect_endpoint(_, _) :-
    throw(zara_runtime_fault(invalid_host_effect_endpoint)).

host_token_code(Code) :-
    ( between(0'a, 0'z, Code)
    ; between(0'A, 0'Z, Code)
    ; between(0'0, 0'9, Code)
    ),
    !.
host_token_code(0'-).
host_token_code(0'_).

register_host_spec(_, host_tool(Schema, _)) :-
    is_dict(Schema),
    get_dict(effect, Schema, Effect),
    Effect \== read,
    !,
    throw(zara_runtime_fault(effectful_host_tool_unsupported)).
register_host_spec(Registry, host_tool(Schema, Handler)) :-
    rlm_tool:tool_register(Registry, Schema, Handler, ok(_)),
    !.
register_host_spec(_, _) :-
    throw(zara_runtime_fault(invalid_host_tool_spec)).

replace_host_registry(Registry, Token) :-
    with_mutex(zara_runtime_requests,
               ( zara_request_token(_, _)
               -> throw(zara_runtime_fault(host_tools_busy))
               ;  true
               )),
    ( zara_retained_registry(_, _, _)
    -> throw(zara_runtime_fault(host_tools_busy))
    ;  true
    ),
    ( retract(zara_host_registry(Old))
    -> rlm_tool:tool_registry_destroy(Old)
    ;  true
    ),
    retractall(zara_host_token(_)),
    retractall(zara_host_callback(_, _, _, _, _)),
    ( Registry == none
    -> true
    ;  assertz(zara_host_registry(Registry)),
       assertz(zara_host_token(Token))
    ).

request_host_tools(Request, Registry, Capabilities) :-
    request_host_tools("direct", Request, Registry, Capabilities).

request_host_tools(RequestId, Request, Registry, Capabilities) :-
    with_mutex(zara_runtime_host_tools,
               request_host_tools_locked(RequestId, Request,
                                         Registry, Capabilities)),
    !.
request_host_tools(_, _, _, _) :-
    throw(zara_runtime_fault(invalid_host_tools)).

request_host_tools_locked(RequestId, Request, Registry, Capabilities) :-
    ( get_dict(host_tools, Request, Requested)
    -> true
    ;  Requested = []
    ),
    ( is_list(Requested), length(Requested, Count), Count =< 16
    -> true
    ;  throw(zara_runtime_fault(invalid_host_tools))
    ),
    ( zara_host_callback(Token, Endpoint, EffectEndpoint,
                         Generation, Schemas)
    -> callback_registry(RequestId, Requested, Schemas,
                         Token, Endpoint, EffectEndpoint, Generation,
                         Registry, Capabilities)
    ;  ( zara_host_registry(Registry)
       -> rlm_tool:tool_discover(Registry, Schemas)
       ;  Registry = none, Schemas = []
       ),
       maplist(granted_host_tool(Schemas), Requested, Capabilities0),
       sort(Capabilities0, Capabilities),
       length(Capabilities, Count)
    ),
    !.

granted_host_tool(Schemas, Name0, tool(Name)) :-
    normalize_atom(host_tool, Name0, Name),
    member(Schema, Schemas),
    Schema.name == Name,
    !.
granted_host_tool(_, _, _) :-
    throw(zara_runtime_fault(unknown_host_tool)).

callback_registry(_, [], _, _, _, _, _, none, []) :- !.
callback_registry(RequestId, Requested, Schemas,
                  Token, Endpoint, EffectEndpoint, Generation,
                  Registry, Capabilities) :-
    maplist(callback_grant(Schemas), Requested, Names),
    sort(Names, UniqueNames),
    length(UniqueNames, Count),
    length(Names, Count),
    !,
    rlm_tool:tool_registry_create(Registry),
    catch(( maplist(register_callback_tool(Registry, RequestId,
                                           Token, Endpoint, EffectEndpoint,
                                           Generation,
                                           Schemas),
                    UniqueNames),
            maplist(wrap_tool_capability, UniqueNames, Capabilities)
          ),
          Error,
          ( rlm_tool:tool_registry_destroy(Registry), throw(Error) )).
callback_registry(_, _, _, _, _, _, _, _, _) :-
    throw(zara_runtime_fault(invalid_host_tools)).

callback_grant(Schemas, Name0, Name) :-
    normalize_atom(host_tool, Name0, Name),
    member(Schema, Schemas),
    Schema.name == Name,
    !.
callback_grant(_, _, _) :-
    throw(zara_runtime_fault(unknown_host_tool)).

register_callback_tool(Registry, RequestId, Token, _Endpoint,
                       EffectEndpoint, Generation, Schemas, Name) :-
    member(Schema, Schemas),
    Schema.name == Name,
    Schema.effect \== read,
    !,
    EffectEndpoint \== none,
    rlm_tool:tool_register(
        Registry, Schema,
        tool_effect_handler(
            rlm_zara_runtime:callback_effect_preflight(RequestId, Generation),
            rlm_zara_runtime:callback_effect(EffectEndpoint, Token,
                                             Generation, RequestId, Schema)),
        ok(_)).
register_callback_tool(Registry, RequestId, Token, Endpoint,
                       _EffectEndpoint, Generation, Schemas, Name) :-
    member(Schema, Schemas),
    Schema.name == Name,
    rlm_tool:tool_register(
        Registry, Schema,
        rlm_zara_runtime:callback_read(Endpoint, Token, Generation,
                                       RequestId, Name),
        ok(_)).

wrap_tool_capability(Name, tool(Name)).

release_host_registry(none) :- !.
release_host_registry(Registry) :-
    zara_host_callback(_, _, _, _, _),
    !,
    rlm_tool:tool_registry_destroy(Registry).
release_host_registry(_).

release_host_registry(_, none) :- !.
release_host_registry(RequestId, Registry) :-
    zara_host_callback(_, _, _, Generation, _),
    host_authority_context(RequestId, Generation, Context),
    rlm_authority:rlm_pending_approvals(Context, Approvals),
    include(unresolved_host_approval, Approvals, Unresolved),
    Unresolved \== [],
    !,
    assertz(zara_retained_registry(RequestId, Generation, Registry)).
release_host_registry(RequestId, Registry) :-
    zara_host_callback(_, _, _, Generation, _),
    !,
    rlm_tool:tool_registry_destroy(Registry),
    host_authority_context(RequestId, Generation, Context),
    rlm_authority:rlm_authority_clear(Context).
release_host_registry(_, Registry) :-
    release_host_registry(Registry).

host_authority_context(RequestId, Generation,
                       session(zara_host(RequestId, Generation))).

zara_runtime_pending(RequestId, Generation, Reply) :-
    ( zara_retained_registry(RequestId, Generation, _)
    -> host_authority_context(RequestId, Generation, Context),
       rlm_authority:rlm_pending_approvals(Context, Native),
       maplist(project_host_approval, Native, Approvals),
       Reply = _{protocol:"ZARA-RUNTIME/1",request_id:RequestId,
                 generation:Generation,status:"approval_required",
                 approvals:Approvals}
    ; Reply = _{protocol:"ZARA-RUNTIME/1",request_id:RequestId,
                generation:Generation,status:"not_found"}
    ).

project_host_approval(Native, Public) :-
    get_dict(id, Native, Id),
    get_dict(name, Native, Name),
    get_dict(effect, Native, Effect),
    get_dict(fingerprint, Native, Fingerprint),
    get_dict(state, Native, State),
    get_dict(operation, Native, Operation),
    get_dict(args, Operation, Args),
    get_dict(effect_identity, Operation, EffectIdentity),
    get_dict(attempt_id, EffectIdentity, AttemptId),
    get_dict(fingerprint, EffectIdentity, EffectFingerprint),
    rlm_effect:rlm_effect_idempotency_key(AttemptId, IdempotencyKey),
    Public = _{id:Id,name:Name,effect:Effect,
               fingerprint:Fingerprint,state:State,args:Args,
               attempt_id:AttemptId,
               effect_fingerprint:EffectFingerprint,
               idempotency_key:IdempotencyKey}.

zara_runtime_approval(RequestId, Generation, ApprovalId,
                      Decision, Reply) :-
    ( zara_retained_registry(RequestId, Generation, _)
    -> host_authority_context(RequestId, Generation, Context),
       ( rlm_authority:rlm_pending_approval(Context, ApprovalId, Approval),
         Approval.state == pending
       -> apply_host_approval(Decision, ApprovalId, Outcome),
          ( Outcome = ok(_)
          -> Status = "accepted"
          ;  Status = "failed"
          )
       ;  Status = "not_found"
       )
    ;  Status = "not_found"
    ),
    Reply = _{protocol:"ZARA-RUNTIME/1",request_id:RequestId,
              generation:Generation,approval_id:ApprovalId,status:Status}.

apply_host_approval("approve", ApprovalId, Outcome) :-
    rlm_authority:rlm_approve(ApprovalId, Outcome).
apply_host_approval("deny", ApprovalId, Outcome) :-
    rlm_authority:rlm_deny(ApprovalId, zara_host_denied, Outcome).

zara_runtime_approval_status(RequestId, Generation, ApprovalId, Reply) :-
    ( zara_retained_registry(RequestId, Generation, Registry),
      host_authority_context(RequestId, Generation, Context),
      rlm_authority:rlm_pending_approval(Context, ApprovalId, _),
      rlm_authority:rlm_pending_resolution_async(ApprovalId, Future)
    -> rlm_async:rlm_future_status(Future, FutureStatus),
       project_host_resolution(FutureStatus, Status, Value),
       Reply = _{protocol:"ZARA-RUNTIME/1",request_id:RequestId,
                 generation:Generation,approval_id:ApprovalId,
                 status:Status,value:Value},
       maybe_release_resolved_host_registry(RequestId, Generation,
                                            Registry, Context, Status)
    ;  Reply = _{protocol:"ZARA-RUNTIME/1",request_id:RequestId,
                 generation:Generation,approval_id:ApprovalId,
                 status:"not_found"}
    ).

project_host_resolution(FutureStatus, "completed", Value) :-
    FutureStatus.state == completed,
    get_dict(outcome, FutureStatus, Resolution),
    get_dict(outcome, Resolution, ok(Value)),
    !.
project_host_resolution(FutureStatus, "indeterminate", _{}) :-
    FutureStatus.state == completed,
    get_dict(outcome, FutureStatus, Resolution),
    get_dict(status, Resolution, indeterminate),
    !.
project_host_resolution(FutureStatus, "failed", _{}) :-
    FutureStatus.state == completed,
    !.
project_host_resolution(_, "running", _{}).

maybe_release_resolved_host_registry(RequestId, Generation, _, _, _) :-
    zara_retained_completion(RequestId, Generation, _, _),
    !.
maybe_release_resolved_host_registry(RequestId, Generation, Registry,
                                     Context, Status) :-
    memberchk(Status, ["completed","failed","indeterminate"]),
    rlm_authority:rlm_pending_approvals(Context, Approvals),
    \+ (member(Approval, Approvals),
        memberchk(Approval.state, [pending,approved,scheduled,executing])),
    !,
    retractall(zara_retained_registry(RequestId, Generation, Registry)),
    rlm_tool:tool_registry_destroy(Registry),
    rlm_authority:rlm_authority_clear(Context).
maybe_release_resolved_host_registry(_, _, _, _, _).

zara_runtime_resume(RequestId, Generation, ApprovalId, Reply) :-
    ( zara_retained_completion(RequestId, Generation, Mode, Cursor),
      zara_retained_registry(RequestId, Generation, Registry),
      host_authority_context(RequestId, Generation, Context),
      rlm_authority:rlm_pending_approval(Context, ApprovalId, Approval),
      Cursor.plan_cursor = plan_cursor(_, ApprovalId),
      rlm_authority:rlm_pending_resolution_async(ApprovalId, Future)
    -> rlm_async:rlm_future_status(Future, FutureStatus),
       project_host_resolution(FutureStatus, Status, Value),
       resume_resolution(Status, Value, Approval, RequestId, Generation,
                         Mode, Cursor, Registry, Context, Reply)
    ;  Reply = _{protocol:"ZARA-RUNTIME/1",request_id:RequestId,
                 generation:Generation,status:"not_found"}
    ).

resume_resolution("running", _, _, RequestId, Generation, _, _, _, _, Reply) :-
    !,
    Reply = _{protocol:"ZARA-RUNTIME/1",request_id:RequestId,
              generation:Generation,status:"running"}.
resume_resolution("completed", ToolValue, Approval, RequestId, Generation,
                  Mode, Cursor, Registry, Context, Reply) :-
    !,
    ( claim_retained_for_resume(RequestId, Generation, Mode, Cursor)
    -> ToolResult = tool_result{status:ok,value:ToolValue,
                                approval_id:Approval.id},
       setup_call_cleanup(
           true,
           ( setup_call_cleanup(
                 rlm_completion:register_current_thread(Cursor.token),
                 rlm_completion:rlm_completion_resume(Cursor, Approval.id,
                                                      ToolResult, Outcome),
                 rlm_completion:cleanup_cancellation(Cursor.token, false)),
             ( Outcome = suspended(NextCursor)
             -> assertz(zara_retained_completion(RequestId, Generation,
                                                 Mode, NextCursor))
             ;  release_resumed_host_registry(RequestId, Generation,
                                              Registry, Context) ),
             project_outcome(RequestId, Mode, Outcome, Reply) ),
           unregister_request(RequestId, Cursor.token))
    ;  resume_not_found(RequestId, Generation, Reply) ).
resume_resolution(_, _, _, RequestId, Generation, Mode, Cursor,
                  Registry, Context, Reply) :-
    ( claim_retained_completion(RequestId, Generation, Mode, Cursor)
    -> rlm_completion:rlm_completion_discard(Cursor),
       release_resumed_host_registry(RequestId, Generation,
                                    Registry, Context),
       Reply = _{protocol:"ZARA-RUNTIME/1",request_id:RequestId,
                 generation:Generation,status:"failed",
                 error:_{kind:"effect_resolution_failed",
                         message:"Approved effect did not produce an observed result"}}
    ;  resume_not_found(RequestId, Generation, Reply) ).

claim_retained_completion(RequestId, Generation, Mode, Cursor) :-
    with_mutex(zara_runtime_completion,
               retract(zara_retained_completion(RequestId, Generation,
                                                Mode, Cursor))).

claim_retained_for_resume(RequestId, Generation, Mode, Cursor) :-
    with_mutex(zara_runtime_completion,
               ( retract(zara_retained_completion(RequestId, Generation,
                                                  Mode, Cursor)),
                 register_request(RequestId, Cursor.token) )).

resume_not_found(RequestId, Generation,
                 _{protocol:"ZARA-RUNTIME/1",request_id:RequestId,
                   generation:Generation,status:"not_found"}).

release_resumed_host_registry(RequestId, Generation, Registry, Context) :-
    retractall(zara_retained_registry(RequestId, Generation, Registry)),
    rlm_tool:tool_registry_destroy(Registry),
    rlm_authority:rlm_authority_clear(Context).

callback_effect_preflight(RequestId, Generation, Args, Args,
                          callback_identity{request_id:RequestId,
                                            generation:Generation}).

callback_effect(Endpoint, Token, Generation, RequestId, Schema,
                Attempt, Request, Outcome) :-
    atom_string(Attempt.attempt_id, AttemptId),
    atom_string(Attempt.fingerprint, Fingerprint),
    atom_string(Attempt.idempotency_key, IdempotencyKey),
    atom_string(Schema.name, Name),
    Body = _{protocol:"ZARA-HOST-EFFECT/1",
             request_id:RequestId,
             tool_call_id:AttemptId,
             generation:Generation,
             attempt_id:AttemptId,
             idempotency_key:IdempotencyKey,
             effect_fingerprint:Fingerprint,
             name:Name,
             args:Request.args},
    atom_json_dict(BodyAtom, Body, []),
    format(string(Authorization), 'Bearer ~s', [Token]),
    setup_call_cleanup(
        http_open(Endpoint, Stream,
                  [method(post), post(atom(BodyAtom)),
                   request_header('Content-Type'='application/json'),
                   request_header('Authorization'=Authorization),
                   bypass_proxy(true), redirect(false), timeout(2)]),
        ( read_string(Stream, 65537, ResponseText),
          string_length(ResponseText, ResponseLength),
          ResponseLength =< 65536,
          atom_string(ResponseAtom, ResponseText),
          atom_json_dict(ResponseAtom, Response, [])
        ),
        close(Stream)),
    Response.protocol == "ZARA-HOST-EFFECT/1",
    Response.request_id == RequestId,
    Response.tool_call_id == AttemptId,
    Response.generation == Generation,
    Response.attempt_id == AttemptId,
    Response.effect_fingerprint == Fingerprint,
    callback_effect_response(Response, Schema, Attempt, Outcome).

callback_effect_response(Response, Schema, Attempt,
                         observed(Observation)) :-
    Response.status == "observed",
    get_dict(value, Response, Value),
    get_dict(metadata, Attempt, Metadata),
    get_dict(limits, Metadata, Limits),
    rlm_tool:invoke_after_call(ok(Value), Schema, Limits,
                               ok(Value), _, Bytes),
    !,
    Observation = observation{status:succeeded, value:Value,
                              usage:usage{units:1,output_bytes:Bytes},
                              provenance:zara_host_effect,
                              tool:Schema.name}.
callback_effect_response(Response, _, _,
                         indeterminate(host_in_progress_without_reconcile)) :-
    Response.status == "in_progress",
    !.
callback_effect_response(Response, _, _, indeterminate(host_reported)) :-
    Response.status == "indeterminate",
    !.
callback_effect_response(_, _, _,
                         indeterminate(invalid_host_effect_response)).

callback_read(Endpoint, Token, Generation, RequestId, Name, Args, Value) :-
    uuid(CallIdAtom, [version(4)]),
    atom_string(CallIdAtom, CallId),
    atom_string(Name, NameText),
    Body = _{protocol:"ZARA-HOST-TOOL/1",
             request_id:RequestId,
             tool_call_id:CallId,
             generation:Generation,
             name:NameText,
             args:Args},
    atom_json_dict(BodyAtom, Body, []),
    format(string(Authorization), 'Bearer ~s', [Token]),
    setup_call_cleanup(
        http_open(Endpoint, Stream,
                  [method(post), post(atom(BodyAtom)),
                   request_header('Content-Type'='application/json'),
                   request_header('Authorization'=Authorization),
                   bypass_proxy(true), redirect(false), timeout(2)]),
        ( read_string(Stream, 65537, ResponseText),
          string_length(ResponseText, ResponseLength),
          ResponseLength =< 65536,
          atom_string(ResponseAtom, ResponseText),
          atom_json_dict(ResponseAtom, Response, [])
        ),
        close(Stream)),
    ( Response.protocol == "ZARA-HOST-TOOL/1",
      Response.request_id == RequestId,
      Response.tool_call_id == CallId,
      Response.generation == Generation
    -> true
    ;  throw(zara_runtime_fault(host_callback_mismatch))
    ),
    ( Response.status == "ok",
      get_dict(value, Response, Value)
    -> true
    ;  throw(zara_runtime_fault(host_callback_denied))
    ).

zara_runtime_set_profiles(Profiles0) :-
    (   is_list(Profiles0),
        length(Profiles0, Count),
        Count =< 16
    ->  maplist(normalize_profile, Profiles0, Profiles),
        sort(Profiles, Unique),
        ( length(Unique, Count)
        -> true
        ;  throw(zara_runtime_fault(duplicate_profile))
        ),
        with_mutex(zara_runtime_profiles,
                   ( retractall(zara_runtime_profile(_)),
                     maplist(assert_runtime_profile, Profiles)
                   ))
    ;   throw(zara_runtime_fault(invalid_profiles))
    ).

normalize_profile(Value, Profile) :-
    normalize_identifier(profile, Value, Profile),
    ( valid_runtime_name(Profile)
    -> true
    ;  throw(zara_runtime_fault(invalid_profile(Profile)))
    ).

valid_runtime_name(Text) :-
    string_codes(Text, [First|Rest]),
    runtime_name_start(First),
    maplist(runtime_name_code, Rest).

runtime_name_start(Code) :-
    Code >= 0'a,
    Code =< 0'z,
    !.
runtime_name_start(Code) :-
    Code >= 0'0,
    Code =< 0'9.

runtime_name_code(Code) :-
    runtime_name_start(Code),
    !.
runtime_name_code(0'.).
runtime_name_code(0'_).
runtime_name_code(0'-).

assert_runtime_profile(Profile) :-
    assertz(zara_runtime_profile(Profile)).

zara_runtime_cancel(RequestId0, Reply) :-
    catch(( normalize_identifier(request_id, RequestId0, RequestId),
            cancel_request(RequestId, Reply)
          ),
          _,
          Reply = _{
              protocol:"ZARA-RUNTIME/1",
              runtime_id:"prolog-rlm",
              status:"failed",
              error:_{kind:"invalid_request",
                      message:"request_id is invalid"}
          }).

cancel_request(RequestId, Reply) :-
    with_mutex(zara_runtime_requests,
               ( zara_request_token(RequestId, Token)
               -> Found = true
               ;  Found = false
               )),
    (   Found == true
    ->  rlm:rlm_cancel(Token),
        ( claim_pending_cancel(RequestId) -> true ; true ),
        Reply = _{
            protocol:"ZARA-RUNTIME/1",
            runtime_id:"prolog-rlm",
            request_id:RequestId,
            status:"cancel_requested",
            found:true
        }
    ;   claim_pending_cancel(RequestId)
    ->  Reply = _{
            protocol:"ZARA-RUNTIME/1",
            runtime_id:"prolog-rlm",
            request_id:RequestId,
            status:"cancel_requested",
            found:true
        }
    ;   active_request_token(RequestId, ResumingToken)
    ->  rlm:rlm_cancel(ResumingToken),
        Reply = _{protocol:"ZARA-RUNTIME/1",runtime_id:"prolog-rlm",
                  request_id:RequestId,status:"cancel_requested",
                  found:true}
    ;   Reply = _{
            protocol:"ZARA-RUNTIME/1",
            runtime_id:"prolog-rlm",
            request_id:RequestId,
            status:"not_found",
            found:false
        }
    ).

active_request_token(RequestId, Token) :-
    with_mutex(zara_runtime_requests,
               zara_request_token(RequestId, Token)).

claim_pending_cancel(RequestId) :-
    with_mutex(zara_runtime_completion,
               retract(zara_retained_completion(RequestId,
                                                Generation, _, Cursor))),
    rlm:rlm_cancel(Cursor.token),
    host_authority_context(RequestId, Generation, Context),
    rlm_authority:rlm_pending_approvals(Context, Approvals),
    forall(( member(Approval, Approvals), Approval.state == pending ),
           rlm_authority:rlm_deny(Approval.id, zara_cancelled, _)),
    rlm_completion:rlm_completion_discard(Cursor),
    ( zara_retained_registry(RequestId, Generation, Registry)
    -> maybe_release_resolved_host_registry(RequestId, Generation,
                                            Registry, Context, "failed")
    ;  true ).

zara_runtime_server_start(Port) :-
    with_mutex(zara_runtime_server,
               start_server_locked(Port)).

start_server_locked(Port) :-
    (   zara_server_port(Current)
    ->  Port = Current
    ;   Address = '127.0.0.1':Port,
        http_server(http_dispatch,
                    [ port(Address),
                      workers(4),
                      timeout(30),
                      keep_alive_timeout(2),
                      silent(true)
                    ]),
        assertz(zara_server_port(Port))
    ).

zara_runtime_server_stop :-
    with_mutex(zara_runtime_server,
               stop_server_locked).

stop_server_locked :-
    (   retract(zara_server_port(Port))
    ->  http_stop_server(Port, [])
    ;   true
    ).

/* HTTP ---------------------------------------------------------------- */

zara_discover_handler(_Request) :-
    zara_runtime_descriptor(Descriptor),
    reply_json_dict(_{runtimes:[Descriptor]}).

zara_health_handler(_Request) :-
    zara_runtime_health(Health),
    reply_json_dict(Health).

zara_generate_handler(HttpRequest) :-
    catch(( require_host_authorization(HttpRequest),
            http_read_json_dict(HttpRequest, Body,
                                [value_string_as(string)]),
            zara_runtime_execute(Body, Reply)
          ),
          Error,
          ( error_kind(Error, Kind, Message),
            Reply = _{
              protocol:"ZARA-RUNTIME/1",
              runtime_id:"prolog-rlm",
              status:"failed",
              error:_{kind:Kind, message:Message}
          })),
    reply_json_dict(Reply).

zara_cancel_handler(HttpRequest) :-
    catch(( require_host_authorization(HttpRequest),
            http_read_json_dict(HttpRequest, Body,
                                [value_string_as(string)]),
            get_dict(request_id, Body, RequestId),
            zara_runtime_cancel(RequestId, Reply)
          ),
          Error,
          ( error_kind(Error, Kind, Message),
            Reply = _{
              protocol:"ZARA-RUNTIME/1",
              runtime_id:"prolog-rlm",
              status:"failed",
              error:_{kind:Kind, message:Message}
          })),
    reply_json_dict(Reply).

zara_host_config_handler(HttpRequest) :-
    catch(( require_bootstrap_authorization(HttpRequest, Token),
            bounded_config_body(HttpRequest, Body),
            get_dict(protocol, Body, "ZARA-RUNTIME/1"),
            get_dict(endpoint, Body, Endpoint),
            ( get_dict(effect_endpoint, Body, EffectEndpoint)
            -> true ; EffectEndpoint = none ),
            get_dict(generation, Body, Generation),
            get_dict(tools, Body, WireTools),
            is_list(WireTools),
            maplist(host_tool_from_wire, WireTools, Schemas),
            zara_runtime_set_host_callback(Token, Endpoint,
                                           EffectEndpoint, Generation, Schemas),
            Reply = _{protocol:"ZARA-RUNTIME/1", status:"configured",
                      generation:Generation}
          ),
          Error,
          ( error_kind(Error, Kind, Message),
            Reply = _{protocol:"ZARA-RUNTIME/1", status:"failed",
                      error:_{kind:Kind, message:Message}}
          )),
    reply_json_dict(Reply).

zara_host_pending_handler(HttpRequest) :-
    host_approval_http(HttpRequest, pending, Reply),
    reply_json_dict(Reply).

zara_host_approval_handler(HttpRequest) :-
    host_approval_http(HttpRequest, approve, Reply),
    reply_json_dict(Reply).

zara_host_approval_status_handler(HttpRequest) :-
    host_approval_http(HttpRequest, status, Reply),
    reply_json_dict(Reply).

zara_resume_handler(HttpRequest) :-
    host_approval_http(HttpRequest, resume, Reply),
    reply_json_dict(Reply).

host_approval_http(HttpRequest, Action, Reply) :-
    catch(( ( require_effect_authorization(HttpRequest),
            bounded_config_body(HttpRequest, Body),
            get_dict(protocol, Body, "ZARA-RUNTIME/1"),
            get_dict(request_id, Body, RequestId0),
            normalize_identifier(request_id, RequestId0, RequestId),
            get_dict(generation, Body, Generation),
            integer(Generation), Generation >= 0,
            host_approval_action(Action, Body, RequestId,
                                 Generation, Reply)
          ) -> true
          ; throw(zara_runtime_fault(invalid_host_approval))
          ),
          Error,
          ( error_kind(Error, Kind, Message),
            Reply = _{protocol:"ZARA-RUNTIME/1",status:"failed",
                      error:_{kind:Kind,message:Message}} )).

require_effect_authorization(HttpRequest) :-
    zara_host_callback(_, _, EffectEndpoint, _, _),
    EffectEndpoint \== none,
    require_host_authorization(HttpRequest),
    !.
require_effect_authorization(_) :-
    throw(zara_runtime_fault(unauthorized)).

host_approval_action(pending, _, RequestId, Generation, Reply) :-
    zara_runtime_pending(RequestId, Generation, Reply).
host_approval_action(approve, Body, RequestId, Generation, Reply) :-
    get_dict(approval_id, Body, ApprovalId0),
    normalize_atom(approval_id, ApprovalId0, ApprovalId),
    get_dict(decision, Body, Decision),
    memberchk(Decision, ["approve","deny"]),
    zara_runtime_approval(RequestId, Generation,
                          ApprovalId, Decision, Reply).
host_approval_action(status, Body, RequestId, Generation, Reply) :-
    get_dict(approval_id, Body, ApprovalId0),
    normalize_atom(approval_id, ApprovalId0, ApprovalId),
    zara_runtime_approval_status(RequestId, Generation,
                                 ApprovalId, Reply).
host_approval_action(resume, Body, RequestId, Generation, Reply) :-
    get_dict(approval_id, Body, ApprovalId0),
    normalize_atom(approval_id, ApprovalId0, ApprovalId),
    zara_runtime_resume(RequestId, Generation, ApprovalId, Reply).

require_bootstrap_authorization(HttpRequest, Token) :-
    zara_bootstrap_token(Token),
    format(string(Expected), 'Bearer ~s', [Token]),
    member(authorization(Header), HttpRequest),
    text_string(Header, Expected),
    !.
require_bootstrap_authorization(_, _) :-
    throw(zara_runtime_fault(unauthorized)).

bounded_config_body(HttpRequest, Body) :-
    memberchk(content_length(Length), HttpRequest),
    integer(Length), Length =< 32768,
    !,
    http_read_json_dict(HttpRequest, Body,
                        [value_string_as(string)]).
bounded_config_body(_, _) :-
    throw(zara_runtime_fault(invalid_host_callback)).

host_tool_from_wire(Wire, Schema) :-
    is_dict(Wire),
    \+ get_dict(handler, Wire, _),
    \+ get_dict(capability, Wire, _),
    ( get_dict(effect, Wire, EffectText)
    -> memberchk(EffectText, ["write","process"]),
       atom_string(Effect, EffectText)
    ;  Effect = read
    ),
    get_dict(name, Wire, NameText),
    normalize_atom(host_tool, NameText, Name),
    atom_length(Name, NameLength),
    NameLength =< 64,
    valid_runtime_name(NameText),
    get_dict(arguments, Wire, ArgumentsWire),
    get_dict(result, Wire, ResultWire),
    schema_from_wire(ArgumentsWire, Arguments),
    schema_from_wire(ResultWire, Result),
    ( get_dict(description, Wire, Description0)
    -> bounded_text(description, Description0, 512, Description)
    ;  Description = ""
    ),
    Schema = tool_schema{name:Name,
                         description:Description,
                         capability:tool(Name), effect:Effect,
                         arguments:Arguments, result:Result},
    !.
host_tool_from_wire(_, _) :-
    throw(zara_runtime_fault(invalid_host_callback_schema)).

schema_from_wire(Wire, Schema) :-
    is_dict(Wire),
    get_dict(type, Wire, TypeText),
    normalize_atom(schema_type, TypeText, Type),
    memberchk(Type, [any,string,integer,number,boolean,list,array,object]),
    put_dict(type, Wire, Type, Typed),
    ( get_dict(required, Typed, RequiredWire)
    -> maplist(normalize_atom(required), RequiredWire, Required),
       put_dict(required, Typed, Required, WithRequired)
    ;  WithRequired = Typed
    ),
    ( get_dict(properties, WithRequired, PropertiesWire)
    -> is_dict(PropertiesWire),
       dict_pairs(PropertiesWire, Tag, PropertyPairs),
       maplist(schema_property_from_wire, PropertyPairs, ConvertedPairs),
       dict_pairs(Properties, Tag, ConvertedPairs),
       put_dict(properties, WithRequired, Properties, WithProperties)
    ;  WithProperties = WithRequired
    ),
    ( get_dict(items, WithProperties, ItemsWire)
    -> schema_from_wire(ItemsWire, Items),
       put_dict(items, WithProperties, Items, Schema)
    ;  Schema = WithProperties
    ),
    !.
schema_from_wire(_, _) :-
    throw(zara_runtime_fault(invalid_host_callback_schema)).

schema_property_from_wire(Name-Wire, Name-Schema) :-
    schema_from_wire(Wire, Schema).

require_host_authorization(_) :-
    \+ zara_host_token(_),
    !.
require_host_authorization(HttpRequest) :-
    zara_host_token(Token),
    format(string(Expected), 'Bearer ~s', [Token]),
    member(authorization(Header), HttpRequest),
    text_string(Header, Provided),
    Provided == Expected,
    !.
require_host_authorization(_) :-
    throw(zara_runtime_fault(unauthorized)).

/* Execution ----------------------------------------------------------- */

execute_mode(Mode,
             RequestId,
             Prompt,
             Context,
             ProviderName,
             Provider,
             Budget,
             MaxTokens,
             ToolRegistry,
             ToolCapabilities,
             Token,
             Reply) :-
    runtime_options(RequestId,
                    ProviderName,
                    Provider,
                    Budget,
                    MaxTokens,
                    ToolRegistry,
                    ToolCapabilities,
                    Token,
                    Options),
    execute_mode_outcome(Mode, Prompt, Context, Options, Outcome),
    ( Outcome = error(_),
      zara_host_callback(_, _, _, Generation, _)
    -> deny_unresumable_pending(RequestId, Generation)
    ;  true ),
    ( Outcome = suspended(Cursor),
      zara_host_callback(_, _, _, Generation, _)
    -> assertz(zara_retained_completion(RequestId, Generation,
                                        Mode, Cursor))
    ;  true ),
    project_outcome(RequestId, Mode, Outcome, Reply).

deny_unresumable_pending(RequestId, Generation) :-
    host_authority_context(RequestId, Generation, Context),
    rlm_authority:rlm_pending_approvals(Context, Approvals),
    forall(( member(Approval, Approvals), Approval.state == pending ),
           rlm_authority:rlm_deny(Approval.id, unresumable_plan, _)).

execute_mode_outcome(direct, Prompt, _Context, Options, Outcome) :-
    !,
    rlm:llm_query(Prompt, Options, Outcome).
execute_mode_outcome(rlm, Prompt, Context, Options, Outcome) :-
    !,
    rlm:rlm_completion(Prompt, text(Context), Options, Outcome).
execute_mode_outcome(Mode, _, _, _, _) :-
    throw(zara_runtime_fault(unsupported_mode(Mode))).

runtime_options(RequestId,
                ProviderName,
                Provider,
                Budget,
                MaxTokens,
                ToolRegistry,
                ToolCapabilities,
                Token,
                Options) :-
    append(ToolCapabilities,
           [rlm, context(peek), context(search), context(slice),
            model(ProviderName)],
           Capabilities),
    Base = [ provider(Provider),
                  provider_name(ProviderName),
                  planner_max_tokens(MaxTokens),
                  cancel_token(Token),
                  trace_id(RequestId),
                  capabilities(Capabilities),
                  child_capabilities([model(ProviderName)]),
                  budget(Budget)
                ],
    ( ToolRegistry == none
    -> Options = Base
    ;  ( zara_host_callback(_, _, _, Generation, _)
       -> host_authority_context(RequestId, Generation, Context),
          Options = [tool_registry(ToolRegistry),
                     authority_context(Context)|Base]
       ;  Options = [tool_registry(ToolRegistry)|Base]
       )
    ).

project_outcome(RequestId, _Mode, _Outcome, Reply) :-
    zara_host_callback(_, _, EffectEndpoint, Generation, _),
    EffectEndpoint \== none,
    host_authority_context(RequestId, Generation, Context),
    rlm_authority:rlm_pending_approvals(Context, Native),
    include(unresolved_host_approval, Native, Unresolved),
    Unresolved \== [],
    maplist(project_host_approval, Unresolved, Approvals),
    !,
    Reply = _{protocol:"ZARA-RUNTIME/1",runtime_id:"prolog-rlm",
              request_id:RequestId,generation:Generation,
              status:"approval_required",approvals:Approvals}.

project_outcome(RequestId, Mode, ok(Result), Reply) :-
    !,
    outcome_text(Mode, Result, Text),
    Reply = _{
        protocol:"ZARA-RUNTIME/1",
        runtime_id:"prolog-rlm",
        request_id:RequestId,
        status:"completed",
        text:Text
    }.
project_outcome(RequestId, _Mode, error(_Error), Reply) :-
    !,
    Reply = _{
        protocol:"ZARA-RUNTIME/1",
        runtime_id:"prolog-rlm",
        request_id:RequestId,
        status:"failed",
        error:_{kind:"runtime_error",
                message:"Prolog-RLM did not complete the request"}
    }.
project_outcome(RequestId, _Mode, _Other, Reply) :-
    Reply = _{
        protocol:"ZARA-RUNTIME/1",
        runtime_id:"prolog-rlm",
        request_id:RequestId,
        status:"failed",
        error:_{kind:"runtime_error",
                message:"Prolog-RLM returned an invalid outcome"}
    }.

unresolved_host_approval(Approval) :-
    memberchk(Approval.state, [pending,approved,scheduled,executing]).

outcome_text(direct, Result, Text) :-
    is_dict(Result),
    get_dict(response, Result, Response),
    response_text(Response, Text),
    !.
outcome_text(rlm, Result, Text) :-
    is_dict(Result),
    get_dict(value, Result, Value),
    response_text(Value, Text),
    !.
outcome_text(_, _, "").

response_text(Value, Value) :-
    string(Value),
    !.
response_text(Value, Text) :-
    atom(Value),
    !,
    atom_string(Value, Text).
response_text(Value, Text) :-
    is_dict(Value),
    get_dict(text, Value, Text),
    string(Text),
    !.
response_text(Value, Text) :-
    is_dict(Value),
    get_dict(reasoning, Value, Text),
    string(Text).

/* Request validation -------------------------------------------------- */

require_request_dict(Request) :-
    (   is_dict(Request)
    ->  true
    ;   throw(zara_runtime_fault(invalid_request_object))
    ).

require_protocol(Request) :-
    (   get_dict(protocol, Request, Protocol0)
    ->  text_string(Protocol0, Protocol),
        zara_runtime_protocol(Expected),
        ( Protocol == Expected
        -> true
        ;  throw(zara_runtime_fault(incompatible_protocol(Protocol)))
        )
    ;   throw(zara_runtime_fault(missing_field(protocol)))
    ).

request_id(Request, RequestId) :-
    (   get_dict(request_id, Request, RequestId0)
    ->  normalize_identifier(request_id, RequestId0, RequestId)
    ;   throw(zara_runtime_fault(missing_field(request_id)))
    ).

request_mode(Request, Mode) :-
    (   get_dict(mode, Request, Mode0)
    ->  normalize_atom(mode, Mode0, Mode)
    ;   Mode = rlm
    ),
    ( memberchk(Mode, [direct, rlm])
    -> true
    ;  throw(zara_runtime_fault(unsupported_mode(Mode)))
    ).

request_prompt(Request, Prompt) :-
    (   get_dict(prompt, Request, Prompt0)
    ->  bounded_text(prompt, Prompt0, 131072, Prompt)
    ;   get_dict(messages, Request, Messages)
    ->  messages_prompt(Messages, Prompt)
    ;   throw(zara_runtime_fault(missing_field(prompt)))
    ).

messages_prompt(Messages, Prompt) :-
    (   is_list(Messages),
        Messages \== []
    ->  maplist(message_line, Messages, Lines),
        atomics_to_string(Lines, "\n", Prompt0),
        bounded_text(messages, Prompt0, 131072, Prompt)
    ;   throw(zara_runtime_fault(invalid_messages))
    ).

message_line(Message, Line) :-
    is_dict(Message),
    get_dict(role, Message, Role0),
    get_dict(content, Message, Content0),
    normalize_atom(role, Role0, Role),
    memberchk(Role, [system, user, assistant]),
    bounded_text(content, Content0, 65536, Content),
    format(string(Line), '~w: ~s', [Role, Content]),
    !.
message_line(_, _) :-
    throw(zara_runtime_fault(invalid_message)).

request_context(Request, Context) :-
    (   get_dict(inline_context, Request, Context0)
    ->  bounded_text(inline_context, Context0, 262144, Context)
    ;   Context = ""
    ).

request_provider(Request, ProviderName, Provider) :-
    (   get_dict(provider, Request, Spec)
    ->  provider_spec(Spec, ProviderName, Provider)
    ;   request_openrouter_model(Request, Model),
        ProviderName = openrouter,
        openrouter_provider(Model, Provider)
    ).

provider_spec(Spec, _, _) :-
    is_dict(Spec),
    ( get_dict(api_key, Spec, _)
    ; get_dict(credential, Spec, _)
    ),
    !,
    throw(zara_runtime_fault(literal_credentials_forbidden)).
provider_spec(Spec, openrouter, Provider) :-
    is_dict(Spec),
    get_dict(kind, Spec, Kind0),
    normalize_atom(provider_kind, Kind0, openrouter),
    !,
    (   get_dict(model, Spec, Model0)
    ->  normalize_atom(model, Model0, Model)
    ;   default_openrouter_model(Model)
    ),
    openrouter_provider(Model, Provider).
provider_spec(Spec, openai_compatible, Provider) :-
    is_dict(Spec),
    get_dict(kind, Spec, Kind0),
    normalize_atom(provider_kind, Kind0, Kind),
    memberchk(Kind, [openai_compatible, 'openai-compatible']),
    !,
    required_provider_atom(Spec, endpoint, Endpoint),
    required_provider_atom(Spec, model, Model),
    provider_credential(Spec, Credential),
    openai_compatible_provider(Endpoint, Credential, Model, Provider).
provider_spec(_, _, _) :-
    throw(zara_runtime_fault(invalid_provider)).

request_openrouter_model(Request, Model) :-
    (   get_dict(model, Request, Model0)
    ->  normalize_atom(model, Model0, Model)
    ;   default_openrouter_model(Model)
    ).

required_provider_atom(Spec, Key, Atom) :-
    (   get_dict(Key, Spec, Value)
    ->  normalize_atom(Key, Value, Atom)
    ;   throw(zara_runtime_fault(missing_provider_field(Key)))
    ).

provider_credential(Spec, none) :-
    get_dict(no_credential, Spec, true),
    !.
provider_credential(Spec, env(Name)) :-
    (   get_dict(credential_env, Spec, Name0)
    ->  normalize_atom(credential_env, Name0, Name),
        valid_env_name(Name)
    ;   Name = 'OPENAI_API_KEY'
    ).

valid_env_name(Name) :-
    atom_chars(Name, [First|Rest]),
    ( char_type(First, alpha) ; First == '_' ),
    maplist(env_char, Rest),
    atom_length(Name, Length),
    Length =< 64,
    !.
valid_env_name(_) :-
    throw(zara_runtime_fault(invalid_credential_env)).

env_char(Char) :-
    char_type(Char, alnum),
    !.
env_char('_').

request_budget(Request, Budget, MaxTokens) :-
    rlm:default_completion_budget(Default),
    (   get_dict(budgets, Request, Requested),
        is_dict(Requested)
    ->  true
    ;   Requested = _{}
    ),
    bounded_budget_integer(Requested,
                           max_tokens,
                           1,
                           Default.max_total_tokens,
                           1024,
                           MaxTokens),
    bounded_budget_integer(Requested,
                           max_output_bytes,
                           1024,
                           Default.max_output_bytes,
                           Default.max_output_bytes,
                           MaxOutputBytes),
    bounded_budget_integer(Requested,
                           max_model_calls,
                           1,
                           Default.max_model_calls,
                           Default.max_model_calls,
                           MaxModelCalls),
    bounded_budget_integer(Requested,
                           max_tool_calls,
                           0,
                           Default.max_tool_calls,
                           Default.max_tool_calls,
                           MaxToolCalls),
    bounded_budget_integer(Requested,
                           max_recursion_depth,
                           0,
                           Default.max_recursion_depth,
                           Default.max_recursion_depth,
                           MaxDepth),
    bounded_wall_time(Requested, Default.time_limit, TimeLimit),
    bounded_cost(Requested, Default.max_cost_usd, MaxCost),
    TotalTokens is min(Default.max_total_tokens, max(512, MaxTokens*4)),
    put_dict(_{
                 max_total_tokens:TotalTokens,
                 max_output_bytes:MaxOutputBytes,
                 max_model_calls:MaxModelCalls,
                 max_tool_calls:MaxToolCalls,
                 max_recursion_depth:MaxDepth,
                 time_limit:TimeLimit,
                 max_cost_usd:MaxCost
             },
             Default,
             Budget).

bounded_budget_integer(Dict, Key, Minimum, Maximum, Default, Value) :-
    (   get_dict(Key, Dict, Requested)
    ->  ( integer(Requested),
          Requested >= Minimum,
          Requested =< Maximum
        -> Value = Requested
        ;  throw(zara_runtime_fault(invalid_budget(Key)))
        )
    ;   Value = Default
    ).

bounded_wall_time(Dict, MaximumSeconds, TimeLimit) :-
    (   get_dict(wall_time_ms, Dict, Milliseconds)
    ->  ( number(Milliseconds),
          Milliseconds > 0,
          Milliseconds =< MaximumSeconds*1000
        -> TimeLimit is Milliseconds/1000.0
        ;  throw(zara_runtime_fault(invalid_budget(wall_time_ms)))
        )
    ;   TimeLimit = MaximumSeconds
    ).

bounded_cost(Dict, Maximum, Cost) :-
    (   get_dict(max_cost_usd, Dict, Requested)
    ->  ( number(Requested),
          Requested >= 0,
          Requested =< Maximum
        -> Cost = Requested
        ;  throw(zara_runtime_fault(invalid_budget(max_cost_usd)))
        )
    ;   Cost = Maximum
    ).

register_request(RequestId, Token) :-
    with_mutex(zara_runtime_requests,
               ( ( zara_request_token(RequestId, _)
                 ; zara_retained_completion(RequestId, _, _, _) )
               -> throw(zara_runtime_fault(duplicate_request_id))
               ;  assertz(zara_request_token(RequestId, Token))
               )).

unregister_request(RequestId, Token) :-
    with_mutex(zara_runtime_requests,
               retractall(zara_request_token(RequestId, Token))).

/* Safe projection ----------------------------------------------------- */

zara_exception_reply(Request, Error, Reply) :-
    request_id_or_unknown(Request, RequestId),
    error_kind(Error, Kind, Message),
    Reply = _{
        protocol:"ZARA-RUNTIME/1",
        runtime_id:"prolog-rlm",
        request_id:RequestId,
        status:"failed",
        error:_{kind:Kind, message:Message}
    }.

request_id_or_unknown(Request, RequestId) :-
    is_dict(Request),
    get_dict(request_id, Request, Value),
    catch(normalize_identifier(request_id, Value, RequestId), _, fail),
    !.
request_id_or_unknown(_, "unknown").

error_kind(error(Inner, _Context), Kind, Message) :-
    !,
    error_kind(Inner, Kind, Message).
error_kind(zara_runtime_fault(incompatible_protocol(_)),
           "incompatible_protocol",
           "runtime protocol is incompatible") :- !.
error_kind(zara_runtime_fault(literal_credentials_forbidden),
           "invalid_request",
           "literal provider credentials are forbidden") :- !.
error_kind(zara_runtime_fault(unauthorized),
           "unauthorized",
           "host authorization is required") :- !.
error_kind(zara_runtime_fault(effect_store_required),
           "effect_store_required",
           "durable effect store is required for host writes") :- !.
error_kind(zara_runtime_fault(unsupported_mode(_)),
           "invalid_request",
           "runtime mode is unsupported") :- !.
error_kind(zara_runtime_fault(_),
           "invalid_request",
           "runtime request is invalid") :- !.
error_kind(error(rlm_cancelled(_), _),
           "cancelled",
           "request was cancelled") :- !.
error_kind(rlm_cancelled(_),
           "cancelled",
           "request was cancelled") :- !.
error_kind(time_limit_exceeded,
           "timeout",
           "runtime request timed out") :- !.
error_kind(_, "runtime_error", "Prolog-RLM runtime request failed").

normalize_identifier(Field, Value, Text) :-
    (   text_string(Value, Candidate),
        string_length(Candidate, Length),
        Length > 0,
        Length =< 128,
        string_codes(Candidate, Codes),
        \+ ( member(Code, Codes),
             Code < 32
           )
    ->  Text = Candidate
    ;   throw(zara_runtime_fault(invalid_identifier(Field)))
    ).

normalize_atom(_Field, Value, Atom) :-
    atom(Value),
    !,
    Atom = Value.
normalize_atom(_Field, Value, Atom) :-
    string(Value),
    Value \== "",
    !,
    atom_string(Atom, Value).
normalize_atom(Field, _, _) :-
    throw(zara_runtime_fault(invalid_atom(Field))).

bounded_text(_Field, Value, Maximum, Text) :-
    text_string(Value, Text),
    string_length(Text, Length),
    Length =< Maximum,
    !.
bounded_text(Field, _, _, _) :-
    throw(zara_runtime_fault(invalid_text(Field))).

text_string(Value, Value) :-
    string(Value),
    !.
text_string(Value, Text) :-
    atom(Value),
    !,
    atom_string(Value, Text).
text_string(_, _) :-
    fail.
