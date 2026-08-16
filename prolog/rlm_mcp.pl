:- module(rlm_mcp,
          [ rlm_mcp_ready/0,
            mcp_client_connect/5,
            mcp_client_connect_async/5,
            mcp_client_command/4,
            mcp_client_command_async/4,
            mcp_client_close/2,
            mcp_client_close_async/2,
            mcp_client_trace/2,
            mcp_client_protocol/2,
            mcp_server_new/5,
            mcp_server_handle/6,
            mcp_server_handle_async/6,
            mcp_server_trace/2,
            mcp_command_normalize/2,
            mcp_tool_normalize/2,
            mcp_resource_normalize/2,
            mcp_prompt_normalize/2
          ]).

/** <module> Model Context Protocol interoperability

The public runtime is command-oriented and version-neutral. Protocol selection,
wire methods, HTTP routing metadata, and legacy session state terminate at this
facade and its version adapters.

Latency-bearing client and server operations are canonical async-first. Async
predicates submit only execute predicates through rlm_async; synchronous
predicates start the same Future and await it. Stateful async command/server
operations return the updated state in their Future result rather than relying
on output variables copied into worker threads.
*/

:- use_module(rlm_mcp_model,
              [ mcp_command_normalize/2,
                mcp_tool_normalize/2,
                mcp_resource_normalize/2,
                mcp_prompt_normalize/2
              ]).
:- use_module(rlm_mcp_transport).
:- use_module(rlm_mcp_transport_send).
:- use_module(rlm_mcp_v2025_11_25).
:- use_module(rlm_mcp_v2026_07_28).
:- use_module(rlm_mcp_compat).
:- use_module(rlm_async, []).
:- use_module(library(option)).

:- dynamic mcp_connect_generation/1.

mcp_connect_generation(0).

rlm_mcp_ready :-
    mcp_2025_protocol_version('2025-11-25'),
    mcp_2026_protocol_version('2026-07-28').

/* -------------------------------------------------------------------------
 * Canonical async helpers
 * ---------------------------------------------------------------------- */

mcp_client_connect_async(TransportSpec, ClientInfo, ClientCaps, Options, Future) :-
    mcp_subject(TransportSpec, Subject),
    mcp_task_metadata(mcp_connect, Subject, Options, Metadata),
    rlm_async:rlm_async_submit(
        rlm_mcp:mcp_client_connect_execute(TransportSpec,
                                           ClientInfo,
                                           ClientCaps,
                                           Options),
        Metadata,
        Future).

mcp_client_command_async(Client0, Command0, Options, Future) :-
    mcp_client_subject(Client0, Subject),
    mcp_task_metadata(mcp_command, Subject, Options, Metadata),
    rlm_async:rlm_async_submit(
        rlm_mcp:mcp_client_command_execute(Client0, Command0),
        Metadata,
        Future).

mcp_client_close_async(Client, Future) :-
    mcp_client_subject(Client, Subject),
    mcp_task_metadata(mcp_close, Subject, [], Metadata),
    rlm_async:rlm_async_submit(
        rlm_mcp:mcp_client_close_execute(Client),
        Metadata,
        Future).

mcp_server_handle_async(Server0, Wire, RequestMeta, Dispatch, Options, Future) :-
    mcp_task_metadata(mcp_server_handle, server, Options, Metadata),
    rlm_async:rlm_async_submit(
        rlm_mcp:mcp_server_handle_execute(Server0,
                                          Wire,
                                          RequestMeta,
                                          Dispatch),
        Metadata,
        Future).

await_mcp_future(Future, Result) :-
    setup_call_cleanup(
        true,
        rlm_async:rlm_future_await(Future, Result),
        rlm_async:rlm_future_destroy(Future)).

mcp_task_metadata(Operation, Subject0, Options, Metadata) :-
    metadata_ground(Subject0, unknown, Subject),
    metadata_option(trace_id, Options, none, TraceId),
    metadata_option(session_id, Options, none, SessionId),
    Metadata = async_metadata{
                   operation:Operation,
                   mcp_subject:Subject,
                   trace_id:TraceId,
                   session_id:SessionId
               }.

metadata_option(Name, Options, Default, Value) :-
    (   is_list(Options),
        member(Option, Options),
        Option =.. [Name, Found],
        ground(Found)
    ->  Value = Found
    ;   Value = Default
    ).

metadata_ground(Value, _, Value) :-
    ground(Value),
    !.
metadata_ground(_, Default, Default).

mcp_subject(Spec, Subject) :-
    catch(endpoint_identity(Spec, Subject0), _, fail),
    ground(Subject0),
    !,
    Subject = Subject0.
mcp_subject(_, unknown).

mcp_client_subject(Client, Subject) :-
    is_dict(Client, mcp_client),
    get_dict(endpoint, Client, Endpoint),
    ground(Endpoint),
    !,
    Subject = Endpoint.
mcp_client_subject(_, unknown).

/* -------------------------------------------------------------------------
 * Client negotiation
 * ---------------------------------------------------------------------- */

mcp_client_connect(TransportSpec, ClientInfo, ClientCaps, Options, Outcome) :-
    mcp_client_connect_async(TransportSpec,
                             ClientInfo,
                             ClientCaps,
                             Options,
                             Future),
    await_mcp_future(Future, FutureResult),
    mcp_simple_future_result(FutureResult, Outcome).

mcp_client_connect_execute(TransportSpec, ClientInfo, ClientCaps, Options,
                           Outcome) :-
    catch(client_connect(TransportSpec,
                         ClientInfo,
                         ClientCaps,
                         Options,
                         Outcome),
          Exception,
          runtime_exception(connect, Exception, Outcome)).

