:- module(rlm_mcp_server,
          [ mcp_server/2,
            mcp_server_definition/2,
            mcp_server_definitions/1,
            rlm_install_mcp_server/2,
            rlm_install_mcp_server/3,
            rlm_install_mcp_server_async/2,
            rlm_install_mcp_server_async/3,
            rlm_run_mcp_server/2,
            rlm_run_mcp_server/3,
            rlm_run_mcp_server_async/2,
            rlm_run_mcp_server_async/3,
            rlm_stop_mcp_server/2,
            rlm_stop_mcp_server_async/2,
            rlm_restart_mcp_server/2,
            rlm_restart_mcp_server/3,
            rlm_restart_mcp_server_async/2,
            rlm_restart_mcp_server_async/3,
            rlm_connect_mcp_server/5,
            rlm_connect_mcp_server_async/5
          ]).

/** <module> Declarative MCP server definitions and explicit lifecycle

MCP server declarations are ordinary trusted Prolog data. Declaring or loading
a server never installs it, starts it, connects to it, imports its tools, or
grants capabilities. Every latency-bearing lifecycle operation follows the
canonical async-first contract: the async API submits one execute predicate and
the sync API starts the same Future and awaits it.

External packages may contribute declarations with multifile clauses such as:

  :- multifile rlm_mcp_server:mcp_server/2.

  rlm_mcp_server:mcp_server(filesystem,
      mcp_server_spec{
          transport:stdio(npx, ['-y', '@modelcontextprotocol/server-filesystem']),
          install:none,
          version:external,
          capabilities:[tools]
      }).

Install recipes use direct executable argv only; this module never invokes a
shell. Secrets belong in ambient environment/configuration references, not in
server facts.
*/

:- use_module(library(process)).
:- use_module(rlm_async, []).
:- use_module(rlm_mcp, []).
:- use_module(rlm_mcp_transport, []).

:- multifile mcp_server/2.
:- dynamic mcp_server/2.

/* -------------------------------------------------------------------------
 * Declarative definitions
 * ---------------------------------------------------------------------- */

mcp_server_definition(Name, Outcome) :-
    catch(mcp_server_definition_(Name, Outcome),
          Exception,
          lifecycle_exception(definition, Name, Exception, Outcome)).

mcp_server_definition_(Name, Outcome) :-
    require_server_name(Name),
    (   mcp_server(Name, Spec0)
    ->  normalize_server_spec(Name, Spec0, Spec),
        Outcome = ok(Spec)
    ;   Outcome = error(mcp_lifecycle_error{
                            phase:definition,
                            kind:unknown_server,
                            server:Name,
                            message:"MCP server is not declared"
                        })
    ).

mcp_server_definitions(Definitions) :-
    findall(Name-Spec,
            ( mcp_server(Name, Spec0),
              catch(normalize_server_spec(Name, Spec0, Spec), _, fail)
            ),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Definitions).

pairs_values([], []).
pairs_values([_-Value|Pairs], [Value|Values]) :-
    pairs_values(Pairs, Values).

normalize_server_spec(Name, Spec0, Spec) :-
    (   is_dict(Spec0)
    ->  true
    ;   throw(mcp_lifecycle_fault(invalid_server_spec(Spec0)))
    ),
    (   get_dict(transport, Spec0, Transport)
    ->  validate_owned_transport(Transport)
    ;   throw(mcp_lifecycle_fault(missing_transport))
    ),
    (   get_dict(install, Spec0, Install0)
    ->  validate_install_recipe(Install0), Install = Install0
    ;   Install = none
    ),
    put_dict(_{name:Name, install:Install}, Spec0, Spec).

validate_owned_transport(stdio(Executable, Args)) :-
    !,
    require_executable(Executable),
    require_argv(Args).
validate_owned_transport(streamable_http(Endpoint)) :-
    !,
    text_value(Endpoint).
validate_owned_transport(fixture(Kind, Handler)) :-
    !,
    memberchk(Kind, [stdio, streamable_http]),
    callable(Handler),
    ground(Handler).
