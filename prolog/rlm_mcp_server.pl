:- module(rlm_mcp_server,
          [ mcp_server_definition/2,
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

/** <module> Declarative MCP server lifecycle

Server declarations are passive data until explicit install/run calls. Loading
this module or a tool category never installs or starts an MCP server.

Latency-bearing lifecycle operations preserve the canonical async direction:
the async surface submits one execute predicate; the synchronous surface starts
that same operation and waits on its Future. Side effects that actually cross a
host boundary are mediated by `rlm_authority` after declaration/recipe/transport
validation. Human approval returns a pending operation immediately and never
parks an `rlm_async` worker.

`fixture/2` and `streamable_http/1` opens are non-mutating handle construction;
`stdio/2` starts a process and is classified `service_start`. Only an owned
stdio transport stop is `service_stop`. Installation recipes using `process/3`
are `install`. The declarations remain data and authority never makes an invalid
recipe or transport spec valid.
*/

:- use_module(library(option)).
:- use_module(library(process)).
:- use_module(rlm_async, []).
:- use_module(rlm_authority, []).
:- use_module(rlm_mcp, []).
:- use_module(rlm_mcp_transport, []).

:- multifile mcp_server/2.

/* -------------------------------------------------------------------------
 * Passive declaration discovery
 * ---------------------------------------------------------------------- */

mcp_server_definition(Name, Outcome) :-
    catch(mcp_server_definition_(Name, Outcome),
          Exception,
          lifecycle_exception(definition, Name, Exception, Outcome)).

mcp_server_definition_(Name, Outcome) :-
    require_server_name(Name),
    findall(Spec0, mcp_server(Name, Spec0), Specs),
    definition_result(Name, Specs, Outcome).

definition_result(Name, [],
                  error(mcp_lifecycle_error{
                            phase:definition,
                            kind:unknown_server,
                            server:Name,
                            message:"MCP server is not declared"
                        })) :- !.
definition_result(Name, [_|[_|_]],
                  error(mcp_lifecycle_error{
                            phase:definition,
                            kind:duplicate_server_definition,
                            server:Name,
                            message:"MCP server has multiple declarations"
                        })) :- !.
definition_result(Name, [Spec0], Outcome) :-
    catch(( normalize_server_spec(Name, Spec0, Spec), Outcome = ok(Spec) ),
          Exception,
          lifecycle_exception(definition, Name, Exception, Outcome)).

mcp_server_definitions(Definitions) :-
    findall(Name, mcp_server(Name, _), Names0),
    sort(Names0, Names),
    findall(Spec,
            ( member(Name, Names),
              mcp_server_definition(Name, ok(Spec)) ),
            Definitions).

normalize_server_spec(Name, Spec0, Spec) :-
    is_dict(Spec0),
    !,
    require_spec_key(Spec0, transport, Transport),
    normalize_transport_spec(Transport, NormalizedTransport),
    dict_value_default(install, Spec0, none, Install0),
    normalize_install_recipe(Install0, Install),
    dict_value_default(version, Spec0, unspecified, Version),
    dict_value_default(capabilities, Spec0, [], Capabilities),
    dict_value_default(options, Spec0, [], Options),
    require_ground(Version, version),
    require_capability_list(Capabilities),
    require_options(Options),
    Spec = mcp_server_spec{name:Name,
                           transport:NormalizedTransport,
                           install:Install,
                           version:Version,
                           capabilities:Capabilities,
                           options:Options}.
normalize_server_spec(_, Spec, _) :-
    throw(mcp_lifecycle_fault(invalid_server_spec(Spec))).

normalize_transport_spec(existing(Transport), existing(Transport)) :-
    !,
    require_ground(Transport, transport).
normalize_transport_spec(fixture(Kind, Handler), fixture(Kind, Handler)) :-
    !,
    memberchk(Kind, [stdio,streamable_http]),
    callable(Handler),
    ground(Handler).
normalize_transport_spec(stdio(Executable, Args), stdio(Executable, Args)) :-
    !,
    atom(Executable),
    Executable \== '',
    is_list(Args),
    ground(Args),
    maplist(valid_process_arg, Args).
normalize_transport_spec(streamable_http(Endpoint), streamable_http(Endpoint)) :-
    !,
    text_value(Endpoint),
    Endpoint \== ''.
normalize_transport_spec(Transport, _) :-
    throw(mcp_lifecycle_fault(invalid_transport_spec(Transport))).

normalize_install_recipe(none, none) :- !.
normalize_install_recipe(process(Executable, Args, Options),
                         process(Executable, Args, Options)) :-
    !,
    atom(Executable),
    Executable \== '',
    is_list(Args),
    ground(Args),
    maplist(valid_process_arg, Args),
    validate_install_options(Options).
normalize_install_recipe(Recipe, _) :-
    throw(mcp_lifecycle_fault(invalid_install_recipe(Recipe))).

valid_process_arg(Arg) :- atomic(Arg), !.
valid_process_arg(Arg) :-
    throw(mcp_lifecycle_fault(invalid_process_argument(Arg))).

validate_install_options(Options) :-
    is_list(Options),
    ground(Options),
    forall(member(Option, Options), valid_install_option(Option)),
    !.
validate_install_options(Options) :-
    throw(mcp_lifecycle_fault(invalid_install_options(Options))).

valid_install_option(cwd(Directory)) :- atom(Directory), !.
valid_install_option(env(Env)) :- is_list(Env), ground(Env), !.
valid_install_option(Option) :-
    throw(mcp_lifecycle_fault(disallowed_install_option(Option))).

/* -------------------------------------------------------------------------
 * Explicit install
 * ---------------------------------------------------------------------- */

rlm_install_mcp_server_async(Name, Future) :-
    rlm_install_mcp_server_async(Name, [], Future).

rlm_install_mcp_server_async(Name, Options, Future) :-
    lifecycle_metadata(mcp_install, Name, Options, Metadata),
    rlm_async:rlm_async_submit(
        rlm_mcp_server:rlm_install_mcp_server_execute(Name, Options),
        Metadata,
        Future).

rlm_install_mcp_server(Name, Outcome) :-
    rlm_install_mcp_server_async(Name, Future),
    await_owned_future(Future, Outcome).

rlm_install_mcp_server(Name, Options, Outcome) :-
    rlm_install_mcp_server_async(Name, Options, Future),
    await_owned_future(Future, Outcome).

rlm_install_mcp_server_execute(Name, Options, Outcome) :-
    catch(rlm_install_mcp_server_(Name, Options, Outcome),
          Exception,
          lifecycle_exception(install, Name, Exception, Outcome)).

rlm_install_mcp_server_(Name, Options, Outcome) :-
    mcp_server_definition(Name, DefinitionOutcome),
    install_after_definition(DefinitionOutcome, Name, Options, Outcome).

install_after_definition(error(Error), _, _, error(Error)) :- !.
install_after_definition(ok(Spec), Name, Options, Outcome) :-
    install_recipe_effect(Spec.install, Name, Options, Outcome).

install_recipe_effect(none, Name, _,
                      ok(mcp_install_result{server:Name,
                                            status:not_required})) :- !.
install_recipe_effect(Recipe, Name, Options, Outcome) :-
    Recipe = process(Executable, Args, InstallOptions),
    authority_context(Name, Options, Context),
    bounded_install_details(Executable, Args, InstallOptions, Details),
    Operation = authority_operation{name:mcp_install,
                                    effect:install,
                                    capability:mcp(Name),
                                    args:mcp_install_args{server:Name,
                                                          executable:Executable,
                                                          argv:Args},
                                    details:Details},
    Continuation = rlm_mcp_server:install_process_effect(
                       Name, Executable, Args, InstallOptions),
    lifecycle_authorize(Context, Operation, Continuation, install, Name,
                        Outcome).

bounded_install_details(Executable, Args, InstallOptions,
                        mcp_install_details{executable:Executable,
                                            argv:Args,
                                            cwd:Cwd,
                                            env_reference:EnvReference}) :-
    ( memberchk(cwd(Cwd0), InstallOptions) -> Cwd = Cwd0 ; Cwd = none ),
    ( memberchk(env(_), InstallOptions) -> EnvReference = supplied ; EnvReference = none ).

install_process_effect(Name, Executable, Args, InstallOptions, Outcome) :-
    process_create(path(Executable),
                   Args,
                   [process(Pid)|InstallOptions]),
    process_wait(Pid, Status),
    (   Status == exit(0)
    ->  Outcome = ok(mcp_install_result{server:Name,
                                        status:installed,
                                        process_status:Status})
    ;   Outcome = error(mcp_lifecycle_error{
                            phase:install,
                            kind:installer_failed,
                            server:Name,
                            process_status:Status,
                            message:"MCP installer exited unsuccessfully"
                        })
    ).

/* -------------------------------------------------------------------------
 * Explicit run / stop / restart
 * ---------------------------------------------------------------------- */

rlm_run_mcp_server_async(Name, Future) :-
    rlm_run_mcp_server_async(Name, [], Future).

rlm_run_mcp_server_async(Name, Options, Future) :-
    lifecycle_metadata(mcp_run, Name, Options, Metadata),
    rlm_async:rlm_async_submit(
        rlm_mcp_server:rlm_run_mcp_server_execute(Name, Options),
        Metadata,
        Future).

rlm_run_mcp_server(Name, Outcome) :-
    rlm_run_mcp_server_async(Name, Future),
    await_owned_future(Future, Outcome).

rlm_run_mcp_server(Name, Options, Outcome) :-
    rlm_run_mcp_server_async(Name, Options, Future),
    await_owned_future(Future, Outcome).

rlm_run_mcp_server_execute(Name, Options, Outcome) :-
    catch(rlm_run_mcp_server_(Name, Options, Outcome),
          Exception,
          lifecycle_exception(run, Name, Exception, Outcome)).

rlm_run_mcp_server_(Name, Options, Outcome) :-
    mcp_server_definition(Name, DefinitionOutcome),
    run_after_definition(DefinitionOutcome, Name, Options, Outcome).

run_after_definition(error(Error), _, _, error(Error)) :- !.
run_after_definition(ok(Spec), Name, Options, Outcome) :-
    merge_runtime_options(Spec, Options, RuntimeOptions0),
    normalize_runtime_options(RuntimeOptions0, RuntimeOptions),
    authority_context(Name, Options, Context),
    transport_authority(Spec.transport, Effect, Details),
    Operation = authority_operation{name:mcp_run,
                                    effect:Effect,
                                    capability:mcp(Name),
                                    args:mcp_run_args{server:Name},
                                    details:Details},
    Continuation = rlm_mcp_server:run_transport_effect(
                       Name, Spec, RuntimeOptions, Context),
    lifecycle_authorize(Context, Operation, Continuation, run, Name, Outcome).

run_transport_effect(Name, Spec, RuntimeOptions, Context, Outcome) :-
    rlm_mcp_transport:mcp_transport_open(Spec.transport,
                                         RuntimeOptions,
                                         TransportOutcome),
    run_after_transport(TransportOutcome, Name, Spec, Context, Outcome).

run_after_transport(error(Error), _, _, _, error(Error)) :- !.
run_after_transport(ok(Transport), Name, Spec, Context,
                    ok(mcp_runtime_handle{server:Name,
                                          spec:Spec,
                                          transport:Transport,
                                          authority_context:Context,
                                          status:running})) :- !.

rlm_stop_mcp_server_async(Handle, Future) :-
    lifecycle_handle_subject(Handle, Server),
    lifecycle_handle_context(Handle, Context),
    Metadata = async_metadata{operation:mcp_stop,
                              mcp_server:Server,
                              authority_context:Context,
                              trace_id:none,
                              session_id:none},
    rlm_async:rlm_async_submit(
        rlm_mcp_server:rlm_stop_mcp_server_execute(Handle),
        Metadata,
        Future).

rlm_stop_mcp_server(Handle, Outcome) :-
    rlm_stop_mcp_server_async(Handle, Future),
    await_owned_future(Future, Outcome).

rlm_stop_mcp_server_execute(Handle, Outcome) :-
    lifecycle_handle_subject(Handle, Server),
    catch(rlm_stop_mcp_server_(Handle, Outcome),
          Exception,
          lifecycle_exception(stop, Server, Exception, Outcome)).

rlm_stop_mcp_server_(Handle, Outcome) :-
    require_running_handle(Handle, Server, Transport),
    lifecycle_handle_context(Handle, Context),
    stop_authority(Transport, Effect, Details),
    Operation = authority_operation{name:mcp_stop,
                                    effect:Effect,
                                    capability:mcp(Server),
                                    args:mcp_stop_args{server:Server},
                                    details:Details},
    Continuation = rlm_mcp_server:stop_transport_effect(Handle, Transport),
    lifecycle_authorize(Context, Operation, Continuation, stop, Server, Outcome).

stop_transport_effect(Handle, Transport, Outcome) :-
    rlm_mcp_transport:mcp_transport_stop(Transport, StopOutcome),
    stop_after_transport(StopOutcome, Handle, Outcome).

stop_after_transport(error(Error), _, error(Error)) :- !.
stop_after_transport(ok(_), Handle,
                     ok(Stopped)) :-
    put_dict(status, Handle, stopped, Stopped).

rlm_restart_mcp_server_async(Handle, Future) :-
    rlm_restart_mcp_server_async(Handle, [], Future).

rlm_restart_mcp_server_async(Handle, Options, Future) :-
    lifecycle_handle_subject(Handle, Server),
    lifecycle_metadata(mcp_restart, Server, Options, Metadata),
    rlm_async:rlm_async_submit(
        rlm_mcp_server:rlm_restart_mcp_server_execute(Handle, Options),
        Metadata,
        Future).

rlm_restart_mcp_server(Handle, Outcome) :-
    rlm_restart_mcp_server_async(Handle, Future),
    await_owned_future(Future, Outcome).

rlm_restart_mcp_server(Handle, Options, Outcome) :-
    rlm_restart_mcp_server_async(Handle, Options, Future),
    await_owned_future(Future, Outcome).

rlm_restart_mcp_server_execute(Handle, Options, Outcome) :-
    lifecycle_handle_subject(Handle, Server),
    catch(rlm_restart_mcp_server_(Handle, Options, Outcome),
          Exception,
          lifecycle_exception(restart, Server, Exception, Outcome)).

rlm_restart_mcp_server_(Handle, Options, Outcome) :-
    require_running_handle(Handle, Server, Transport),
    Spec = Handle.spec,
    merge_runtime_options(Spec, Options, RuntimeOptions0),
    normalize_runtime_options(RuntimeOptions0, RuntimeOptions),
    restart_context(Handle, Options, Context),
    restart_authority(Transport, Spec.transport, Effect, Details),
    Operation = authority_operation{name:mcp_restart,
                                    effect:Effect,
                                    capability:mcp(Server),
                                    args:mcp_restart_args{server:Server},
                                    details:Details},
    Continuation = rlm_mcp_server:restart_transport_effect(
                       Handle, Server, Spec, RuntimeOptions, Context),
    lifecycle_authorize(Context, Operation, Continuation, restart, Server,
                        Outcome).

restart_transport_effect(Handle, Server, Spec, RuntimeOptions, Context, Outcome) :-
    Transport = Handle.transport,
    rlm_mcp_transport:mcp_transport_stop(Transport, StopOutcome),
    restart_after_stop(StopOutcome, Server, Spec, RuntimeOptions, Context,
                       Outcome).

restart_after_stop(error(Error), _, _, _, _, error(Error)) :- !.
restart_after_stop(ok(_), Server, Spec, RuntimeOptions, Context, Outcome) :-
    run_transport_effect(Server, Spec, RuntimeOptions, Context, Outcome).

/* -------------------------------------------------------------------------
 * Connection against a running transport
 * ---------------------------------------------------------------------- */

rlm_connect_mcp_server_async(Handle, ClientInfo, ClientCapabilities,
                             Options, Future) :-
    lifecycle_handle_subject(Handle, Server),
    lifecycle_metadata(mcp_connect, Server, Options, Metadata),
    rlm_async:rlm_async_submit(
        rlm_mcp_server:rlm_connect_mcp_server_execute(
                           Handle, ClientInfo, ClientCapabilities, Options),
        Metadata,
        Future).

rlm_connect_mcp_server(Handle, ClientInfo, ClientCapabilities,
                       Options, Outcome) :-
    rlm_connect_mcp_server_async(Handle,
                                 ClientInfo,
                                 ClientCapabilities,
                                 Options,
                                 Future),
    await_owned_future(Future, Outcome).

rlm_connect_mcp_server_execute(Handle, ClientInfo, ClientCapabilities,
                               Options, Outcome) :-
    lifecycle_handle_subject(Handle, Server),
    catch(rlm_connect_mcp_server_(Handle,
                                  ClientInfo,
                                  ClientCapabilities,
                                  Options,
                                  Outcome),
          Exception,
          lifecycle_exception(connect, Server, Exception, Outcome)).

rlm_connect_mcp_server_(Handle, ClientInfo, ClientCapabilities,
                        Options, Outcome) :-
    require_running_handle(Handle, _, Transport),
    rlm_mcp:mcp_client_connect_execute(existing(Transport),
                                       ClientInfo,
                                       ClientCapabilities,
                                       Options,
                                       Result),
    (   is_dict(Result, mcp_connect_async_result)
    ->  Outcome = Result.outcome
    ;   Outcome = error(mcp_lifecycle_error{
                            phase:connect,
                            kind:invalid_async_result,
                            message:"canonical MCP connect execute ABI returned an invalid result"
                        })
    ).

/* -------------------------------------------------------------------------
 * Authority helpers
 * ---------------------------------------------------------------------- */

lifecycle_authorize(Context, Operation, Continuation, Phase, Server, Outcome) :-
    rlm_authority:rlm_authorize_operation(Context,
                                          Operation,
                                          Continuation,
                                          none,
                                          AuthorityOutcome),
    lifecycle_authority_result(AuthorityOutcome,
                               Context,
                               Continuation,
                               Phase,
                               Server,
                               Outcome).

lifecycle_authority_result(execute(Permit), Context, Continuation, _, _, Outcome) :-
    !,
    call_lifecycle_continuation(Permit, Context, Continuation, Outcome).
lifecycle_authority_result(approval_required(Pending), _, _, _, _,
                           approval_required(Pending)) :- !.
lifecycle_authority_result(replay(Outcome), _, _, _, _, Outcome) :- !.
lifecycle_authority_result(error(Error), _, _, Phase, Server,
                           error(mcp_lifecycle_error{
                                     phase:Phase,
                                     kind:authority_denied,
                                     server:Server,
                                     cause:Error,
                                     message:"host authority rejected MCP lifecycle operation"
                                 })).

call_lifecycle_continuation(Permit, Context, Continuation, Outcome) :-
    catch(call(Continuation, Outcome),
          Exception,
          ( complete_lifecycle_exception(Permit, Context, Exception),
            throw(Exception) )),
    complete_lifecycle_once(Permit, Context, Outcome).

complete_lifecycle_exception(Permit, Context, Exception) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    complete_lifecycle_once(Permit, Context,
                            error(mcp_lifecycle_execution_exception(Safe))).

complete_lifecycle_once(Permit, Context, Outcome) :-
    (   Permit.kind == allow_once
    ->  rlm_authority:rlm_authority_complete_once(Context,
                                                  Permit.fingerprint,
                                                  Outcome)
    ;   true
    ).

authority_context(Server, Options, Context) :-
    ( metadata_option(authority_context, Options, none, Explicit),
      Explicit \== none
    -> Context = Explicit
    ; metadata_option(session_id, Options, none, Session),
      Session \== none
    -> Context = session(Session)
    ; Context = mcp(Server)
    ).

restart_context(Handle, Options, Context) :-
    ( metadata_option(authority_context, Options, none, Explicit),
      Explicit \== none
    -> Context = Explicit
    ; lifecycle_handle_context(Handle, Context)
    ).

lifecycle_handle_context(Handle, Context) :-
    ( is_dict(Handle, mcp_runtime_handle),
      get_dict(authority_context, Handle, Found),
      ground(Found)
    -> Context = Found
    ; lifecycle_handle_subject(Handle, Server),
      Context = mcp(Server)
    ).

transport_authority(stdio(Executable, Args), service_start,
                    mcp_transport_details{kind:stdio,
                                          executable:Executable,
                                          argv:Args}) :- !.
transport_authority(fixture(Kind, _), read,
                    mcp_transport_details{kind:fixture,
                                          transport_kind:Kind}) :- !.
transport_authority(streamable_http(Endpoint), read,
                    mcp_transport_details{kind:streamable_http,
                                          endpoint:Endpoint}) :- !.
transport_authority(existing(_), read,
                    mcp_transport_details{kind:existing}) :- !.

stop_authority(Transport, service_stop,
               mcp_transport_details{kind:stdio}) :-
    is_dict(Transport, mcp_transport),
    get_dict(backend, Transport, stdio(_,_,_,_)),
    !.
stop_authority(_, read, mcp_transport_details{kind:non_owned_process}).

restart_authority(Transport, TransportSpec, service_start, Details) :-
    ( is_dict(Transport, mcp_transport),
      get_dict(backend, Transport, stdio(_,_,_,_))
    ; TransportSpec = stdio(_, _)
    ),
    !,
    transport_authority(TransportSpec, service_start, Details).
restart_authority(_, TransportSpec, read, Details) :-
    transport_authority(TransportSpec, _, Details).

/* -------------------------------------------------------------------------
 * Validation and options
 * ---------------------------------------------------------------------- */

require_running_handle(Handle, Server, Transport) :-
    is_dict(Handle, mcp_runtime_handle),
    get_dict(status, Handle, running),
    get_dict(server, Handle, Server),
    get_dict(transport, Handle, Transport),
    !.
require_running_handle(Handle, _, _) :-
    throw(mcp_lifecycle_fault(invalid_runtime_handle(Handle))).

require_server_name(Name) :-
    atom(Name),
    Name \== '',
    !.
require_server_name(Name) :-
    throw(mcp_lifecycle_fault(invalid_server_name(Name))).

require_spec_key(Spec, Key, Value) :-
    (   get_dict(Key, Spec, Value)
    ->  true
    ;   throw(mcp_lifecycle_fault(missing_server_field(Key)))
    ).

require_ground(Value, _) :- ground(Value), !.
require_ground(Value, Field) :-
    throw(mcp_lifecycle_fault(nonground_field(Field, Value))).

require_capability_list(Value) :-
    is_list(Value),
    ground(Value),
    !.
require_capability_list(Value) :-
    throw(mcp_lifecycle_fault(invalid_capabilities(Value))).

require_options(Value) :-
    is_list(Value),
    ground(Value),
    !.
require_options(Value) :-
    throw(mcp_lifecycle_fault(invalid_options(Value))).

merge_runtime_options(Spec, Options, RuntimeOptions) :-
    ( get_dict(options, Spec, SpecOptions), is_list(SpecOptions)
    -> true
    ; SpecOptions = [] ),
    ( is_list(Options)
    -> exclude(lifecycle_only_option, Options, RuntimeUserOptions),
       append(RuntimeUserOptions, SpecOptions, RuntimeOptions)
    ; throw(mcp_lifecycle_fault(invalid_options(Options))) ).

lifecycle_only_option(authority_context(_)).
lifecycle_only_option(session_id(_)).
lifecycle_only_option(trace_id(_)).

normalize_runtime_options(Options, Normalized) :-
    is_list(Options),
    ground(Options),
    forall(member(Option, Options), valid_runtime_option(Option)),
    !,
    Normalized = Options.
normalize_runtime_options(Options, _) :-
    throw(mcp_lifecycle_fault(invalid_runtime_options(Options))).

valid_runtime_option(timeout(Value)) :- number(Value), Value > 0, !.
valid_runtime_option(Option) :-
    throw(mcp_lifecycle_fault(disallowed_runtime_option(Option))).

text_value(Value) :- atom(Value), !.
text_value(Value) :- string(Value), !.

/* -------------------------------------------------------------------------
 * Metadata and errors
 * ---------------------------------------------------------------------- */

lifecycle_metadata(Operation, Server0, Options, Metadata) :-
    metadata_ground(Server0, unknown, Server),
    metadata_option(trace_id, Options, none, TraceId),
    metadata_option(session_id, Options, none, SessionId),
    authority_context(Server, Options, AuthorityContext),
    Metadata = async_metadata{operation:Operation,
                              mcp_server:Server,
                              trace_id:TraceId,
                              session_id:SessionId,
                              authority_context:AuthorityContext}.

metadata_option(Name, Options, Default, Value) :-
    ( is_list(Options),
      member(Option, Options),
      nonvar(Option),
      Option =.. [Name, Found],
      ground(Found)
    -> Value = Found
    ; Value = Default ).

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
    setup_call_cleanup(true,
                       rlm_async:rlm_future_await(Future, Outcome),
                       rlm_async:rlm_future_destroy(Future)).

lifecycle_exception(_, _, Exception, _) :-
    lifecycle_control_exception(Exception),
    !,
    throw(Exception).
lifecycle_exception(Phase, Server, mcp_lifecycle_fault(Detail), error(Error)) :-
    !,
    Error = mcp_lifecycle_error{phase:Phase,
                                kind:invalid_lifecycle_operation,
                                server:Server,
                                detail:Detail,
                                message:"MCP lifecycle operation is invalid"}.
lifecycle_exception(Phase, Server, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = mcp_lifecycle_error{phase:Phase,
                                kind:lifecycle_exception,
                                server:Server,
                                exception:Safe,
                                message:"MCP lifecycle operation raised an exception"}.

lifecycle_control_exception(rlm_async_cancelled(_)).
lifecycle_control_exception(rlm_cancelled(_)).
lifecycle_control_exception(chain_cancelled(_)).
lifecycle_control_exception(graph_cancelled(_)).
lifecycle_control_exception(cancelled(_)).
lifecycle_control_exception('$aborted').
lifecycle_control_exception(abort).

dict_value_default(Key, Dict, Default, Value) :-
    ( get_dict(Key, Dict, Found) -> Value = Found ; Value = Default ).