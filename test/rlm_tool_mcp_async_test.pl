:- begin_tests(rlm_tool_mcp_async).

:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_tool_async', []).
:- use_module('../prolog/rlm_mcp').
:- use_module('../prolog/rlm_mcp_async', []).
:- use_module('../prolog/rlm_mcp_server').
:- use_module('../prolog/rlm_mcp_tool').
:- use_module('support/tool_test_support').

:- multifile rlm_mcp_server:mcp_server/2.

:- dynamic direct_tool_calls/1.
:- dynamic cancellable_started/0.
:- dynamic cancellable_cleanups/1.
:- dynamic mcp_remote_calls/1.
:- dynamic mcp_slow_started/0.
:- dynamic mcp_slow_cleanups/1.

rlm_mcp_server:mcp_server(
    async_fixture,
    mcp_server_spec{
        transport:fixture(streamable_http,
                          plunit_rlm_tool_mcp_async:mcp_fixture),
        install:none,
        version:"fixture-1",
        capabilities:[tools]
    }).

/* Source architecture helpers ------------------------------------------ */

canonical_submit(Module, AsyncName/AsyncArity, ExecuteName/ExecuteArity) :-
    functor(Head, AsyncName, AsyncArity),
    clause(Module:Head, Body),
    submit_closure(Body, Closure),
    strip_module(Closure, ClosureModule, PlainClosure),
    ClosureModule == Module,
    functor(PlainClosure, ExecuteName, ClosureArity),
    ExecuteArity is ClosureArity+1,
    !.

submit_closure(Body, Closure) :-
    sub_term(SubTerm, Body),
    nonvar(SubTerm),
    (   SubTerm = rlm_async_submit(Closure, _, _)
    ;   SubTerm = rlm_async:rlm_async_submit(Closure, _, _)
    ).

sync_calls_async(Module, SyncName/SyncArity, AsyncName/AsyncArity) :-
    functor(Head, SyncName, SyncArity),
    clause(Module:Head, Body),
    sub_term(Call, Body),
    nonvar(Call),
    source_call_functor(Call, AsyncName, AsyncArity),
    !.

source_call_functor(_Module:Goal, Name, Arity) :-
    !,
    callable(Goal),
    functor(Goal, Name, Arity).
source_call_functor(Goal, Name, Arity) :-
    callable(Goal),
    functor(Goal, Name, Arity).

body_calls(Body, Name, Arity) :-
    sub_term(Call0, Body),
    nonvar(Call0),
    ( Call0 = _Module:Call -> true ; Call = Call0 ),
    callable(Call),
    functor(Call, Name, Arity).

body_contains_qualified(Body, Module, Name, Arity) :-
    sub_term(SubTerm, Body),
    nonvar(SubTerm),
    SubTerm = Module:Goal,
    callable(Goal),
    functor(Goal, Name, Arity).

/* Tool fixtures --------------------------------------------------------- */

reset_direct_tool_calls :-
    retractall(direct_tool_calls(_)),
    assertz(direct_tool_calls(0)).

counted_tool(Args, json{seen:Value}) :-
    with_mutex(plunit_rlm_tool_mcp_async_direct,
               ( retract(direct_tool_calls(Current)),
                 Next is Current+1,
                 assertz(direct_tool_calls(Next))
               )),
    Value = Args.value.

counting_schema(
    tool_schema{name:async_counting,
                description:"canonical async counting tool",
                capability:tool(async_counting),
                arguments:_{type:object,
                            required:[value],
                            additional_properties:false,
                            properties:_{value:_{type:integer}}},
                result:_{type:object,
                         required:[seen],
                         additional_properties:false,
                         properties:_{seen:_{type:integer}}},
                limits:_{time_limit:2.0, max_output_bytes:4096}}).

cancellable_schema(
    tool_schema{name:async_cancellable,
                description:"cancellation fixture",
                capability:tool(async_cancellable),
                arguments:_{type:object,
                            required:[],
                            additional_properties:false,
                            properties:_{}},
                result:_{type:object,
                         required:[ok],
                         additional_properties:false,
                         properties:_{ok:_{type:boolean}}},
                limits:_{time_limit:5.0, max_output_bytes:4096}}).

reset_cancellable :-
    retractall(cancellable_started),
    retractall(cancellable_cleanups(_)),
    assertz(cancellable_cleanups(0)).