validate_owned_transport(Transport) :-
    throw(mcp_lifecycle_fault(unsupported_transport(Transport))).

validate_install_recipe(none) :- !.
validate_install_recipe(process(Executable, Args)) :-
    !,
    require_executable(Executable),
    require_argv(Args).
validate_install_recipe(Recipe) :-
    throw(mcp_lifecycle_fault(unsupported_install_recipe(Recipe))).

require_server_name(Name) :-
    atom(Name),
    Name \== '',
    !.
require_server_name(Name) :-
    throw(mcp_lifecycle_fault(invalid_server_name(Name))).

require_executable(Executable) :-
    atom(Executable),
    Executable \== '',
    !.
require_executable(Executable) :-
    throw(mcp_lifecycle_fault(invalid_executable(Executable))).

require_argv(Args) :-
    is_list(Args),
    maplist(atomic, Args),
    !.
require_argv(Args) :-
    throw(mcp_lifecycle_fault(invalid_argv(Args))).

text_value(Value) :- string(Value), !.
text_value(Value) :- atom(Value), Value \== '', !.
text_value(Value) :-
    throw(mcp_lifecycle_fault(invalid_endpoint(Value))).

/* -------------------------------------------------------------------------
 * Installation
 * ---------------------------------------------------------------------- */

rlm_install_mcp_server(Server, Outcome) :-
    rlm_install_mcp_server(Server, [], Outcome).

rlm_install_mcp_server(Server, Options, Outcome) :-
    rlm_install_mcp_server_async(Server, Options, Future),
    await_owned_future(Future, Outcome).

rlm_install_mcp_server_async(Server, Future) :-
    rlm_install_mcp_server_async(Server, [], Future).

rlm_install_mcp_server_async(Server, Options, Future) :-
    lifecycle_metadata(mcp_install, Server, Options, Metadata),
    rlm_async:rlm_async_submit(
        rlm_mcp_server:rlm_install_mcp_server_execute(Server, Options),
        Metadata,
        Future).

rlm_install_mcp_server_execute(Server, _, Outcome) :-
    mcp_server_definition(Server, DefinitionOutcome),
    install_after_definition(DefinitionOutcome, Server, Outcome).

install_after_definition(error(Error), _, error(Error)) :- !.
install_after_definition(ok(Spec), Server, Outcome) :-
    install_recipe(Spec.install, Server, Outcome).

install_recipe(none, Server,
               ok(mcp_install{server:Server, status:not_required})) :- !.
install_recipe(process(Executable, Args), Server, Outcome) :-
    catch(run_install_process(Executable, Args, Status),
          Exception,
          lifecycle_exception(install, Server, Exception, Outcome)),
    (   var(Outcome)
    ->  install_status(Status, Server, Outcome)
    ;   true
    ).

run_install_process(Executable, Args, Status) :-
    process_create(path(Executable), Args, [process(Pid)]),
    setup_call_cleanup(
        true,
        process_wait(Pid, Status),
        ensure_process_stopped(Pid)).

ensure_process_stopped(Pid) :-
    catch(process_kill(Pid, term), _, true),
    catch(process_wait(Pid, _), _, true).

install_status(exit(0), Server,
               ok(mcp_install{server:Server, status:installed})) :- !.
install_status(Status, Server,
               error(mcp_lifecycle_error{
                         phase:install,
                         kind:installer_failed,
                         server:Server,
                         process_status:Status,
                         message:"MCP server installer exited unsuccessfully"
                     })).

/* -------------------------------------------------------------------------
 * Process/transport lifecycle
 * ---------------------------------------------------------------------- */

rlm_run_mcp_server(Server, Outcome) :-
    rlm_run_mcp_server(Server, [], Outcome).

rlm_run_mcp_server(Server, Options, Outcome) :-
    rlm_run_mcp_server_async(Server, Options, Future),
    await_owned_future(Future, Outcome).

