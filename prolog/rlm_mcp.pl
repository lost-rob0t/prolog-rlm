:- module(rlm_mcp,
          [ rlm_mcp_ready/0,
            mcp_client_connect/5,
            mcp_client_command/4,
            mcp_client_close/2,
            mcp_client_trace/2,
            mcp_client_protocol/2,
            mcp_server_new/5,
            mcp_server_handle/6,
            mcp_server_trace/2,
            mcp_command_normalize/2,
            mcp_tool_normalize/2,
            mcp_resource_normalize/2,
            mcp_prompt_normalize/2
          ]).

/** <module> Model Context Protocol interoperability

The public runtime is command-oriented and version-neutral.  The 2025-11-25
adapter is selected internally; JSON-RPC method names and session headers never
cross this facade into agent or graph code.
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
:- use_module(library(option)).

rlm_mcp_ready :-
    mcp_2025_protocol_version('2025-11-25').

/* -------------------------------------------------------------------------
 * Client
 * ---------------------------------------------------------------------- */

mcp_client_connect(TransportSpec, ClientInfo, ClientCaps, Options, Outcome) :-
    catch(client_connect(TransportSpec,
                         ClientInfo,
                         ClientCaps,
                         Options,
                         Outcome),
          Exception,
          runtime_exception(connect, Exception, Outcome)).

client_connect(TransportSpec, ClientInfo, ClientCaps, Options, Outcome) :-
    mcp_transport_open(TransportSpec, Options, TransportOutcome),
    (   TransportOutcome = ok(Transport)
    ->  mcp_transport_kind(Transport, Kind),
        mcp_2025_client_state_new(ClientInfo,
                                  ClientCaps,
                                  Kind,
                                  StateOutcome),
        client_connect_state(StateOutcome,
                             Transport,
                             Options,
                             Outcome)
    ;   TransportOutcome = error(Error),
        Outcome = error(Error)
    ).

client_connect_state(error(Error), Transport, _, error(Error)) :-
    !,
    mcp_transport_close(Transport, _).
client_connect_state(ok(State0), Transport, Options, Outcome) :-
    trace_empty(Trace0),
    trace_emit(connected,
               State0,
               _{transport:State0.transport},
               Trace0,
               Trace1),
    initialize_client(Transport,
                      State0,
                      1,
                      StateOutcome,
                      Trace1,
                      Trace2),
    (   StateOutcome = ok(State)
    ->  option(protocol('2025-11-25'), Options, '2025-11-25'),
        Client = mcp_client{transport:Transport,
                            adapter_state:State,
                            next_id:2,
                            trace:Trace2},
        Outcome = ok(Client)
    ;   StateOutcome = error(Error),
        mcp_transport_close(Transport, _),
        Outcome = error(Error)
    ).