mcp_simple_future_result(error(Error), error(Error)) :- !.
mcp_simple_future_result(Result, Result).

client_connect(TransportSpec, ClientInfo, ClientCaps, Options, Outcome) :-
    mcp_transport_open(TransportSpec, Options, TransportOutcome),
    (   TransportOutcome = ok(Transport)
    ->  mcp_transport_kind(Transport, Kind),
        endpoint_identity(TransportSpec, Endpoint),
        next_connect_generation(Generation),
        option(cache_max_age(MaxAge), Options, 32),
        option(protocol(Protocol0), Options, auto),
        normalize_protocol_option(Protocol0, Protocol),
        trace_empty(Trace0),
        connect_selected(Protocol,
                         Transport,
                         Kind,
                         Endpoint,
                         Generation,
                         MaxAge,
                         ClientInfo,
                         ClientCaps,
                         Trace0,
                         Outcome)
    ;   TransportOutcome = error(Error),
        Outcome = error(Error)
    ).

connect_selected('2025-11-25', Transport, Kind, Endpoint, Generation, _,
                 ClientInfo, ClientCaps, Trace0, Outcome) :-
    !,
    connect_2025(Transport,
                 Kind,
                 Endpoint,
                 Generation,
                 ClientInfo,
                 ClientCaps,
                 1,
                 explicit,
                 Trace0,
                 Outcome).
connect_selected('2026-07-28', Transport, Kind, Endpoint, Generation, _,
                 ClientInfo, ClientCaps, Trace0, Outcome) :-
    !,
    connect_2026_discover(Transport,
                          Kind,
                          Endpoint,
                          Generation,
                          ClientInfo,
                          ClientCaps,
                          1,
                          false,
                          Trace0,
                          Outcome).
connect_selected(auto, Transport, Kind, Endpoint, Generation, MaxAge,
                 ClientInfo, ClientCaps, Trace0, Outcome) :-
    mcp_compat_cache_lookup(Endpoint,
                            Kind,
                            Generation,
                            MaxAge,
                            CacheOutcome),
    connect_from_cache(CacheOutcome,
                       Transport,
                       Kind,
                       Endpoint,
                       Generation,
                       ClientInfo,
                       ClientCaps,
                       Trace0,
                       Outcome).

connect_from_cache(ok(Entry), Transport, Kind, Endpoint, Generation,
                   ClientInfo, ClientCaps, Trace0, Outcome) :-
    !,
    Selected = Entry.selected,
    (   Selected == '2026-07-28'
    ->  mcp_2026_client_state_new(ClientInfo,
                                  ClientCaps,
                                  Kind,
                                  StateOutcome),
        connect_cached_2026(StateOutcome,
                            Transport,
                            Endpoint,
                            Generation,
                            ClientInfo,
                            ClientCaps,
                            Entry,
                            Trace0,
                            Outcome)
    ;   connect_2025(Transport,
                     Kind,
                     Endpoint,
                     Generation,
                     ClientInfo,
                     ClientCaps,
                     1,
                     cache,
                     Trace0,
                     Outcome)
    ).
connect_from_cache(_, Transport, Kind, Endpoint, Generation,
                   ClientInfo, ClientCaps, Trace0, Outcome) :-
    connect_2026_discover(Transport,
                          Kind,
                          Endpoint,
                          Generation,
                          ClientInfo,
                          ClientCaps,
                          1,
                          true,
                          Trace0,
                          Outcome).

connect_cached_2026(error(Error), Transport, _, _, _, _, _, _,
                    error(Error)) :-
    !,
    mcp_transport_close(Transport, _).
connect_cached_2026(ok(State), Transport, Endpoint, Generation,
                    ClientInfo, ClientCaps, Entry, Trace0, ok(Client)) :-
    trace_emit(connected,
               State,
               _{transport:State.transport},
               Trace0,
               Trace1),
    trace_emit(protocol_selected,
               State,
               _{source:cache,
                 verified_versions:Entry.verified_versions},
               Trace1,
               Trace),
    make_client(Transport,
                State,
                Endpoint,
                Generation,
                ClientInfo,
                ClientCaps,
                1,
                Trace,
                Client).

connect_2026_discover(Transport, Kind, Endpoint, Generation,
                      ClientInfo, ClientCaps, Id, AllowFallback,
                      Trace0, Outcome) :-
    mcp_2026_client_state_new(ClientInfo, ClientCaps, Kind, StateOutcome),
    (   StateOutcome = ok(State0)
    ->  trace_emit(connected,
                   State0,
                   _{transport:Kind},
                   Trace0,
                   Trace1),
        mcp_2026_client_discover(State0, Id, Wire, Meta, EncodeOutcome),
        connect_2026_discover_exchange(EncodeOutcome,
                                       Transport,
                                       Kind,
                                       Endpoint,
                                       Generation,
                                       ClientInfo,
                                       ClientCaps,
                                       Id,
                                       AllowFallback,
                                       State0,
                                       Wire,
                                       Meta,
                                       Trace1,
                                       Outcome)
    ;   StateOutcome = error(Error),
        mcp_transport_close(Transport, _),
        Outcome = error(Error)
    ).

connect_2026_discover_exchange(error(Error), Transport, _, _, _, _, _, _, _,
                               _, _, _, _, error(Error)) :-
    !,
    mcp_transport_close(Transport, _).
connect_2026_discover_exchange(ok, Transport, Kind, Endpoint, Generation,
                               ClientInfo, ClientCaps, Id, AllowFallback,
                               State0, Wire, Meta, Trace0, Outcome) :-
    trace_emit(discover_sent,
               State0,
               _{request_id:Id},
               Trace0,
               Trace1),
    mcp_transport_exchange(Transport, Wire, Meta, ExchangeOutcome),
    accept_discover_exchange(ExchangeOutcome,
                             Transport,
                             Kind,
                             Endpoint,
                             Generation,
                             ClientInfo,
                             ClientCaps,
                             Id,
                             AllowFallback,
                             State0,
                             Trace1,
                             Outcome).