rlm_run_mcp_server_async(Server, Future) :-
    rlm_run_mcp_server_async(Server, [], Future).

rlm_run_mcp_server_async(Server, Options, Future) :-
    lifecycle_metadata(mcp_run, Server, Options, Metadata),
    rlm_async:rlm_async_submit(
        rlm_mcp_server:rlm_run_mcp_server_execute(Server, Options),
        Metadata,
        Future).

rlm_run_mcp_server_execute(Server, Options, Outcome) :-
    mcp_server_definition(Server, DefinitionOutcome),
    run_after_definition(DefinitionOutcome, Server, Options, Outcome).

run_after_definition(error(Error), _, _, error(Error)) :- !.
run_after_definition(ok(Spec), Server, Options, Outcome) :-
    merge_runtime_options(Spec, Options, RuntimeOptions),
    rlm_mcp_transport:mcp_transport_open(Spec.transport,
                                         RuntimeOptions,
                                         TransportOutcome),
    run_after_transport(TransportOutcome,
                        Server,
                        Spec.transport,
                        RuntimeOptions,
                        Outcome).

run_after_transport(error(Error), _, _, _, error(Error)) :- !.
run_after_transport(ok(Transport), Server, TransportSpec, Options,
                    ok(mcp_runtime_handle{
                           server:Server,
                           status:running,
                           transport:Transport,
                           transport_spec:TransportSpec,
                           options:Options
                       })).

rlm_stop_mcp_server(Handle, Outcome) :-
    rlm_stop_mcp_server_async(Handle, Future),
    await_owned_future(Future, Outcome).

rlm_stop_mcp_server_async(Handle, Future) :-
    lifecycle_handle_subject(Handle, Server),
    lifecycle_metadata(mcp_stop, Server, [], Metadata),
    rlm_async:rlm_async_submit(
        rlm_mcp_server:rlm_stop_mcp_server_execute(Handle),
        Metadata,
        Future).

rlm_stop_mcp_server_execute(Handle0, Outcome) :-
    catch(require_running_handle(Handle0),
          Exception,
          lifecycle_exception(stop, unknown, Exception, Outcome)),
    (   var(Outcome)
    ->  rlm_mcp_transport:mcp_transport_stop(Handle0.transport,
                                             StopOutcome),
        stop_after_transport(StopOutcome, Handle0, Outcome)
    ;   true
    ).

stop_after_transport(error(Error), _, error(Error)) :- !.
stop_after_transport(ok(_), Handle0, ok(Handle)) :-
    put_dict(status, Handle0, stopped, Handle).

rlm_restart_mcp_server(Handle, Outcome) :-
    rlm_restart_mcp_server(Handle, [], Outcome).

rlm_restart_mcp_server(Handle, Options, Outcome) :-
    rlm_restart_mcp_server_async(Handle, Options, Future),
    await_owned_future(Future, Outcome).

rlm_restart_mcp_server_async(Handle, Future) :-
    rlm_restart_mcp_server_async(Handle, [], Future).

rlm_restart_mcp_server_async(Handle, Options, Future) :-
    lifecycle_handle_subject(Handle, Server),
    lifecycle_metadata(mcp_restart, Server, Options, Metadata),
    rlm_async:rlm_async_submit(
        rlm_mcp_server:rlm_restart_mcp_server_execute(Handle, Options),
        Metadata,
        Future).

rlm_restart_mcp_server_execute(Handle, Options, Outcome) :-
    rlm_stop_mcp_server_execute(Handle, StopOutcome),
    restart_after_stop(StopOutcome, Handle, Options, Outcome).

restart_after_stop(error(Error), _, _, error(Error)) :- !.
restart_after_stop(ok(_), Handle, Options, Outcome) :-
    rlm_run_mcp_server_execute(Handle.server, Options, Outcome).

require_running_handle(Handle) :-
    is_dict(Handle, mcp_runtime_handle),
    Handle.status == running,
    !.