cancellable_tool(_, json{ok:true}) :-
    setup_call_cleanup(
        assertz(cancellable_started),
        sleep(2.0),
        with_mutex(plunit_rlm_tool_mcp_async_cancel,
                   ( retract(cancellable_cleanups(Current)),
                     Next is Current+1,
                     assertz(cancellable_cleanups(Next))
                   ))).

wait_for(Goal) :-
    wait_for(Goal, 100).

wait_for(Goal, _) :- call(Goal), !.
wait_for(_, 0) :- !, fail.
wait_for(Goal, Attempts) :-
    sleep(0.01),
    Next is Attempts-1,
    wait_for(Goal, Next).

/* MCP fixture ----------------------------------------------------------- */

reset_mcp_fixture :-
    retractall(mcp_remote_calls(_)),
    assertz(mcp_remote_calls(0)),
    retractall(mcp_slow_started),
    retractall(mcp_slow_cleanups(_)),
    assertz(mcp_slow_cleanups(0)).

client_info(_{name:"async-client", version:"1.0"}).
client_caps(_{roots:_{listChanged:false}}).
server_info(_{name:"async-server", version:"1.0"}).
server_caps(_{tools:_{listChanged:false}}).

mcp_fixture(Wire, Meta, Response) :-
    get_dict(method, Wire, Method),
    mcp_fixture_method(Method, Wire, Meta, Response).

mcp_fixture_method("server/discover", Wire, _, Response) :-
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          error:_{code: -32601, message:"Method not found"}},
                   headers:transport_headers{},
                   content_type:'application/json'}.
mcp_fixture_method("initialize", Wire, _, Response) :-
    server_info(Info),
    server_caps(Caps),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{protocolVersion:"2025-11-25",
                                   capabilities:Caps,
                                   serverInfo:Info}},
                   headers:transport_headers{'mcp-session-id':"async-session"},
                   content_type:'application/json'}.
mcp_fixture_method("notifications/initialized", _, _, null).
mcp_fixture_method("tools/list", Wire, _, Response) :-
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{tools:[_{name:"lookup",
                                           description:"fixture lookup",
                                           inputSchema:_{type:"object",
                                                         required:["query"],
                                                         additionalProperties:false,
                                                         properties:_{query:_{type:"string"}}}}]}},
                   headers:transport_headers{},
                   content_type:'application/json'}.
mcp_fixture_method("tools/call", Wire, _, Response) :-
    Query = Wire.params.arguments.query,
    mcp_call_response(Query, Wire, Response).

mcp_call_response("slow", Wire, Response) :-
    !,
    setup_call_cleanup(
        ( assertz(mcp_slow_started), bump_remote_calls ),
        sleep(2.0),
        with_mutex(plunit_rlm_tool_mcp_async_mcp_cleanup,
                   ( retract(mcp_slow_cleanups(Current)),
                     Next is Current+1,
                     assertz(mcp_slow_cleanups(Next))
                   ))),
    tool_response(Wire, "slow", Response).
mcp_call_response(Query, Wire, Response) :-
    bump_remote_calls,
    tool_response(Wire, Query, Response).

bump_remote_calls :-
    with_mutex(plunit_rlm_tool_mcp_async_remote,
               ( retract(mcp_remote_calls(Current)),
                 Next is Current+1,
                 assertz(mcp_remote_calls(Next))
               )).

tool_response(Wire, Query, Response) :-
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{content:[_{type:"text", text:"tool-ok"}],
                                   structuredContent:_{answer:Query},
                                   isError:false}},
                   headers:transport_headers{},
                   content_type:'application/json'}.

connect_fixture(Client) :-
    client_info(Info),
    client_caps(Caps),
    mcp_client_connect(fixture(streamable_http,
                               plunit_rlm_tool_mcp_async:mcp_fixture),
                       Info,
                       Caps,
                       [],
                       ok(Client)).

/* Architecture regressions --------------------------------------------- */

test(tool_async_submits_canonical_execute_predicate) :-
    assertion(canonical_submit(rlm_tool,
                               tool_invoke_async/6,
                               tool_invoke_execute/6)).

test(tool_sync_starts_async_operation) :-
    assertion(sync_calls_async(rlm_tool,
                               tool_invoke/7,
                               tool_invoke_async/6)).