initialize_client(Transport, State0, Id, Outcome, Trace0, Trace) :-
    mcp_2025_client_initialize(State0, Id, Wire, Meta, EncodeOutcome),
    (   EncodeOutcome = ok
    ->  trace_emit(initialize_sent,
                   State0,
                   _{request_id:Id},
                   Trace0,
                   Trace1),
        mcp_transport_exchange(Transport, Wire, Meta, ExchangeOutcome),
        accept_initialize_exchange(ExchangeOutcome,
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

accept_initialize_exchange(error(Error), _, _, _, error(Error), Trace, Trace) :-
    !.
accept_initialize_exchange(ok(Response), Transport, State0, Id,
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
        send_initialized(NotificationOutcome,
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

send_initialized(error(Error), _, _, _, _, error(Error), Trace, Trace) :-
    !.
send_initialized(ok(StateMaybe), Transport, State0, Wire, Meta,
                 Outcome, Trace0, Trace) :-
    mcp_transport_send(Transport, Wire, Meta, SendOutcome),
    (   SendOutcome = ok(sent)
    ->  normalize_ready_state(StateMaybe, State0, State),
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

normalize_ready_state(StateMaybe, _, StateMaybe) :-
    is_dict(StateMaybe, mcp_2025_client),
    StateMaybe.phase == ready,
    !.
normalize_ready_state(_, State0, State) :-
    put_dict(phase, State0, ready, State).

mcp_client_command(Client0, Command0, Client, Outcome) :-
    catch(client_command(Client0, Command0, Client, Outcome),
          Exception,
          runtime_exception(command, Exception, Outcome)).

client_command(Client0, Command0, Client, Outcome) :-
    require_client(Client0),
    mcp_command_normalize(Command0, CommandOutcome),
    (   CommandOutcome = ok(Command)
    ->  command_once(Client0,
                     Command,
                     true,
                     Client,
                     Outcome)
    ;   CommandOutcome = error(Error),
        Client = Client0,
        Outcome = error(Error)
    ).

command_once(Client0, Command, AllowRecovery, Client, Outcome) :-
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
        command_exchange(ExchangeOutcome,
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

command_exchange(error(Error), Client0, _, _, _, _, Client0, error(Error)) :-
    !.
command_exchange(ok(Response), Client0, Command, Id, AllowRecovery, Trace0,
                 Client, Outcome) :-
    (   Response.status =:= 404,
        AllowRecovery == true
    ->  recover_and_retry(Client0,
                          Command,
                          Id,
                          Trace0,
                          Client,
                          Outcome)
    ;   mcp_2025_client_decode(Client0.adapter_state,
                               Command,
                               Response,
                               DecodeOutcome),
        finish_command(DecodeOutcome,
                       Client0,
                       Command,
                       Id,
                       Trace0,
                       Client,
                       Outcome)
    ).

finish_command(error(Error), Client0, _, _, _, Client0, error(Error)) :- !.
finish_command(ok(Result), Client0, Command, Id, Trace0, Client, ok(Result)) :-
    NextId is Id+1,
    trace_emit(command_completed,
               Client0.adapter_state,
               _{request_id:Id, operation:Command.op},
               Trace0,
               Trace),
    put_dict(_{next_id:NextId, trace:Trace}, Client0, Client).

recover_and_retry(Client0, Command, FailedId, Trace0, Client, Outcome) :-
    mcp_2025_client_recover_404(Client0.adapter_state, RecoveryOutcome),
    (   RecoveryOutcome = ok(ResetState)
    ->  trace_emit(session_invalidated,
                   ResetState,
                   _{failed_request_id:FailedId},
                   Trace0,
                   Trace1),
        InitId is FailedId+1,
        initialize_client(Client0.transport,
                          ResetState,
                          InitId,
                          InitOutcome,
                          Trace1,
                          Trace2),
        retry_after_reinitialize(InitOutcome,
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

retry_after_reinitialize(error(Error), Client0, _, _, _, Client0, error(Error)) :-
    !.
retry_after_reinitialize(ok(State), Client0, Command, InitId, Trace,
                         Client, Outcome) :-
    CommandId is InitId+1,
    Temp = Client0.put(_{adapter_state:State,
                         next_id:CommandId,
                         trace:Trace}),
    command_once(Temp, Command, false, Client, Outcome).

mcp_client_close(Client, Outcome) :-
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
 * Server
 * ---------------------------------------------------------------------- */

mcp_server_new(TransportKind, ServerInfo, ServerCaps, Options, Outcome) :-
    option(session_id(SessionId), Options, null),
    mcp_2025_server_state_new(ServerInfo,
                              ServerCaps,
                              TransportKind,
                              SessionId,
                              StateOutcome),
    (   StateOutcome = ok(State)
    ->  trace_empty(Trace0),
        trace_emit(server_created,
                   State,
                   _{transport:TransportKind},
                   Trace0,
                   Trace),
        Outcome = ok(mcp_server{adapter_state:State, trace:Trace})
    ;   Outcome = StateOutcome
    ).

mcp_server_handle(Server0, Wire, RequestMeta, Dispatch, Server, Outcome) :-
    catch(server_handle(Server0,
                        Wire,
                        RequestMeta,
                        Dispatch,
                        Server,
                        Outcome),
          Exception,
          runtime_exception(server, Exception, Outcome)).

server_handle(Server0, Wire, RequestMeta, Dispatch, Server, Outcome) :-
    require_server(Server0),
    callable(Dispatch),
    mcp_2025_server_receive(Server0.adapter_state,
                            Wire,
                            RequestMeta,
                            Event,
                            ReceiveOutcome),
    handle_server_receive(ReceiveOutcome,
                          Event,
                          Server0,
                          Dispatch,
                          Server,
                          Outcome).

handle_server_receive(error(Error), _, Server, _, Server, Outcome) :-
    !,
    server_error_outcome(Error, Outcome).
handle_server_receive(ok(State), Event, Server0, Dispatch, Server, Outcome) :-
    server_event(Event,
                 State,
                 Server0,
                 Dispatch,
                 Server,
                 Outcome).

server_event(initialize(Id, _, _), State, Server0, _, Server, Outcome) :-
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
server_event(initialized, State, Server0, _, Server,
             ok(mcp_server_no_reply{})) :-
    !,
    trace_emit(server_ready,
               State,
               _{protocol_version:'2025-11-25'},
               Server0.trace,
               Trace),
    put_dict(_{adapter_state:State, trace:Trace}, Server0, Server).
server_event(command(Id, Command), State, Server0, Dispatch, Server, Outcome) :-
    call_dispatch(Dispatch, Command, DispatchOutcome),
    (   DispatchOutcome = ok(CanonicalResult)
    ->  mcp_2025_server_command_response(State,
                                         Id,
                                         Command,
                                         CanonicalResult,
                                         Wire,
                                         EncodeOutcome),
        finish_server_command(EncodeOutcome,
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

finish_server_command(error(Error), _, _, _, _, Server, Server, error(Error)) :-
    !.
finish_server_command(ok, Id, Command, Wire, State, Server0, Server,
                      ok(mcp_server_reply{wire:Wire,
                                          meta:mcp_transport_response_meta{headers:[]},
                                          status:200})) :-
    trace_emit(server_command_completed,
               State,
               _{request_id:Id, operation:Command.op},
               Server0.trace,
               Trace),
    put_dict(_{adapter_state:State, trace:Trace}, Server0, Server).

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

dispatch_exception(Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = mcp_error{phase:server_dispatch,
                      kind:dispatch_exception,
                      exception:Safe,
                      message:"MCP server dispatch raised an exception"}.

server_error_outcome(Error, Outcome) :-
    (   is_dict(Error),
        get_dict(detail, Error, invalid_session)
    ->  Outcome = error(mcp_server_transport_error{status:404,
                                                   cause:Error,
                                                   message:"MCP session is invalid"})
    ;   Outcome = error(Error)
    ).

mcp_server_trace(Server, Events) :-
    require_server(Server),
    Events = Server.trace.

/* -------------------------------------------------------------------------
 * Trace and validation
 * ---------------------------------------------------------------------- */

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
    ( get_dict(protocol_version, State, Value), Value \== null
    -> Protocol = Value
    ; Protocol = '2025-11-25'
    ).

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
