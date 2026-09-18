:- module(rlm_zara_runtime,
          [ zara_runtime_protocol/1,
            zara_runtime_descriptor/1,
            zara_runtime_health/1,
            zara_runtime_execute/2,
            zara_runtime_cancel/2,
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
:- use_module(library(lists)).
:- use_module(rlm).
:- use_module(rlm_chain,
              [ openrouter_provider/2,
                openai_compatible_provider/4,
                default_openrouter_model/1
              ]).

:- dynamic zara_server_port/1.
:- dynamic zara_request_token/2.

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

zara_runtime_protocol("ZARA-RUNTIME/1").

zara_runtime_descriptor(Descriptor) :-
    rlm:rlm_version(Version0),
    text_string(Version0, Version),
    zara_runtime_protocol(Protocol),
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
        profiles:[],
        provider_control:"runtime",
        model_control:"runtime",
        supports_streaming:false,
        supports_cancel:true,
        supports_context_handles:false,
        supports_host_tools:false,
        provenance:_{kind:"prolog-rlm", source:"local"}
    }.

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
        execute_mode(Mode,
                     RequestId,
                     Prompt,
                     Context,
                     ProviderName,
                     Provider,
                     Budget,
                     MaxTokens,
                     Token,
                     Reply),
        unregister_request(RequestId, Token)).

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
    ;   Address = localhost:Port,
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
    catch(( http_read_json_dict(HttpRequest, Body,
                                [value_string_as(string)]),
            zara_runtime_execute(Body, Reply)
          ),
          _,
          Reply = _{
              protocol:"ZARA-RUNTIME/1",
              runtime_id:"prolog-rlm",
              status:"failed",
              error:_{kind:"invalid_request",
                      message:"request body is invalid"}
          }),
    reply_json_dict(Reply).

zara_cancel_handler(HttpRequest) :-
    catch(( http_read_json_dict(HttpRequest, Body,
                                [value_string_as(string)]),
            get_dict(request_id, Body, RequestId),
            zara_runtime_cancel(RequestId, Reply)
          ),
          _,
          Reply = _{
              protocol:"ZARA-RUNTIME/1",
              runtime_id:"prolog-rlm",
              status:"failed",
              error:_{kind:"invalid_request",
                      message:"cancel request is invalid"}
          }),
    reply_json_dict(Reply).

/* Execution ----------------------------------------------------------- */

execute_mode(Mode,
             RequestId,
             Prompt,
             Context,
             ProviderName,
             Provider,
             Budget,
             MaxTokens,
             Token,
             Reply) :-
    runtime_options(RequestId,
                    ProviderName,
                    Provider,
                    Budget,
                    MaxTokens,
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
                Token,
                [ provider(Provider),
                  provider_name(ProviderName),
                  planner_max_tokens(MaxTokens),
                  cancel_token(Token),
                  trace_id(RequestId),
                  capabilities([rlm,
                                context(peek),
                                context(search),
                                context(slice),
                                model(ProviderName)]),
                  child_capabilities([model(ProviderName)]),
                  budget(Budget)
                ]).

project_outcome(RequestId, Mode, ok(Result), Reply) :-
    !,
    outcome_text(Mode, Result, Text),
    rlm:trace_encode(Result, Encoded),
    Reply = _{
        protocol:"ZARA-RUNTIME/1",
        runtime_id:"prolog-rlm",
        request_id:RequestId,
        status:"completed",
        text:Text,
        result:Encoded
    }.
project_outcome(RequestId, _Mode, error(Error), Reply) :-
    !,
    rlm:trace_encode(Error, Encoded),
    Reply = _{
        protocol:"ZARA-RUNTIME/1",
        runtime_id:"prolog-rlm",
        request_id:RequestId,
        status:"failed",
        error:_{kind:"runtime_error",
                message:"Prolog-RLM did not complete the request",
                detail:Encoded}
    }.
project_outcome(RequestId, _Mode, Other, Reply) :-
    rlm:trace_encode(Other, Encoded),
    Reply = _{
        protocol:"ZARA-RUNTIME/1",
        runtime_id:"prolog-rlm",
        request_id:RequestId,
        status:"failed",
        error:_{kind:"runtime_error",
                message:"Prolog-RLM returned an invalid outcome",
                detail:Encoded}
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