test(tool_plan_adapter_uses_execute_abi_not_sync_wrapper) :-
    clause(rlm_tool:registry_plan_handler(_, _, _, _, _), Body),
    assertion(body_calls(Body, tool_invoke_execute, 6)),
    assertion(\+ body_calls(Body, tool_invoke, 7)).

test(tool_wrappers_do_not_duplicate_capability_or_schema_checks) :-
    clause(rlm_tool:tool_invoke_async(_, _, _, _, _, _), AsyncBody),
    clause(rlm_tool:tool_invoke(_, _, _, _, _, _, _), SyncBody),
    assertion(\+ body_calls(AsyncBody, authorize_tool, 3)),
    assertion(\+ body_calls(AsyncBody, validate_schema, 4)),
    assertion(\+ body_calls(SyncBody, authorize_tool, 3)),
    assertion(\+ body_calls(SyncBody, validate_schema, 4)).

test(tool_compat_async_never_calls_sync_wrapper) :-
    clause(rlm_tool_async:tool_invoke_async(_, _, _, _, _, _), Body),
    assertion(\+ body_contains_qualified(Body,
                                         rlm_tool,
                                         tool_invoke,
                                         7)).

test(mcp_async_submits_only_execute_predicates) :-
    assertion(canonical_submit(rlm_mcp,
                               mcp_client_connect_async/5,
                               mcp_client_connect_execute/5)),
    assertion(canonical_submit(rlm_mcp,
                               mcp_client_command_async/4,
                               mcp_client_command_execute/3)),
    assertion(canonical_submit(rlm_mcp,
                               mcp_client_close_async/2,
                               mcp_client_close_execute/2)),
    assertion(canonical_submit(rlm_mcp,
                               mcp_server_handle_async/6,
                               mcp_server_handle_execute/5)).

test(mcp_sync_surfaces_start_async_surfaces) :-
    assertion(sync_calls_async(rlm_mcp,
                               mcp_client_connect/5,
                               mcp_client_connect_async/5)),
    assertion(sync_calls_async(rlm_mcp,
                               mcp_client_command/4,
                               mcp_client_command_async/4)),
    assertion(sync_calls_async(rlm_mcp,
                               mcp_client_close/2,
                               mcp_client_close_async/2)),
    assertion(sync_calls_async(rlm_mcp,
                               mcp_server_handle/6,
                               mcp_server_handle_async/6)).

test(mcp_compat_async_never_calls_sync_wrappers) :-
    forall(member(AsyncPI-SyncPI,
                  [ mcp_client_connect_async/5-mcp_client_connect/5,
                    mcp_client_command_async/4-mcp_client_command/4,
                    mcp_client_close_async/2-mcp_client_close/2,
                    mcp_server_handle_async/6-mcp_server_handle/6
                  ]),
           ( AsyncPI = AsyncName/AsyncArity,
             functor(Head, AsyncName, AsyncArity),
             clause(rlm_mcp_async:Head, Body),
             SyncPI = SyncName/SyncArity,
             assertion(\+ body_contains_qualified(Body,
                                                  rlm_mcp,
                                                  SyncName,
                                                  SyncArity))
           )).

test(mcp_lifecycle_async_submits_execute_predicates) :-
    assertion(canonical_submit(rlm_mcp_server,
                               rlm_install_mcp_server_async/3,
                               rlm_install_mcp_server_execute/3)),
    assertion(canonical_submit(rlm_mcp_server,
                               rlm_run_mcp_server_async/3,
                               rlm_run_mcp_server_execute/3)),
    assertion(canonical_submit(rlm_mcp_server,
                               rlm_stop_mcp_server_async/2,
                               rlm_stop_mcp_server_execute/2)),
    assertion(canonical_submit(rlm_mcp_server,
                               rlm_restart_mcp_server_async/3,
                               rlm_restart_mcp_server_execute/3)),
    assertion(canonical_submit(rlm_mcp_server,
                               rlm_connect_mcp_server_async/5,
                               rlm_connect_mcp_server_execute/5)).

