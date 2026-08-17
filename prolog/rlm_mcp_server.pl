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

Server declarations are passive trusted host data until explicit install/run
calls. Loading this module or an external tool category never installs, starts,
connects to, or imports tools from an MCP server.

Process-backed declarations are closed over trusted host execution profiles.
They do not contain executable paths, arbitrary argv, shell commands, or raw
environment values. Environment values are represented by `env_ref/1` and
`config_ref/1` references and are resolved only inside an authority-permitted
lifecycle continuation immediately before process creation.

Latency-bearing lifecycle operations preserve the canonical async direction:
the async surface submits one execute predicate; the synchronous surface starts
that same operation and waits on its Future. Trusted code already executing in a
canonical async worker calls execute predicates directly.
*/

:- use_module(library(option)).
:- use_module(library(process)).
:- use_module(library(time)).
:- use_module(rlm_async, []).
:- use_module(rlm_authority, []).
:- use_module(rlm_mcp, []).
:- use_module(rlm_mcp_policy, []).
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
    require_spec_key(Spec0, transport, Transport0),
    normalize_transport_spec(Transport0, Transport),
    dict_value_default(install, Spec0, none, Install0),
    rlm_mcp_policy:mcp_install_recipe_normalize(Install0, Install),
    dict_value_default(environment, Spec0, [], Environment0),
    rlm_mcp_policy:mcp_environment_normalize(Environment0, Environment),
    dict_value_default(working_directory, Spec0, inherit, WorkingDirectory0),
    rlm_mcp_policy:mcp_working_directory_normalize(WorkingDirectory0,
                                                    WorkingDirectory),
    validate_execution_configuration_usage(Transport,
                                             Install,
                                             Environment,
                                             WorkingDirectory),
    dict_value_default(version, Spec0, unspecified, Version),
    dict_value_default(capabilities, Spec0, [], Capabilities),
    dict_value_default(options, Spec0, [], Options0),
    require_ground(Version, version),
    require_capability_list(Capabilities),
    normalize_runtime_options(Options0, Options),
    Spec = mcp_server_spec{name:Name,
                           transport:Transport,
                           install:Install,
                           environment:Environment,
                           working_directory:WorkingDirectory,
                           version:Version,
                           capabilities:Capabilities,
                           options:Options}.
normalize_server_spec(_, _, _) :-
    throw(mcp_lifecycle_fault(invalid_server_spec)).

normalize_transport_spec(existing(Transport), existing(Transport)) :-
    !,
    require_ground(Transport, transport).
normalize_transport_spec(fixture(Kind, Handler), fixture(Kind, Handler)) :-
    !,
    memberchk(Kind, [stdio,streamable_http]),
    callable(Handler),
    ground(Handler).
normalize_transport_spec(stdio(Recipe0), stdio(Recipe)) :-
    !,
    rlm_mcp_policy:mcp_stdio_recipe_normalize(Recipe0, Recipe).
normalize_transport_spec(streamable_http(Endpoint), streamable_http(Endpoint)) :-
    !,
    text_value(Endpoint),
    Endpoint \== ''.
normalize_transport_spec(_, _) :-
    throw(mcp_lifecycle_fault(invalid_transport_spec)).

validate_execution_configuration_usage(Transport, Install,
                                       Environment, WorkingDirectory) :-
    (   Environment == [], WorkingDirectory == inherit
    ->  true
    ;   Install \== none
    ->  true
    ;   Transport = stdio(_)
    ->  true
    ;   throw(mcp_lifecycle_fault(configuration_without_process_boundary))
    ).

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
    validate_install_call_options(Options),
    mcp_server_definition(Name, DefinitionOutcome),
    install_after_definition(DefinitionOutcome, Name, Options, Outcome).

install_after_definition(error(Error), _, _, error(Error)) :- !.
install_after_definition(ok(Spec), Name, Options, Outcome) :-
    install_recipe_effect(Spec, Name, Options, Outcome).

install_recipe_effect(Spec, Name, _,
                      ok(mcp_install_result{server:Name,
                                            status:not_required})) :-
    Spec.install == none,
    !.