require_running_handle(Handle) :-
    throw(mcp_lifecycle_fault(invalid_or_stopped_handle(Handle))).

/* -------------------------------------------------------------------------
 * Connection to an explicitly running server
 * ---------------------------------------------------------------------- */

rlm_connect_mcp_server(Handle, ClientInfo, ClientCaps, Options, Outcome) :-
    rlm_connect_mcp_server_async(Handle,
                                 ClientInfo,
                                 ClientCaps,
                                 Options,
                                 Future),
    await_owned_future(Future, Outcome).

rlm_connect_mcp_server_async(Handle, ClientInfo, ClientCaps, Options, Future) :-
    lifecycle_handle_subject(Handle, Server),
    lifecycle_metadata(mcp_connect_server, Server, Options, Metadata),
    rlm_async:rlm_async_submit(
        rlm_mcp_server:rlm_connect_mcp_server_execute(Handle,
                                                      ClientInfo,
                                                      ClientCaps,
                                                      Options),
        Metadata,
        Future).

rlm_connect_mcp_server_execute(Handle, ClientInfo, ClientCaps, Options,
                               Outcome) :-
    catch(require_running_handle(Handle),
          Exception,
          lifecycle_exception(connect, unknown, Exception, Outcome)),
    (   var(Outcome)
    ->  rlm_mcp:mcp_client_connect_execute(existing(Handle.transport),
                                            ClientInfo,
                                            ClientCaps,
                                            Options,
                                            Outcome)
    ;   true
    ).

/* -------------------------------------------------------------------------
 * Options, metadata, errors
 * ---------------------------------------------------------------------- */

merge_runtime_options(Spec, Options, RuntimeOptions) :-
    (   get_dict(options, Spec, SpecOptions), is_list(SpecOptions)
    ->  true
    ;   SpecOptions = []
    ),
    (   is_list(Options)
    ->  append(Options, SpecOptions, RuntimeOptions)
    ;   throw(mcp_lifecycle_fault(invalid_options(Options)))
    ).

lifecycle_metadata(Operation, Server0, Options, Metadata) :-
    metadata_ground(Server0, unknown, Server),
    metadata_option(trace_id, Options, none, TraceId),
    metadata_option(session_id, Options, none, SessionId),
    Metadata = async_metadata{
                   operation:Operation,
                   mcp_server:Server,
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

metadata_ground(Value, _, Value) :- ground(Value), !.
metadata_ground(_, Default, Default).

lifecycle_handle_subject(Handle, Server) :-
    is_dict(Handle, mcp_runtime_handle),
    get_dict(server, Handle, Found),
    ground(Found),
    !,
    Server = Found.
lifecycle_handle_subject(_, unknown).

await_owned_future(Future, Outcome) :-
    setup_call_cleanup(
        true,
        rlm_async:rlm_future_await(Future, Outcome),
        rlm_async:rlm_future_destroy(Future)).

lifecycle_exception(_, _, Exception, _) :-
    lifecycle_control_exception(Exception),
    !,
    throw(Exception).
lifecycle_exception(Phase, Server, mcp_lifecycle_fault(Detail), error(Error)) :-
    !,
    Error = mcp_lifecycle_error{
                phase:Phase,
                kind:invalid_lifecycle_operation,
                server:Server,
                detail:Detail,
                message:"MCP lifecycle operation is invalid"
            }.
lifecycle_exception(Phase, Server, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = mcp_lifecycle_error{
                phase:Phase,
                kind:lifecycle_exception,
                server:Server,
                exception:Safe,
                message:"MCP lifecycle operation raised an exception"
            }.

lifecycle_control_exception(rlm_async_cancelled(_)).
lifecycle_control_exception(rlm_cancelled(_)).
lifecycle_control_exception(chain_cancelled(_)).
lifecycle_control_exception(graph_cancelled(_)).
lifecycle_control_exception(cancelled(_)).
lifecycle_control_exception('$aborted').
lifecycle_control_exception(abort).
