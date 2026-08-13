:- begin_tests(rlm_mcp_runtime).

:- use_module('../prolog/rlm_mcp').

:- dynamic recovery_generation/1.

reset_recovery :-
    retractall(recovery_generation(_)),
    assertz(recovery_generation(0)).

client_info(_{name:"runtime-client", version:"1.0"}).
client_caps(_{roots:_{listChanged:false}}).
server_info(_{name:"runtime-server", version:"1.0"}).
server_caps(_{tools:_{listChanged:true},
              resources:_{subscribe:false},
              prompts:_{listChanged:true}}).

connect_fixture(Client) :-
    client_info(Info),
    client_caps(Caps),
    mcp_client_connect(fixture(streamable_http,
                               plunit_rlm_mcp_runtime:fixture_exchange),
                       Info,
                       Caps,
                       [],
                       ok(Client)).

test(client_negotiates_and_lists_tools_resources_prompts) :-
    connect_fixture(Client0),
    mcp_client_protocol(Client0, '2025-11-25'),
    mcp_client_command(Client0, list_tools, Client1, ok(ToolsPage)),
    ToolsPage.tools = [Tool],
    assertion(Tool.name == lookup),
    mcp_client_command(Client1, list_resources, Client2, ok(ResourcesPage)),
    ResourcesPage.resources = [Resource],
    assertion(Resource.uri == "file:///fixture.txt"),
    mcp_client_command(Client2, list_prompts, Client3, ok(PromptsPage)),
    PromptsPage.prompts = [Prompt],
    assertion(Prompt.name == review),
    mcp_client_trace(Client3, Trace),
    assertion(trace_sequences(Trace)),
    assertion(trace_has_type(Trace, initialized_negotiated)),
    assertion(trace_has_type(Trace, command_completed)),
    mcp_client_close(Client3, ok(closed)).

test(client_invokes_tool_reads_resource_and_gets_prompt) :-
    connect_fixture(Client0),
    mcp_client_command(Client0,
                       call_tool(lookup, _{query:"hello"}),
                       Client1,
                       ok(ToolResult)),
    ToolResult.content = [Text],
    assertion(Text.text == "tool-ok"),
    assertion(ToolResult.structured.answer == "hello"),
    mcp_client_command(Client1,
                       read_resource("file:///fixture.txt"),
                       Client2,
                       ok(ResourceResult)),
    ResourceResult.contents = [Content],
    assertion(Content.data == "fixture-body"),
    mcp_client_command(Client2,
                       get_prompt(review, _{text:"hello"}),
                       Client3,
                       ok(PromptResult)),
    PromptResult.messages = [Message],
    assertion(Message.role == user),
    assertion(Message.content.text == "review hello"),
    mcp_client_close(Client3, ok(closed)).

test(streamable_http_404_reinitializes_once_and_replays,
     [setup(reset_recovery)]) :-
    client_info(Info),
    client_caps(Caps),
    mcp_client_connect(fixture(streamable_http,
                               plunit_rlm_mcp_runtime:recovery_exchange),
                       Info,
                       Caps,
                       [],
                       ok(Client0)),
    mcp_client_command(Client0, list_tools, Client1, ok(Page)),
    Page.tools = [Tool],
    assertion(Tool.name == recovered),
    assertion(Client1.adapter_state.reinitialize_count =:= 1),
    mcp_client_trace(Client1, Trace),
    assertion(trace_has_type(Trace, session_invalidated)),
    assertion(count_trace_type(Trace, initialized_negotiated, 2)),
    mcp_client_close(Client1, ok(closed)).

test(server_fixture_negotiates_and_dispatches_canonical_commands) :-
    server_info(Info),
    server_caps(Caps),
    mcp_server_new(streamable_http,
                   Info,
                   Caps,
                   [session_id("server-session")],
                   ok(Server0)),
    client_info(ClientInfo),
    client_caps(ClientCaps),
    Init = _{jsonrpc:"2.0",
             id:1,
             method:"initialize",
             params:_{protocolVersion:"2025-11-25",
                      capabilities:ClientCaps,
                      clientInfo:ClientInfo}},
    mcp_server_handle(Server0,
                      Init,
                      _{headers:[]},
                      plunit_rlm_mcp_runtime:server_dispatch,
                      Server1,
                      ok(InitReply)),
    assertion(InitReply.wire.result.protocolVersion == '2025-11-25'),
    OperationMeta = _{headers:['MCP-Protocol-Version'='2025-11-25',
                               'MCP-Session-Id'="server-session"]},
    Initialized = _{jsonrpc:"2.0", method:"notifications/initialized"},
    mcp_server_handle(Server1,
                      Initialized,
                      OperationMeta,
                      plunit_rlm_mcp_runtime:server_dispatch,
                      Server2,
                      ok(_)),
    ListTools = _{jsonrpc:"2.0", id:2, method:"tools/list", params:_{}},
    mcp_server_handle(Server2,
                      ListTools,
                      OperationMeta,
                      plunit_rlm_mcp_runtime:server_dispatch,
                      Server3,
                      ok(Reply)),
    Reply.wire.result.tools = [WireTool],
    assertion(WireTool.name == "lookup"),
    mcp_server_trace(Server3, Trace),
    assertion(trace_has_type(Trace, server_ready)),
    assertion(trace_has_type(Trace, server_command_completed)).