test(mcp_lifecycle_sync_starts_async_operations) :-
    assertion(sync_calls_async(rlm_mcp_server,
                               rlm_install_mcp_server/3,
                               rlm_install_mcp_server_async/3)),
    assertion(sync_calls_async(rlm_mcp_server,
                               rlm_run_mcp_server/3,
                               rlm_run_mcp_server_async/3)),
    assertion(sync_calls_async(rlm_mcp_server,
                               rlm_stop_mcp_server/2,
                               rlm_stop_mcp_server_async/2)),
    assertion(sync_calls_async(rlm_mcp_server,
                               rlm_restart_mcp_server/3,
                               rlm_restart_mcp_server_async/3)),
    assertion(sync_calls_async(rlm_mcp_server,
                               rlm_connect_mcp_server/5,
                               rlm_connect_mcp_server_async/5)).

/* Tool behavior --------------------------------------------------------- */

test(sync_tool_executes_handler_once,
     [setup(reset_direct_tool_calls)]) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( counting_schema(Schema),
          tool_register(Registry,
                        Schema,
                        plunit_rlm_tool_mcp_async:counted_tool,
                        ok(_)),
          tool_invoke(Registry,
                      [tool(async_counting)],
                      async_counting,
                      _{value:7},
                      [],
                      ok(Execution),
                      Trace),
          assertion(Execution.value.seen =:= 7),
          assertion(Trace.authorization == allowed),
          direct_tool_calls(Calls),
          assertion(Calls =:= 1)
        ),
        tool_registry_destroy(Registry)).

test(async_tool_executes_handler_once_and_has_metadata,
     [setup(reset_direct_tool_calls)]) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( counting_schema(Schema),
          tool_register(Registry,
                        Schema,
                        plunit_rlm_tool_mcp_async:counted_tool,
                        ok(_)),
          tool_invoke_async(Registry,
                            [tool(async_counting)],
                            async_counting,
                            _{value:9},
                            [trace_id(tool_trace_54),
                             session_id(tool_session_54)],
                            Future),
          setup_call_cleanup(
              true,
              ( rlm_future_metadata(Future, Metadata),
                assertion(Metadata.operation == tool_invoke),
                assertion(Metadata.tool == async_counting),
                assertion(Metadata.trace_id == tool_trace_54),
                assertion(Metadata.session_id == tool_session_54),
                rlm_future_await(Future, 2.0, Result),
                Result = tool_async_result{outcome:ok(Execution), trace:Trace},
                assertion(Execution.value.seen =:= 9),
                assertion(Trace.authorization == allowed),
                direct_tool_calls(Calls),
                assertion(Calls =:= 1)
              ),
              rlm_future_destroy(Future))
        ),
        tool_registry_destroy(Registry)).

test(sync_async_tool_trace_and_outcome_semantics_match) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( counting_schema(Schema),
          tool_register(Registry,
                        Schema,
                        plunit_rlm_tool_mcp_async:counted_tool,
                        ok(_)),
          reset_direct_tool_calls,
          tool_invoke(Registry,
                      [tool(async_counting)],
                      async_counting,
                      _{value:11},
                      [],
                      ok(SyncExecution),
                      SyncTrace),
          reset_direct_tool_calls,
          tool_invoke_async(Registry,
                            [tool(async_counting)],
                            async_counting,
                            _{value:11},
                            [],
                            Future),
          setup_call_cleanup(
              true,
              rlm_future_await(Future,
                               2.0,
                               tool_async_result{outcome:ok(AsyncExecution),
                                                 trace:AsyncTrace}),
              rlm_future_destroy(Future)),
          assertion(SyncExecution.value == AsyncExecution.value),
          assertion(SyncTrace.authorization == AsyncTrace.authorization),
          assertion(SyncTrace.status == AsyncTrace.status),
          assertion(SyncTrace.output_bytes == AsyncTrace.output_bytes)
        ),
        tool_registry_destroy(Registry)).

test(tool_wait_timeout_does_not_restart_and_cancel_cleans_up,
     [setup(reset_cancellable)]) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( cancellable_schema(Schema),
          tool_register(Registry,
                        Schema,
                        plunit_rlm_tool_mcp_async:cancellable_tool,
                        ok(_)),
          tool_invoke_async(Registry,
                            [tool(async_cancellable)],
                            async_cancellable,
                            _{},
                            [],
                            Future),
          setup_call_cleanup(
              true,
              ( wait_for(cancellable_started),
                rlm_future_await(Future, 0.001, TimeoutOutcome),
                TimeoutOutcome = error(TimeoutError),
                assertion(TimeoutError.kind == timeout),
                rlm_future_cancel(Future, CancelOutcome),
                assertion(CancelOutcome == ok(cancelled)),
                rlm_future_await(Future, CancelledOutcome),
                CancelledOutcome = error(CancelError),
                assertion(CancelError.kind == cancelled),
                wait_for(cancellable_cleanups(1))
              ),
              rlm_future_destroy(Future))
        ),
        tool_registry_destroy(Registry)).