accept_discover_exchange(ok(Response), Transport, Kind, Endpoint, Generation,
                         ClientInfo, ClientCaps, Id, AllowFallback,
                         State0, Trace0, Outcome) :-
    mcp_2026_client_accept_discover(State0,
                                    Id,
                                    Response,
                                    State,
                                    AcceptOutcome),
    (   AcceptOutcome = ok
    ->  cache_store_quiet(Endpoint,
                          Kind,
                          State.supported_versions,
                          '2026-07-28',
                          discovery,
                          Generation),
        trace_emit(protocol_selected,
                   State,
                   _{source:discovery,
                     supported_versions:State.supported_versions},
                   Trace0,
                   Trace),
        NextId is Id+1,
        make_client(Transport,
                    State,
                    Endpoint,
                    Generation,
                    ClientInfo,
                    ClientCaps,
                    NextId,
                    Trace,
                    Client),
        Outcome = ok(Client)
    ;   AcceptOutcome = error(Error),
        discover_failed(Error,
                        Transport,
                        Kind,
                        Endpoint,
                        Generation,
                        ClientInfo,
                        ClientCaps,
                        Id,
                        AllowFallback,
                        State0,
                        Trace0,
                        Outcome)
    ).
accept_discover_exchange(error(Error), Transport, Kind, Endpoint, Generation,
                         ClientInfo, ClientCaps, Id, AllowFallback,
                         State0, Trace0, Outcome) :-
    discover_failed(Error,
                    Transport,
                    Kind,
                    Endpoint,
                    Generation,
                    ClientInfo,
                    ClientCaps,
                    Id,
                    AllowFallback,
                    State0,
                    Trace0,
                    Outcome).

discover_failed(Error, Transport, Kind, Endpoint, Generation,
                ClientInfo, ClientCaps, FailedId, true, State0,
                Trace0, Outcome) :-
    !,
    cache_invalidate_quiet(Endpoint),
    trace_emit(protocol_fallback,
               State0,
               _{from:'2026-07-28',
                 to:'2025-11-25',
                 reason:Error},
               Trace0,
               Trace1),
    InitId is FailedId+1,
    connect_2025(Transport,
                 Kind,
                 Endpoint,
                 Generation,
                 ClientInfo,
                 ClientCaps,
                 InitId,
                 fallback,
                 Trace1,
                 Outcome).
discover_failed(Error, Transport, _, _, _, _, _, _, false, _, _, error(Error)) :-
    mcp_transport_close(Transport, _).

connect_2025(Transport, Kind, Endpoint, Generation,
             ClientInfo, ClientCaps, InitId, Source, Trace0, Outcome) :-
    mcp_2025_client_state_new(ClientInfo,
                              ClientCaps,
                              Kind,
                              StateOutcome),
    (   StateOutcome = ok(State0)
    ->  trace_emit(connected,
                   State0,
                   _{transport:Kind},
                   Trace0,
                   Trace1),
        trace_emit(protocol_selected,
                   State0,
                   _{source:Source},
                   Trace1,
                   Trace2),
        initialize_client_2025(Transport,
                               State0,
                               InitId,
                               InitOutcome,
                               Trace2,
                               Trace3),
        finish_connect_2025(InitOutcome,
                            Transport,
                            Kind,
                            Endpoint,
                            Generation,
                            ClientInfo,
                            ClientCaps,
                            InitId,
                            Trace3,
                            Outcome)
    ;   StateOutcome = error(Error),
        mcp_transport_close(Transport, _),
        Outcome = error(Error)
    ).

finish_connect_2025(error(Error), Transport, _, _, _, _, _, _, _, error(Error)) :-
    !,
    mcp_transport_close(Transport, _).
finish_connect_2025(ok(State), Transport, Kind, Endpoint, Generation,
                    ClientInfo, ClientCaps, InitId, Trace, ok(Client)) :-
    cache_store_quiet(Endpoint,
                      Kind,
                      ['2025-11-25'],
                      '2025-11-25',
                      initialize,
                      Generation),
    NextId is InitId+1,
    make_client(Transport,
                State,
                Endpoint,
                Generation,
                ClientInfo,
                ClientCaps,
                NextId,
                Trace,
                Client).

make_client(Transport, State, Endpoint, Generation,
            ClientInfo, ClientCaps, NextId, Trace,
            mcp_client{transport:Transport,
                       adapter_state:State,
                       endpoint:Endpoint,
                       generation:Generation,
                       client_info:ClientInfo,
                       client_capabilities:ClientCaps,
                       next_id:NextId,
                       protocol_retry_count:0,
                       protocol_retry_limit:1,
                       trace:Trace}).

initialize_client_2025(Transport, State0, Id, Outcome, Trace0, Trace) :-
    mcp_2025_client_initialize(State0, Id, Wire, Meta, EncodeOutcome),
    (   EncodeOutcome = ok
    ->  trace_emit(initialize_sent,
                   State0,
                   _{request_id:Id},
                   Trace0,
                   Trace1),
        mcp_transport_exchange(Transport, Wire, Meta, ExchangeOutcome),
        accept_initialize_exchange_2025(ExchangeOutcome,
                                        Transport,
                                        State0,
                                        Id,
                                        Outcome,
                                        Trace1,
                                        Trace)
    ;   EncodeOutcome = error(Error),
        Outcome = error(Error),
        Trace = Trace0
    ).