fixture_exchange(Wire, Meta, Response) :-
    get_dict(method, Wire, Method),
    fixture_method(Method, Wire, Meta, Response).

fixture_method("initialize", Wire, _, Response) :-
    assertion(Wire.params.protocolVersion == '2025-11-25'),
    server_info(Info),
    server_caps(Caps),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{protocolVersion:"2025-11-25",
                                   capabilities:Caps,
                                   serverInfo:Info}},
                   headers:transport_headers{'mcp-session-id':"fixture-session"},
                   content_type:'application/json'}.
fixture_method("notifications/initialized", _, Meta, null) :-
    assertion(memberchk('MCP-Protocol-Version'='2025-11-25', Meta.headers)),
    assertion(memberchk('MCP-Session-Id'="fixture-session", Meta.headers)).
fixture_method("tools/list", Wire, Meta, Response) :-
    require_fixture_session(Meta, "fixture-session"),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{tools:[_{name:"lookup",
                                           description:"lookup",
                                           inputSchema:_{type:"object"}}]}},
                   headers:transport_headers{},
                   content_type:'application/json'}.
fixture_method("tools/call", Wire, Meta, Response) :-
    require_fixture_session(Meta, "fixture-session"),
    assertion(Wire.params.name == "lookup"),
    assertion(Wire.params.arguments.query == "hello"),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{content:[_{type:"text", text:"tool-ok"}],
                                   structuredContent:_{answer:"hello"},
                                   isError:false}},
                   headers:transport_headers{},
                   content_type:'application/json'}.
fixture_method("resources/list", Wire, Meta, Response) :-
    require_fixture_session(Meta, "fixture-session"),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{resources:[_{uri:"file:///fixture.txt",
                                               name:"fixture",
                                               mimeType:"text/plain"}]}},
                   headers:transport_headers{},
                   content_type:'application/json'}.
fixture_method("resources/read", Wire, Meta, Response) :-
    require_fixture_session(Meta, "fixture-session"),
    assertion(Wire.params.uri == "file:///fixture.txt"),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{contents:[_{uri:"file:///fixture.txt",
                                              mimeType:"text/plain",
                                              text:"fixture-body"}]}},
                   headers:transport_headers{},
                   content_type:'application/json'}.
fixture_method("prompts/list", Wire, Meta, Response) :-
    require_fixture_session(Meta, "fixture-session"),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{prompts:[_{name:"review",
                                             description:"review prompt"}]}},
                   headers:transport_headers{},
                   content_type:'application/json'}.
fixture_method("prompts/get", Wire, Meta, Response) :-
    require_fixture_session(Meta, "fixture-session"),
    assertion(Wire.params.name == "review"),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{description:"review",
                                   messages:[_{role:"user",
                                               content:_{type:"text",
                                                         text:"review hello"}}]}},
                   headers:transport_headers{},
                   content_type:'application/json'}.

require_fixture_session(Meta, Session) :-
    assertion(memberchk('MCP-Protocol-Version'='2025-11-25', Meta.headers)),
    assertion(memberchk('MCP-Session-Id'=Session, Meta.headers)).

recovery_exchange(Wire, Meta, Response) :-
    get_dict(method, Wire, Method),
    recovery_method(Method, Wire, Meta, Response).

recovery_method("initialize", Wire, _, Response) :-
    retract(recovery_generation(Current)),
    Generation is Current+1,
    assertz(recovery_generation(Generation)),
    format(string(Session), "session-~d", [Generation]),
    server_info(Info),
    server_caps(Caps),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{protocolVersion:"2025-11-25",
                                   capabilities:Caps,
                                   serverInfo:Info}},
                   headers:transport_headers{'mcp-session-id':Session},
                   content_type:'application/json'}.
recovery_method("notifications/initialized", _, _, null).
recovery_method("tools/list", Wire, Meta, Response) :-
    recovery_generation(Generation),
    format(string(Session), "session-~d", [Generation]),
    require_fixture_session(Meta, Session),
    (   Generation =:= 1
    ->  Response = mcp_transport_response{
                       status:404,
                       body:null,
                       headers:transport_headers{},
                       content_type:'application/json'}
    ;   Response = mcp_transport_response{
                       status:200,
                       body:_{jsonrpc:"2.0",
                              id:Wire.id,
                              result:_{tools:[_{name:"recovered",
                                               inputSchema:_{type:"object"}}]}},
                       headers:transport_headers{},
                       content_type:'application/json'}
    ).

server_dispatch(Command, Result) :-
    assertion(Command.op == list_tools),
    Result = mcp_tools_page{
                 tools:[mcp_tool{name:lookup,
                                 title:null,
                                 description:"lookup",
                                 input_schema:mcp_json{type:"object"},
                                 output_schema:none,
                                 annotations:none,
                                 icons:none}],
                 next_cursor:null
             }.

trace_sequences(Trace) :-
    findall(Sequence, (member(Event, Trace), Sequence = Event.sequence), Sequences),
    length(Sequences, Count),
    numlist(1, Count, Sequences).

trace_has_type(Trace, Type) :- member(Event, Trace), Event.type == Type, !.

count_trace_type(Trace, Type, Count) :-
    include(event_type(Type), Trace, Events),
    length(Events, Count).

event_type(Type, Event) :- Event.type == Type.

:- end_tests(rlm_mcp_runtime).