install_recipe_effect(Spec, Name, Options, Outcome) :-
    Recipe = Spec.install,
    Recipe = package(Profile, Package, Version),
    rlm_mcp_policy:mcp_install_preflight(Recipe,
                                         Spec.environment,
                                         Spec.working_directory,
                                         PolicyDetails),
    authority_context(Name, Options, Context),
    Operation = authority_operation{name:mcp_install,
                                    effect:install,
                                    capability:mcp(Name),
                                    args:mcp_install_args{server:Name,
                                                          profile:Profile,
                                                          package:Package,
                                                          version:Version},
                                    details:mcp_install_details{
                                                policy:PolicyDetails}},
    Continuation = rlm_mcp_server:install_package_effect(
                       Name,
                       Recipe,
                       Spec.environment,
                       Spec.working_directory),
    lifecycle_authorize(Context, Operation, Continuation, install, Name,
                        Outcome).

install_package_effect(Name, Recipe, Environment, WorkingDirectory, Outcome) :-
    rlm_mcp_policy:mcp_prepare_install(Recipe,
                                       Environment,
                                       WorkingDirectory,
                                       Prepared),
    run_installer_process(Name, Prepared, Outcome).

run_installer_process(Name, Prepared, Outcome) :-
    prepared_executable(Prepared.executable, Executable),
    installer_process_options(Prepared, Pid, ProcessOptions),
    process_create(Executable, Prepared.argv, ProcessOptions),
    wait_installer_process(Pid, Prepared.timeout, Status),
    installer_status_outcome(Status, Name, Prepared, Outcome).

installer_process_options(Prepared, Pid, Options) :-
    Base = [process(Pid), stdout(null), stderr(null)],
    environment_process_option(Prepared.environment, EnvironmentOptions),
    cwd_process_option(Prepared.cwd, CwdOptions),
    append([Base, EnvironmentOptions, CwdOptions], Options).

environment_process_option([], []).
environment_process_option(Environment, [environment(Environment)]) :-
    Environment \== [].

cwd_process_option(inherit, []).
cwd_process_option(Cwd, [cwd(Cwd)]) :- Cwd \== inherit.

wait_installer_process(Pid, Timeout, Status) :-
    catch(call_with_time_limit(Timeout, process_wait(Pid, WaitStatus)),
          Exception,
          installer_wait_exception(Pid, Exception, WaitStatus)),
    Status = WaitStatus.

installer_wait_exception(Pid, time_limit_exceeded, timeout) :-
    !,
    terminate_and_reap(Pid).
installer_wait_exception(Pid, Exception, _) :-
    terminate_and_reap(Pid),
    throw(Exception).

terminate_and_reap(Pid) :-
    catch(process_kill(Pid, term), _, true),
    catch(process_wait(Pid, _), _, true).

installer_status_outcome(exit(0), Name, Prepared,
                         ok(mcp_install_result{
                                server:Name,
                                status:installed,
                                process_status:exit(0),
                                captured_output_bytes:0,
                                output_limit_bytes:Prepared.max_output_bytes})) :-
    !.
installer_status_outcome(timeout, Name, _,
                         error(mcp_lifecycle_error{
                                   phase:install,
                                   kind:installer_timeout,
                                   server:Name,
                                   message:"MCP installer exceeded its trusted profile time limit"
                               })) :- !.
installer_status_outcome(Status, Name, _,
                         error(mcp_lifecycle_error{
                                   phase:install,
                                   kind:installer_failed,
                                   server:Name,
                                   process_status:Status,
                                   message:"MCP installer exited unsuccessfully"
                               })).

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
    transport_preflight(Spec, Effect, Details),
    Operation = authority_operation{name:mcp_run,
                                    effect:Effect,
                                    capability:mcp(Name),
                                    args:mcp_run_args{server:Name},
                                    details:Details},
    Continuation = rlm_mcp_server:run_transport_effect(
                       Name, Spec, RuntimeOptions, Context),
    lifecycle_authorize(Context, Operation, Continuation, run, Name, Outcome).

transport_preflight(Spec, service_start, Details) :-
    Spec.transport = stdio(Recipe),
    !,
    rlm_mcp_policy:mcp_stdio_preflight(Recipe,
                                       Spec.environment,
                                       Spec.working_directory,
                                       PolicyDetails),
    stdio_recipe_metadata(Recipe, RecipeMetadata),
    Details = mcp_transport_details{kind:stdio,
                                    recipe:RecipeMetadata,
                                    policy:PolicyDetails}.
transport_preflight(Spec, read,
                    mcp_transport_details{kind:fixture,
                                          transport_kind:Kind}) :-
    Spec.transport = fixture(Kind, _),
    !.