accept_initialize_exchange_2025(error(Error), _, _, _, error(Error), Trace, Trace) :-
    !.
accept_initialize_exchange_2025(ok(Response), Transport, State0, Id,
                                Outcome, Trace0, Trace) :-
    mcp_2025_client_accept_initialize(State0,
                                      Id,
                                      Response,
                                      State1,
                                      AcceptOutcome),
    (   AcceptOutcome = ok
    ->  trace_emit(initialized_negotiated,
                   State1,
                   _{session_id:State1.session_id},
                   Trace0,
                   Trace1),
        mcp_2025_client_initialized(State1,
                                    Notification,
                                    NotificationMeta,
                                    NotificationOutcome),
        send_initialized_2025(NotificationOutcome,
                              Transport,
                              State1,
                              Notification,
                              NotificationMeta,
                              Outcome,
                              Trace1,
                              Trace)
    ;   AcceptOutcome = error(Error),
        Outcome = error(Error),
        Trace = Trace0
    ).

send_initialized_2025(error(Error), _, _, _, _, error(Error), Trace, Trace) :-
    !.
send_initialized_2025(ok(StateMaybe), Transport, State0, Wire, Meta,
                      Outcome, Trace0, Trace) :-
    mcp_transport_send(Transport, Wire, Meta, SendOutcome),
    (   SendOutcome = ok(sent)
    ->  normalize_ready_state_2025(StateMaybe, State0, State),
        trace_emit(ready,
                   State,
                   _{protocol_version:'2025-11-25'},
                   Trace0,
                   Trace),
        Outcome = ok(State)
    ;   SendOutcome = error(Error),
        Outcome = error(Error),
        Trace = Trace0
    ).

normalize_ready_state_2025(StateMaybe, _, StateMaybe) :-
    is_dict(StateMaybe, mcp_2025_client),
    StateMaybe.phase == ready,
    !.
normalize_ready_state_2025(_, State0, State) :-
    put_dict(phase, State0, ready, State).

/* -------------------------------------------------------------------------
 * Client commands
 * ---------------------------------------------------------------------- */

mcp_client_command(Client0, Command0, Client, Outcome) :-
    mcp_client_command_async(Client0, Command0, [], Future),
    await_mcp_future(Future, FutureResult),
    mcp_command_future_result(FutureResult, Client0, Client, Outcome).

mcp_client_command_execute(Client0, Command0, Result) :-
    catch(client_command(Client0, Command0, Client, Outcome),
          Exception,
          ( Client = Client0,
            runtime_exception(command, Exception, Outcome)
          )),
    Result = mcp_command_async_result{client:Client, outcome:Outcome}.

mcp_command_future_result(Result, _, Client, Outcome) :-
    is_dict(Result, mcp_command_async_result),
    !,
    Client = Result.client,
    Outcome = Result.outcome.
mcp_command_future_result(error(Error), Client0, Client0, error(Error)) :- !.
mcp_command_future_result(Other, Client0, Client0, error(Error)) :-
    term_string(Other, Safe, [quoted(true), numbervars(true)]),
    Error = mcp_error{phase:runtime,
                      kind:invalid_async_result,
                      detail:Safe,
                      message:"asynchronous MCP command returned an invalid result"}.

client_command(Client0, Command0, Client, Outcome) :-
    require_client(Client0),
    mcp_command_normalize(Command0, CommandOutcome),
    (   CommandOutcome = ok(Command)
    ->  command_once(Client0, Command, true, Client, Outcome)
    ;   CommandOutcome = error(Error),
        Client = Client0,
        Outcome = error(Error)
    ).

command_once(Client0, Command, AllowSessionRecovery, Client, Outcome) :-
    State = Client0.adapter_state,
    (   is_dict(State, mcp_2026_client)
    ->  command_once_2026(Client0, Command, Client, Outcome)
    ;   is_dict(State, mcp_2025_client)
    ->  command_once_2025(Client0,
                          Command,
                          AllowSessionRecovery,
                          Client,
                          Outcome)
    ;   Client = Client0,
        Outcome = error(mcp_error{phase:runtime,
                                  kind:invalid_adapter_state,
                                  message:"MCP client has an unknown adapter state"})
    ).

command_once_2026(Client0, Command, Client, Outcome) :-
    Id = Client0.next_id,
    State0 = Client0.adapter_state,
    mcp_2026_client_command(State0,
                            Id,
                            Command,
                            Wire,
                            Meta,
                            EncodeOutcome),
    (   EncodeOutcome = ok(_)
    ->  trace_emit(command_sent,
                   State0,
                   _{request_id:Id, operation:Command.op},
                   Client0.trace,
                   Trace1),
        mcp_transport_exchange(Client0.transport,
                               Wire,
                               Meta,
                               ExchangeOutcome),
        command_exchange_2026(ExchangeOutcome,
                              Client0,
                              Command,
                              Id,
                              Trace1,
                              Client,
                              Outcome)
    ;   EncodeOutcome = error(Error),
        Client = Client0,
        Outcome = error(Error)
    ).

command_exchange_2026(error(Error), Client0, _, _, _, Client0, error(Error)) :-
    !.
command_exchange_2026(ok(Response), Client0, Command, Id, Trace0,
                      Client, Outcome) :-
    mcp_2026_client_decode(Client0.adapter_state,
                           Id,
                           Command,
                           Response,
                           DecodeOutcome),
    (   DecodeOutcome = error(Error),
        protocol_fallback_allowed(Client0, Error)
    ->  fallback_command_to_2025(Client0,
                                 Command,
                                 Id,
                                 Error,
                                 Trace0,
                                 Client,
                                 Outcome)
    ;   finish_command_2026(DecodeOutcome,
                            Client0,
                            Command,
                            Id,
                            Trace0,
                            Client,
                            Outcome)
    ).

