:- module(rlm_zara_runtime,
          [ zara_runtime_protocol/1,
            zara_runtime_descriptor/1,
            zara_runtime_health/1,
            zara_runtime_execute/2,
            zara_runtime_cancel/2,
            zara_runtime_set_profiles/1,
            zara_runtime_set_host_tools/2,
            zara_runtime_set_host_callback/4,
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
:- dynamic zara_host_callback/4.
:- dynamic zara_bootstrap_token/1.

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
    ( (zara_host_registry(_) ; zara_host_callback(_, _, _, _))
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
              release_host_registry(ToolRegistry)) ),
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
    require_host_token(Token0, Token),
    require_callback_endpoint(Endpoint0, Endpoint),
    ( integer(Generation), Generation >= 0,
      is_list(Schemas), Schemas \== [],
      length(Schemas, Count), Count =< 16
    -> true
    ;  throw(zara_runtime_fault(invalid_host_callback))
    ),
    validate_callback_schemas(Schemas),
    with_mutex(zara_runtime_host_tools,
               ( replace_host_registry(none, none),
                 assertz(zara_host_callback(Token, Endpoint,
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
    maplist(require_read_schema, Schemas),
    rlm_tool:tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        maplist(validate_callback_schema(Registry), Schemas),
        rlm_tool:tool_registry_destroy(Registry)).

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

require_read_schema(Schema) :-
    is_dict(Schema),
    get_dict(effect, Schema, read),
    get_dict(name, Schema, Name),
    atom(Name),
    !.
require_read_schema(_) :-
    throw(zara_runtime_fault(invalid_host_callback_schema)).

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
    ( retract(zara_host_registry(Old))
    -> rlm_tool:tool_registry_destroy(Old)
    ;  true
    ),
    retractall(zara_host_token(_)),
    retractall(zara_host_callback(_, _, _, _)),
    ( Registry == none
    -> true
    ;  assertz(zara_host_registry(Registry)),
       assertz(zara_host_token(Token))
    ).

request_host_tools(Request, Registry, Capabilities) :-
    request_host_tools("direct", Request, Registry, Capabilities).

request_host_tools(RequestId, Request, Registry, Capabilities) :-
    ( get_dict(host_tools, Request, Requested)
    -> true
    ;  Requested = []
    ),
    ( is_list(Requested), length(Requested, Count), Count =< 16
    -> true
    ;  throw(zara_runtime_fault(invalid_host_tools))
    ),
    ( zara_host_callback(Token, Endpoint, Generation, Schemas)
    -> callback_registry(RequestId, Requested, Schemas,
                         Token, Endpoint, Generation,
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
request_host_tools(_, _, _, _) :-
    throw(zara_runtime_fault(invalid_host_tools)).

granted_host_tool(Schemas, Name0, tool(Name)) :-
    normalize_atom(host_tool, Name0, Name),
    member(Schema, Schemas),
    Schema.name == Name,
    !.
granted_host_tool(_, _, _) :-
    throw(zara_runtime_fault(unknown_host_tool)).

callback_registry(_, [], _, _, _, _, none, []) :- !.
callback_registry(RequestId, Requested, Schemas,
                  Token, Endpoint, Generation, Registry, Capabilities) :-
    maplist(callback_grant(Schemas), Requested, Names),
    sort(Names, UniqueNames),
    length(UniqueNames, Count),
    length(Names, Count),
    !,
    rlm_tool:tool_registry_create(Registry),
    catch(( maplist(register_callback_tool(Registry, RequestId,
                                           Token, Endpoint, Generation,
                                           Schemas),
                    UniqueNames),
            maplist(wrap_tool_capability, UniqueNames, Capabilities)
          ),
          Error,
          ( rlm_tool:tool_registry_destroy(Registry), throw(Error) )).
callback_registry(_, _, _, _, _, _, _, _) :-
    throw(zara_runtime_fault(invalid_host_tools)).

callback_grant(Schemas, Name0, Name) :-
    normalize_atom(host_tool, Name0, Name),
    member(Schema, Schemas),
    Schema.name == Name,
    !.
callback_grant(_, _, _) :-
    throw(zara_runtime_fault(unknown_host_tool)).

register_callback_tool(Registry, RequestId, Token, Endpoint,
                       Generation, Schemas, Name) :-
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
    zara_host_callback(_, _, _, _),
    !,
    rlm_tool:tool_registry_destroy(Registry).
release_host_registry(_).

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
        Reply = _{
            protocol:"ZARA-RUNTIME/1",
            runtime_id:"prolog-rlm",
            request_id:RequestId,
            status:"cancel_requested",
            found:true
        }
    ;   Reply = _{
            protocol:"ZARA-RUNTIME/1",
            runtime_id:"prolog-rlm",
            request_id:RequestId,
            status:"not_found",
            found:false
        }
    ).

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
            get_dict(generation, Body, Generation),
            get_dict(tools, Body, WireTools),
            is_list(WireTools),
            maplist(host_tool_from_wire, WireTools, Schemas),
            zara_runtime_set_host_callback(Token, Endpoint,
                                           Generation, Schemas),
            Reply = _{protocol:"ZARA-RUNTIME/1", status:"configured",
                      generation:Generation}
          ),
          Error,
          ( error_kind(Error, Kind, Message),
            Reply = _{protocol:"ZARA-RUNTIME/1", status:"failed",
                      error:_{kind:Kind, message:Message}}
          )),
    reply_json_dict(Reply).

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
    \+ get_dict(effect, Wire, _),
    \+ get_dict(capability, Wire, _),
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
                         capability:tool(Name), effect:read,
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
    project_outcome(RequestId, Mode, Outcome, Reply).

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
    ;  Options = [tool_registry(ToolRegistry)|Base]
    ).

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
               ( zara_request_token(RequestId, _)
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