transport_preflight(Spec, read,
                    mcp_transport_details{kind:streamable_http,
                                          endpoint:redacted}) :-
    Spec.transport = streamable_http(_),
    !.
transport_preflight(Spec, read,
                    mcp_transport_details{kind:existing}) :-
    Spec.transport = existing(_),
    !.

stdio_recipe_metadata(profile(Profile),
                      mcp_stdio_recipe{kind:profile,
                                       profile:Profile}).
stdio_recipe_metadata(package(Profile, Package, Version),
                      mcp_stdio_recipe{kind:package,
                                       profile:Profile,
                                       package:Package,
                                       version:Version}).

run_transport_effect(Name, Spec, RuntimeOptions, Context, Outcome) :-
    prepare_transport_open(Spec,
                           RuntimeOptions,
                           TransportSpec,
                           TransportOptions),
    run_prepared_transport_effect(Name,
                                  Spec,
                                  TransportSpec,
                                  TransportOptions,
                                  Context,
                                  Outcome).

prepare_transport_open(Spec, RuntimeOptions,
                       stdio(Executable, Args), TransportOptions) :-
    Spec.transport = stdio(Recipe),
    !,
    rlm_mcp_policy:mcp_prepare_stdio(Recipe,
                                     Spec.environment,
                                     Spec.working_directory,
                                     Prepared),
    prepared_executable(Prepared.executable, Executable),
    Args = Prepared.argv,
    transport_process_options(Prepared, ProcessOptions),
    append(RuntimeOptions, ProcessOptions, TransportOptions).
prepare_transport_open(Spec, RuntimeOptions, Spec.transport, RuntimeOptions).

transport_process_options(Prepared, Options) :-
    (   Prepared.environment == []
    ->  EnvironmentOptions = []
    ;   EnvironmentOptions = [mcp_process_environment(Prepared.environment)]
    ),
    (   Prepared.cwd == inherit
    ->  CwdOptions = []
    ;   CwdOptions = [mcp_process_cwd(Prepared.cwd)]
    ),
    append(EnvironmentOptions, CwdOptions, Options).

run_prepared_transport_effect(Name, Spec, TransportSpec, TransportOptions,
                              Context, Outcome) :-
    rlm_mcp_transport:mcp_transport_open(TransportSpec,
                                         TransportOptions,
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
    restart_authority(Transport, Spec, Effect, Details),
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
    prepare_transport_open(Spec,
                           RuntimeOptions,
                           TransportSpec,
                           TransportOptions),
    Transport = Handle.transport,
    rlm_mcp_transport:mcp_transport_stop(Transport, StopOutcome),
    restart_after_stop(StopOutcome,
                       Server,
                       Spec,
                       TransportSpec,
                       TransportOptions,
                       Context,
                       Outcome).

restart_after_stop(error(Error), _, _, _, _, _, error(Error)) :- !.
restart_after_stop(ok(_), Server, Spec, TransportSpec, TransportOptions,
                   Context, Outcome) :-
    run_prepared_transport_effect(Server,
                                  Spec,
                                  TransportSpec,
                                  TransportOptions,
                                  Context,
                                  Outcome).

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
                                       Outcome).

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
    safe_exception_summary(Exception, Safe),
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

stop_authority(Transport, service_stop,
               mcp_transport_details{kind:stdio}) :-
    is_dict(Transport, mcp_transport),
    get_dict(backend, Transport, stdio(_,_,_,_)),
    !.
stop_authority(_, read, mcp_transport_details{kind:non_owned_process}).

restart_authority(Transport, Spec, service_start, Details) :-
    ( is_dict(Transport, mcp_transport),
      get_dict(backend, Transport, stdio(_,_,_,_))
    ; Spec.transport = stdio(_)
    ),
    !,
    transport_preflight(Spec, service_start, Details).
restart_authority(_, Spec, read, Details) :-
    transport_preflight(Spec, _, Details).

/* -------------------------------------------------------------------------
 * Validation and options
 * ---------------------------------------------------------------------- */

require_running_handle(Handle, Server, Transport) :-
    is_dict(Handle, mcp_runtime_handle),
    get_dict(status, Handle, running),
    get_dict(server, Handle, Server),
    get_dict(transport, Handle, Transport),
    !.
require_running_handle(_, _, _) :-
    throw(mcp_lifecycle_fault(invalid_runtime_handle)).

require_server_name(Name) :-
    atom(Name),
    Name \== '',
    !.