finish_command_2026(error(Error), Client0, _, _, _, Client0, error(Error)) :- !.
finish_command_2026(ok(Result), Client0, Command, Id, Trace0,
                    Client, ok(Result)) :-
    NextId is Id+1,
    trace_emit(command_completed,
               Client0.adapter_state,
               _{request_id:Id, operation:Command.op},
               Trace0,
               Trace),
    cache_store_quiet(Client0.endpoint,
                      Client0.adapter_state.transport,
                      Client0.adapter_state.supported_versions,
                      '2026-07-28',
                      command_success,
                      Client0.generation),
    put_dict(_{next_id:NextId, trace:Trace}, Client0, Client).

protocol_fallback_allowed(Client, Error) :-
    is_dict(Error),
    get_dict(kind, Error, unsupported_protocol_version),
    get_dict(supported, Error, Supported),
    memberchk('2025-11-25', Supported),
    Client.protocol_retry_count < Client.protocol_retry_limit.

fallback_command_to_2025(Client0, Command, FailedId, Error, Trace0,
                         Client, Outcome) :-
    cache_invalidate_quiet(Client0.endpoint),
    State2026 = Client0.adapter_state,
    trace_emit(protocol_rejected,
               State2026,
               _{failed_request_id:FailedId,
                 reason:Error,
                 advertised_versions:Error.supported},
               Trace0,
               Trace1),
    mcp_2025_client_state_new(Client0.client_info,
                              Client0.client_capabilities,
                              State2026.transport,
                              StateOutcome),
    (   StateOutcome = ok(State0)
    ->  trace_emit(protocol_fallback,
                   State0,
                   _{from:'2026-07-28', to:'2025-11-25'},
                   Trace1,
                   Trace2),
        InitId is FailedId+1,
        initialize_client_2025(Client0.transport,
                               State0,
                               InitId,
                               InitOutcome,
                               Trace2,
                               Trace3),
        retry_after_protocol_fallback(InitOutcome,
                                      Client0,
                                      Command,
                                      InitId,
                                      Trace3,
                                      Client,
                                      Outcome)
    ;   StateOutcome = error(NewError),
        Client = Client0,
        Outcome = error(NewError)
    ).

retry_after_protocol_fallback(error(Error), Client0, _, _, _,
                              Client0, error(Error)) :- !.
retry_after_protocol_fallback(ok(State), Client0, Command, InitId, Trace,
                              Client, Outcome) :-
    RetryCount is Client0.protocol_retry_count+1,
    CommandId is InitId+1,
    cache_store_quiet(Client0.endpoint,
                      State.transport,
                      ['2025-11-25'],
                      '2025-11-25',
                      unsupported_version,
                      Client0.generation),
    Temp = Client0.put(_{adapter_state:State,
                         next_id:CommandId,
                         protocol_retry_count:RetryCount,
                         trace:Trace}),
    command_once_2025(Temp, Command, true, Client, Outcome).

command_once_2025(Client0, Command, AllowRecovery, Client, Outcome) :-
    Id = Client0.next_id,
    State0 = Client0.adapter_state,
    mcp_2025_client_command(State0,
                            Id,
                            Command,
                            Wire,
                            Meta,
                            EncodeOutcome),
    (   EncodeOutcome = ok(_)
    ->  trace_emit(command_sent,
                   State0,
                   _{request_id:Id, operation:Command.op},
                   Client0.trace,
                   Trace1),
        mcp_transport_exchange(Client0.transport,
                               Wire,
                               Meta,
                               ExchangeOutcome),
        command_exchange_2025(ExchangeOutcome,
                              Client0,
                              Command,
                              Id,
                              AllowRecovery,
                              Trace1,
                              Client,
                              Outcome)
    ;   EncodeOutcome = error(Error),
        Client = Client0,
        Outcome = error(Error)
    ).

command_exchange_2025(error(Error), Client0, _, _, _, _, Client0, error(Error)) :-
    !.
command_exchange_2025(ok(Response), Client0, Command, Id, AllowRecovery, Trace0,
                      Client, Outcome) :-
    (   Response.status =:= 404,
        AllowRecovery == true
    ->  recover_and_retry_2025(Client0,
                               Command,
                               Id,
                               Trace0,
                               Client,
                               Outcome)
    ;   mcp_2025_client_decode(Client0.adapter_state,
                               Id,
                               Command,
                               Response,
                               DecodeOutcome),
        finish_command_2025(DecodeOutcome,
                            Client0,
                            Command,
                            Id,
                            Trace0,
                            Client,
                            Outcome)
    ).

finish_command_2025(error(Error), Client0, _, _, _, Client0, error(Error)) :- !.
finish_command_2025(ok(Result), Client0, Command, Id, Trace0,
                    Client, ok(Result)) :-
    NextId is Id+1,
    trace_emit(command_completed,
               Client0.adapter_state,
               _{request_id:Id, operation:Command.op},
               Trace0,
               Trace),
    put_dict(_{next_id:NextId, trace:Trace}, Client0, Client).

recover_and_retry_2025(Client0, Command, FailedId, Trace0, Client, Outcome) :-
    mcp_2025_client_recover_404(Client0.adapter_state, RecoveryOutcome),
    (   RecoveryOutcome = ok(ResetState)
    ->  trace_emit(session_invalidated,
                   ResetState,
                   _{failed_request_id:FailedId},
                   Trace0,
                   Trace1),
        InitId is FailedId+1,
        initialize_client_2025(Client0.transport,
                               ResetState,
                               InitId,
                               InitOutcome,
                               Trace1,
                               Trace2),
        retry_after_reinitialize_2025(InitOutcome,
                                      Client0,
                                      Command,
                                      InitId,
                                      Trace2,
                                      Client,
                                      Outcome)
    ;   RecoveryOutcome = error(Error),
        Client = Client0,
        Outcome = error(Error)
    ).