/* MCP behavior ---------------------------------------------------------- */

test(mcp_definition_is_queryable_and_inert,
     [setup(reset_mcp_fixture)]) :-
    mcp_server_definition(async_fixture, ok(Spec)),
    assertion(Spec.name == async_fixture),
    assertion(Spec.install == none),
    assertion(Spec.version == "fixture-1"),
    mcp_remote_calls(RemoteCalls),
    assertion(RemoteCalls =:= 0).

test(mcp_definition_does_not_auto_install_or_run,
     [setup(reset_mcp_fixture)]) :-
    mcp_server_definitions(Definitions),
    member(Spec, Definitions),
    Spec.name == async_fixture,
    mcp_remote_calls(RemoteCalls),
    assertion(RemoteCalls =:= 0).

test(mcp_install_none_is_explicit_and_canonical) :-
    rlm_install_mcp_server(async_fixture, ok(Install)),
    assertion(Install.status == not_required).

test(mcp_run_connect_stop_are_explicit_and_borrowed,
     [setup(reset_mcp_fixture)]) :-
    rlm_run_mcp_server(async_fixture, ok(Handle0)),
    assertion(Handle0.status == running),
    client_info(Info),
    client_caps(Caps),
    rlm_connect_mcp_server(Handle0, Info, Caps, [], ok(Client0)),
    mcp_client_command(Client0, list_tools, Client1, ok(Page)),
    Page.tools = [Tool],
    assertion(Tool.name == lookup),
    mcp_client_close(Client1, ok(closed)),
    assertion(Handle0.status == running),
    rlm_stop_mcp_server(Handle0, ok(Handle1)),
    assertion(Handle1.status == stopped).

test(mcp_restart_uses_execute_abis_without_nested_future) :-
    rlm_run_mcp_server(async_fixture, ok(Handle0)),
    rlm_restart_mcp_server(Handle0, ok(Handle1)),
    assertion(Handle1.status == running),
    rlm_stop_mcp_server(Handle1, ok(_)).

test(async_mcp_command_returns_updated_client_and_metadata) :-
    connect_fixture(Client0),
    setup_call_cleanup(
        mcp_client_command_async(Client0,
                                 list_tools,
                                 [trace_id(mcp_trace_54),
                                  session_id(mcp_session_54)],
                                 Future),
        ( rlm_future_metadata(Future, Metadata),
          assertion(Metadata.operation == mcp_command),
          assertion(Metadata.trace_id == mcp_trace_54),
          assertion(Metadata.session_id == mcp_session_54),
          rlm_future_await(Future, 2.0, Result),
          Result = mcp_command_async_result{client:Client1,
                                             outcome:ok(Page)},
          Page.tools = [Tool],
          assertion(Tool.name == lookup),
          mcp_client_close(Client1, ok(closed))
        ),
        rlm_future_destroy(Future)).

test(sync_async_mcp_command_outcome_and_trace_match) :-
    connect_fixture(Client0),
    mcp_client_command(Client0, list_tools, SyncClient, ok(SyncPage)),
    mcp_client_command_async(Client0, list_tools, [], Future),
    setup_call_cleanup(
        true,
        rlm_future_await(Future,
                         2.0,
                         mcp_command_async_result{client:AsyncClient,
                                                  outcome:ok(AsyncPage)}),
        rlm_future_destroy(Future)),
    assertion(SyncPage =@= AsyncPage),
    mcp_client_trace(SyncClient, SyncTrace),
    mcp_client_trace(AsyncClient, AsyncTrace),
    assertion(SyncTrace =@= AsyncTrace),
    mcp_client_close(SyncClient, ok(closed)),
    mcp_client_close(AsyncClient, ok(closed)).