require_server_name(_) :-
    throw(mcp_lifecycle_fault(invalid_server_name)).

require_spec_key(Spec, Key, Value) :-
    (   get_dict(Key, Spec, Value)
    ->  true
    ;   throw(mcp_lifecycle_fault(missing_server_field(Key)))
    ).

require_ground(Value, _) :- ground(Value), !.
require_ground(_, Field) :-
    throw(mcp_lifecycle_fault(nonground_field(Field))).

require_capability_list(Value) :-
    is_list(Value),
    ground(Value),
    !.
require_capability_list(_) :-
    throw(mcp_lifecycle_fault(invalid_capabilities)).

validate_install_call_options(Options) :-
    is_list(Options),
    ground(Options),
    forall(member(Option, Options), valid_install_call_option(Option)),
    !.
validate_install_call_options(_) :-
    throw(mcp_lifecycle_fault(invalid_install_call_options)).

valid_install_call_option(authority_context(Context)) :- ground(Context), !.
valid_install_call_option(session_id(Session)) :- ground(Session), !.
valid_install_call_option(trace_id(Trace)) :- ground(Trace), !.
valid_install_call_option(_) :-
    throw(mcp_lifecycle_fault(disallowed_install_call_option)).

merge_runtime_options(Spec, Options, RuntimeOptions) :-
    ( get_dict(options, Spec, SpecOptions), is_list(SpecOptions)
    -> true
    ; SpecOptions = [] ),
    ( is_list(Options)
    -> exclude(lifecycle_only_option, Options, RuntimeUserOptions),
       append(RuntimeUserOptions, SpecOptions, RuntimeOptions)
    ; throw(mcp_lifecycle_fault(invalid_options)) ).

lifecycle_only_option(authority_context(_)).
lifecycle_only_option(session_id(_)).
lifecycle_only_option(trace_id(_)).

normalize_runtime_options(Options, Normalized) :-
    is_list(Options),
    ground(Options),
    forall(member(Option, Options), valid_runtime_option(Option)),
    !,
    Normalized = Options.
normalize_runtime_options(_, _) :-
    throw(mcp_lifecycle_fault(invalid_runtime_options)).

valid_runtime_option(timeout(Value)) :- number(Value), Value > 0, !.
valid_runtime_option(_) :-
    throw(mcp_lifecycle_fault(disallowed_runtime_option)).

prepared_executable(path(Name), path(Name)).
prepared_executable(file(Path), Path).

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
lifecycle_exception(Phase, Server, mcp_policy_fault(Detail), error(Error)) :-
    !,
    Error = mcp_lifecycle_error{phase:Phase,
                                kind:execution_policy_denied,
                                server:Server,
                                detail:Detail,
                                message:"MCP lifecycle execution policy rejected the operation"}.
lifecycle_exception(Phase, Server, mcp_lifecycle_fault(Detail), error(Error)) :-
    !,
    Error = mcp_lifecycle_error{phase:Phase,
                                kind:invalid_lifecycle_operation,
                                server:Server,
                                detail:Detail,
                                message:"MCP lifecycle operation is invalid"}.
lifecycle_exception(Phase, Server, Exception, error(Error)) :-
    safe_exception_summary(Exception, Safe),
    Error = mcp_lifecycle_error{phase:Phase,
                                kind:lifecycle_exception,
                                server:Server,
                                exception:Safe,
                                message:"MCP lifecycle operation raised an exception"}.

safe_exception_summary(mcp_policy_fault(Detail), mcp_policy_fault(Detail)) :- !.
safe_exception_summary(mcp_lifecycle_fault(Detail),
                       mcp_lifecycle_fault(Detail)) :- !.
safe_exception_summary(Exception, exception(Name, Arity)) :-
    nonvar(Exception),
    functor(Exception, Name, Arity),
    !.
safe_exception_summary(_, exception(unknown, 0)).

lifecycle_control_exception(rlm_async_cancelled(_)).
lifecycle_control_exception(rlm_cancelled(_)).
lifecycle_control_exception(chain_cancelled(_)).
lifecycle_control_exception(graph_cancelled(_)).
lifecycle_control_exception(cancelled(_)).
lifecycle_control_exception('$aborted').
lifecycle_control_exception(abort).

dict_value_default(Key, Dict, Default, Value) :-
    ( get_dict(Key, Dict, Found) -> Value = Found ; Value = Default ).