retry_after_reinitialize_2025(error(Error), Client0, _, _, _,
                              Client0, error(Error)) :- !.
retry_after_reinitialize_2025(ok(State), Client0, Command, InitId, Trace,
                              Client, Outcome) :-
    CommandId is InitId+1,
    Temp = Client0.put(_{adapter_state:State,
                         next_id:CommandId,
                         trace:Trace}),
    command_once_2025(Temp, Command, false, Client, Outcome).

mcp_client_close(Client, Outcome) :-
    mcp_client_close_async(Client, Future),
    await_mcp_future(Future, FutureResult),
    mcp_simple_future_result(FutureResult, Outcome).

mcp_client_close_execute(Client, Outcome) :-
    (   is_dict(Client, mcp_client)
    ->  mcp_transport_close(Client.transport, Outcome)
    ;   Outcome = error(mcp_error{phase:runtime,
                                  kind:invalid_client,
                                  message:"invalid MCP client handle"})
    ).

mcp_client_trace(Client, Events) :-
    require_client(Client),
    Events = Client.trace.

mcp_client_protocol(Client, Protocol) :-
    require_client(Client),
    Protocol = Client.adapter_state.protocol_version.

/* -------------------------------------------------------------------------
 * Dual-version server
 * ---------------------------------------------------------------------- */

mcp_server_new(TransportKind, ServerInfo, ServerCaps, Options, Outcome) :-
    option(session_id(SessionId), Options, null),
    mcp_2025_server_state_new(ServerInfo,
                              ServerCaps,
                              TransportKind,
                              SessionId,
                              State2025Outcome),
    mcp_2026_server_state_new(ServerInfo,
                              ServerCaps,
                              TransportKind,
                              State2026Outcome),
    server_new_states(State2025Outcome,
                      State2026Outcome,
                      TransportKind,
                      Outcome).

server_new_states(error(Error), _, _, error(Error)) :- !.
server_new_states(_, error(Error), _, error(Error)) :- !.
server_new_states(ok(State2025), ok(State2026), TransportKind, ok(Server)) :-
    trace_empty(Trace0),
    trace_emit(server_created,
               State2025,
               _{transport:TransportKind,
                 supported_protocols:['2026-07-28', '2025-11-25']},
               Trace0,
               Trace),
    Server = mcp_server{adapter_state:State2025,
                        adapter_2026:State2026,
                        trace:Trace}.

mcp_server_handle(Server0, Wire, RequestMeta, Dispatch, Server, Outcome) :-
    mcp_server_handle_async(Server0,
                            Wire,
                            RequestMeta,
                            Dispatch,
                            [],
                            Future),
    await_mcp_future(Future, FutureResult),
    mcp_server_future_result(FutureResult, Server0, Server, Outcome).

mcp_server_handle_execute(Server0, Wire, RequestMeta, Dispatch, Result) :-
    catch(server_handle(Server0,
                        Wire,
                        RequestMeta,
                        Dispatch,
                        Server,
                        Outcome),
          Exception,
          ( Server = Server0,
            runtime_exception(server, Exception, Outcome)
          )),
    Result = mcp_server_async_result{server:Server, outcome:Outcome}.

mcp_server_future_result(Result, _, Server, Outcome) :-
    is_dict(Result, mcp_server_async_result),
    !,
    Server = Result.server,
    Outcome = Result.outcome.
mcp_server_future_result(error(Error), Server0, Server0, error(Error)) :- !.
mcp_server_future_result(Other, Server0, Server0, error(Error)) :-
    term_string(Other, Safe, [quoted(true), numbervars(true)]),
    Error = mcp_error{phase:runtime,
                      kind:invalid_async_result,
                      detail:Safe,
                      message:"asynchronous MCP server operation returned an invalid result"}.

server_handle(Server0, Wire, RequestMeta, Dispatch, Server, Outcome) :-
    require_server(Server0),
    callable(Dispatch),
    detect_server_protocol(Server0, Wire, RequestMeta, Protocol),
    server_handle_protocol(Protocol,
                           Server0,
                           Wire,
                           RequestMeta,
                           Dispatch,
                           Server,
                           Outcome).

server_handle_protocol('2026-07-28', Server0, Wire, RequestMeta, Dispatch,
                       Server, Outcome) :-
    !,
    State0 = Server0.adapter_2026,
    mcp_2026_server_receive(State0,
                            Wire,
                            RequestMeta,
                            Event,
                            ReceiveOutcome),
    handle_server_receive_2026(ReceiveOutcome,
                               Event,
                               Wire,
                               Server0,
                               Dispatch,
                               Server,
                               Outcome).
server_handle_protocol('2025-11-25', Server0, Wire, RequestMeta, Dispatch,
                       Server, Outcome) :-
    State0 = Server0.adapter_state,
    mcp_2025_server_receive(State0,
                            Wire,
                            RequestMeta,
                            Event,
                            ReceiveOutcome),
    handle_server_receive_2025(ReceiveOutcome,
                               Event,
                               Server0,
                               Dispatch,
                               Server,
                               Outcome).

handle_server_receive_2025(error(Error), _, Server, _, Server, Outcome) :-
    !,
    server_error_outcome_2025(Error, Outcome).
handle_server_receive_2025(ok(State), Event, Server0, Dispatch, Server, Outcome) :-
    server_event_2025(Event,
                      State,
                      Server0,
                      Dispatch,
                      Server,
                      Outcome).