test(async_mcp_server_handle_matches_sync) :-
    server_info(ServerInfo),
    server_caps(ServerCaps),
    mcp_server_new(streamable_http,
                   ServerInfo,
                   ServerCaps,
                   [session_id("async-server-session")],
                   ok(Server0)),
    client_info(ClientInfo),
    client_caps(ClientCaps),
    Wire = _{jsonrpc:"2.0",
             id:1,
             method:"initialize",
             params:_{protocolVersion:"2025-11-25",
                      capabilities:ClientCaps,
                      clientInfo:ClientInfo}},
    Meta = _{headers:[]},
    mcp_server_handle(Server0,
                      Wire,
                      Meta,
                      plunit_rlm_tool_mcp_async:server_dispatch,
                      SyncServer,
                      SyncOutcome),
    mcp_server_handle_async(Server0,
                            Wire,
                            Meta,
                            plunit_rlm_tool_mcp_async:server_dispatch,
                            [],
                            Future),
    setup_call_cleanup(
        true,
        rlm_future_await(Future,
                         2.0,
                         mcp_server_async_result{server:AsyncServer,
                                                 outcome:AsyncOutcome}),
        rlm_future_destroy(Future)),
    assertion(SyncOutcome =@= AsyncOutcome),
    assertion(SyncServer =@= AsyncServer).

server_dispatch(_, mcp_tools_page{tools:[], next_cursor:null}).

test(mcp_cancellation_propagates_through_command,
     [setup(reset_mcp_fixture)]) :-
    connect_fixture(Client0),
    mcp_client_command_async(Client0,
                             call_tool(lookup, _{query:"slow"}),
                             [],
                             Future),
    setup_call_cleanup(
        true,
        ( wait_for(mcp_slow_started),
          rlm_future_cancel(Future, CancelOutcome),
          assertion(CancelOutcome == ok(cancelled)),
          rlm_future_await(Future, CancelledOutcome),
          CancelledOutcome = error(CancelError),
          assertion(CancelError.kind == cancelled),
          wait_for(mcp_slow_cleanups(1)),
          mcp_remote_calls(Calls),
          assertion(Calls =:= 1)
        ),
        rlm_future_destroy(Future)),
    mcp_client_close(Client0, ok(closed)).

/* Imported MCP tools ---------------------------------------------------- */

test(imported_mcp_tool_flows_through_tool_contract_once,
     [setup(reset_mcp_fixture)]) :-
    connect_fixture(Client0),
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( mcp_import_tools(Registry,
                           async_fixture,
                           Client0,
                           [],
                           ok(Import)),
          Import.tools = [Imported],
          LocalName = Imported.local_name,
          tool_invoke(Registry,
                      [tool(LocalName)],
                      LocalName,
                      _{query:"hello"},
                      [],
                      ok(Execution),
                      Trace),
          assertion(Execution.value.structured.answer == "hello"),
          assertion(Trace.authorization == allowed),
          assertion(Trace.status == ok),
          mcp_remote_calls(Calls),
          assertion(Calls =:= 1),
          mcp_import_state_destroy(Import.state)
        ),
        tool_registry_destroy(Registry)).

test(imported_mcp_tool_schema_rejects_before_remote_call,
     [setup(reset_mcp_fixture)]) :-
    connect_fixture(Client0),
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( mcp_import_tools(Registry,
                           async_fixture,
                           Client0,
                           [],
                           ok(Import)),
          Import.tools = [Imported],
          LocalName = Imported.local_name,
          tool_invoke(Registry,
                      [tool(LocalName)],
                      LocalName,
                      _{},
                      [],
                      error(Error),
                      Trace),
          assertion(Error.kind == schema_validation_failed),
          assertion(Trace.status == malformed_args),
          mcp_remote_calls(Calls),
          assertion(Calls =:= 0),
          mcp_import_state_destroy(Import.state)
        ),
        tool_registry_destroy(Registry)).

test(imported_mcp_tool_capability_denial_precedes_remote_call,
     [setup(reset_mcp_fixture)]) :-
    connect_fixture(Client0),
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( mcp_import_tools(Registry,
                           async_fixture,
                           Client0,
                           [],
                           ok(Import)),
          Import.tools = [Imported],
          LocalName = Imported.local_name,
          tool_invoke(Registry,
                      [],
                      LocalName,
                      _{query:"hello"},
                      [],
                      error(Error),
                      Trace),
          assertion(Error.kind == capability_denied),
          assertion(Trace.authorization == denied),
          mcp_remote_calls(Calls),
          assertion(Calls =:= 0),
          mcp_import_state_destroy(Import.state)
        ),
        tool_registry_destroy(Registry)).

:- end_tests(rlm_tool_mcp_async).