server_event_2025(initialize(Id, _, _), State, Server0, _, Server, Outcome) :-
    !,
    mcp_2025_server_initialize_response(State,
                                        Id,
                                        Wire,
                                        ResponseMeta,
                                        EncodeOutcome),
    (   EncodeOutcome = ok
    ->  trace_emit(server_initialized,
                   State,
                   _{request_id:Id},
                   Server0.trace,
                   Trace),
        put_dict(_{adapter_state:State, trace:Trace}, Server0, Server),
        Outcome = ok(mcp_server_reply{wire:Wire,
                                      meta:ResponseMeta,
                                      status:200})
    ;   EncodeOutcome = error(Error),
        Server = Server0,
        Outcome = error(Error)
    ).
server_event_2025(initialized, State, Server0, _, Server,
                  ok(mcp_server_no_reply{})) :-
    !,
    trace_emit(server_ready,
               State,
               _{protocol_version:'2025-11-25'},
               Server0.trace,
               Trace),
    put_dict(_{adapter_state:State, trace:Trace}, Server0, Server).
server_event_2025(command(Id, Command), State, Server0, Dispatch, Server, Outcome) :-
    call_dispatch(Dispatch, Command, DispatchOutcome),
    (   DispatchOutcome = ok(CanonicalResult)
    ->  mcp_2025_server_command_response(State,
                                         Id,
                                         Command,
                                         CanonicalResult,
                                         Wire,
                                         EncodeOutcome),
        finish_server_command_2025(EncodeOutcome,
                                   Id,
                                   Command,
                                   Wire,
                                   State,
                                   Server0,
                                   Server,
                                   Outcome)
    ;   DispatchOutcome = error(Error),
        Server = Server0,
        Outcome = error(Error)
    ).

finish_server_command_2025(error(Error), _, _, _, _, Server, Server,
                           error(Error)) :- !.
finish_server_command_2025(ok, Id, Command, Wire, State, Server0, Server,
                           ok(mcp_server_reply{
                                  wire:Wire,
                                  meta:mcp_transport_response_meta{headers:[]},
                                  status:200})) :-
    trace_emit(server_command_completed,
               State,
               _{request_id:Id, operation:Command.op},
               Server0.trace,
               Trace),
    put_dict(_{adapter_state:State, trace:Trace}, Server0, Server).

handle_server_receive_2026(error(Error), _, Wire, Server0, _, Server0, Outcome) :-
    !,
    server_error_outcome_2026(Error, Wire, Outcome).
handle_server_receive_2026(ok(State), Event, _, Server0, Dispatch,
                           Server, Outcome) :-
    server_event_2026(Event,
                      State,
                      Server0,
                      Dispatch,
                      Server,
                      Outcome).

server_event_2026(discover(Id, _, _), State, Server0, _, Server, Outcome) :-
    !,
    mcp_2026_server_discover_response(State,
                                      Id,
                                      Wire,
                                      ResponseMeta,
                                      EncodeOutcome),
    (   EncodeOutcome = ok
    ->  trace_emit(server_discovered,
                   State,
                   _{request_id:Id},
                   Server0.trace,
                   Trace),
        put_dict(_{adapter_2026:State, trace:Trace}, Server0, Server),
        Outcome = ok(mcp_server_reply{wire:Wire,
                                      meta:ResponseMeta,
                                      status:200})
    ;   EncodeOutcome = error(Error),
        Server = Server0,
        Outcome = error(Error)
    ).
server_event_2026(command(Id, Command), State, Server0, Dispatch, Server, Outcome) :-
    call_dispatch(Dispatch, Command, DispatchOutcome),
    (   DispatchOutcome = ok(CanonicalResult)
    ->  mcp_2026_server_command_response(State,
                                         Id,
                                         Command,
                                         CanonicalResult,
                                         Wire,
                                         EncodeOutcome),
        finish_server_command_2026(EncodeOutcome,
                                   Id,
                                   Command,
                                   Wire,
                                   State,
                                   Server0,
                                   Server,
                                   Outcome)
    ;   DispatchOutcome = error(Error),
        Server = Server0,
        Outcome = error(Error)
    ).

finish_server_command_2026(error(Error), _, _, _, _, Server, Server,
                           error(Error)) :- !.
finish_server_command_2026(ok, Id, Command, Wire, State, Server0, Server,
                           ok(mcp_server_reply{
                                  wire:Wire,
                                  meta:mcp_transport_response_meta{headers:[]},
                                  status:200})) :-
    trace_emit(server_command_completed,
               State,
               _{request_id:Id, operation:Command.op},
               Server0.trace,
               Trace),
    put_dict(_{adapter_2026:State, trace:Trace}, Server0, Server).

server_error_outcome_2026(Error, Wire, Outcome) :-
    (   is_dict(Error),
        get_dict(jsonrpc_code, Error, _),
        is_dict(Wire),
        get_dict(id, Wire, Id),
        mcp_2026_server_error_reply(Id, Error, ErrorWire, Status)
    ->  Outcome = ok(mcp_server_reply{
                         wire:ErrorWire,
                         meta:mcp_transport_response_meta{headers:[]},
                         status:Status})
    ;   Outcome = error(Error)
    ).

server_error_outcome_2025(Error, Outcome) :-
    (   is_dict(Error),
        get_dict(detail, Error, invalid_session)
    ->  Outcome = error(mcp_server_transport_error{status:404,
                                                   cause:Error,
                                                   message:"MCP session is invalid"})
    ;   Outcome = error(Error)
    ).

detect_server_protocol(_, Wire, _, '2025-11-25') :-
    is_dict(Wire),
    get_dict(method, Wire, "initialize"),
    !.
detect_server_protocol(_, Wire, _, '2026-07-28') :-
    wire_protocol_metadata(Wire, _),
    !.
detect_server_protocol(_, _, RequestMeta, '2026-07-28') :-
    request_meta_header(RequestMeta, 'MCP-Protocol-Version', Version0),
    normalize_version_atom(Version0, Version),
    Version \== '2025-11-25',
    !.
detect_server_protocol(_, _, _, '2025-11-25').

wire_protocol_metadata(Wire, Version) :-
    get_dict(params, Wire, Params),
    is_dict(Params),
    get_dict('_meta', Params, Meta),
    is_dict(Meta),
    get_dict('io.modelcontextprotocol/protocolVersion', Meta, Version).

request_meta_header(RequestMeta, Name, Value) :-
    is_dict(RequestMeta),
    get_dict(headers, RequestMeta, Headers),
    is_list(Headers),
    memberchk(Name=Value, Headers).

/* -------------------------------------------------------------------------
 * Dispatch, trace, cache and validation
 * ---------------------------------------------------------------------- */

call_dispatch(Dispatch, Command, Outcome) :-
    catch(( call(Dispatch, Command, Raw)
          -> normalize_dispatch_outcome(Raw, Outcome)
          ;  Outcome = error(mcp_error{phase:server_dispatch,
                                       kind:dispatch_failed,
                                       message:"MCP server dispatch predicate failed"})
          ),
          Exception,
          dispatch_exception(Exception, Outcome)).

normalize_dispatch_outcome(ok(Result), ok(Result)) :- !.
normalize_dispatch_outcome(error(Error), error(Error)) :- !.
normalize_dispatch_outcome(Result, ok(Result)) :- is_dict(Result), !.
normalize_dispatch_outcome(Result,
                           error(mcp_error{phase:server_dispatch,
                                           kind:invalid_dispatch_result,
                                           detail:Result,
                                           message:"MCP dispatch must return a canonical result"})).

dispatch_exception(Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
dispatch_exception(Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = mcp_error{phase:server_dispatch,
                      kind:dispatch_exception,
                      exception:Safe,
                      message:"MCP server dispatch raised an exception"}.

mcp_server_trace(Server, Events) :-
    require_server(Server),
    Events = Server.trace.

trace_empty([]).

trace_emit(Type, State, Detail, Trace0, Trace) :-
    length(Trace0, Previous),
    Sequence is Previous+1,
    state_transport(State, Transport),
    state_protocol(State, Protocol),
    Event = mcp_trace{sequence:Sequence,
                      type:Type,
                      protocol_version:Protocol,
                      transport:Transport,
                      detail:Detail},
    append(Trace0, [Event], Trace).

state_transport(State, Transport) :-
    ( get_dict(transport, State, Transport) -> true ; Transport = unknown ).

state_protocol(State, Protocol) :-
    (   get_dict(protocol_version, State, Value), Value \== null
    ->  Protocol = Value
    ;   is_dict(State, mcp_2025_client)
    ->  Protocol = '2025-11-25'
    ;   is_dict(State, mcp_2025_server)
    ->  Protocol = '2025-11-25'
    ;   Protocol = unknown
    ).

cache_store_quiet(Endpoint, Transport, Versions, Selected, Source, Generation) :-
    mcp_compat_cache_store(Endpoint,
                           Transport,
                           Versions,
                           Selected,
                           Source,
                           Generation,
                           _).

cache_invalidate_quiet(Endpoint) :-
    mcp_compat_cache_invalidate(Endpoint, _).

endpoint_identity(TransportSpec, Endpoint) :-
    term_string(TransportSpec,
                Endpoint,
                [quoted(true), numbervars(true)]).

next_connect_generation(Generation) :-
    with_mutex(rlm_mcp_connect_generation,
               ( retract(mcp_connect_generation(Current)),
                 Generation is Current+1,
                 assertz(mcp_connect_generation(Generation)) )).

normalize_protocol_option(auto, auto) :- !.
normalize_protocol_option(Value, Protocol) :-
    normalize_version_atom(Value, Protocol),
    memberchk(Protocol, ['2025-11-25', '2026-07-28']),
    !.
normalize_protocol_option(Value, _) :-
    throw(mcp_runtime_fault(unsupported_protocol_option(Value))).

normalize_version_atom(Value, Value) :- atom(Value), !.
normalize_version_atom(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
normalize_version_atom(Value, _) :-
    throw(mcp_runtime_fault(invalid_protocol_version(Value))).

require_client(Client) :-
    (   is_dict(Client, mcp_client)
    ->  true
    ;   throw(mcp_runtime_fault(invalid_client(Client)))
    ).

require_server(Server) :-
    (   is_dict(Server, mcp_server)
    ->  true
    ;   throw(mcp_runtime_fault(invalid_server(Server)))
    ).

control_exception(time_limit_exceeded).
control_exception('$aborted').
control_exception(abort).
control_exception(cancelled(_)).
control_exception(rlm_async_cancelled(_)).
control_exception(rlm_cancelled(_)).
control_exception(chain_cancelled(_)).
control_exception(graph_cancelled(_)).

runtime_exception(_, Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
runtime_exception(_, mcp_runtime_fault(Detail), error(Error)) :-
    !,
    Error = mcp_error{phase:runtime,
                      kind:runtime_error,
                      detail:Detail,
                      message:"MCP runtime validation failed"}.
runtime_exception(Operation, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = mcp_error{phase:runtime,
                      kind:exception,
                      operation:Operation,
                      exception:Safe,
                      message:"MCP runtime raised an exception"}.
