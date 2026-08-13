:- begin_tests(rlm_mcp_dual).

:- use_module('../prolog/rlm_mcp').
:- use_module('../prolog/rlm_mcp_compat').
:- use_module('../prolog/rlm_mcp_v2026_07_28').

:- dynamic fallback_phase/1.

client_info(_{name:"dual-client", version:"1.0"}).
client_caps(_{}).
server_info(_{name:"dual-server", version:"1.0"}).
server_caps(_{tools:_{listChanged:false},
              resources:_{listChanged:false},
              prompts:_{listChanged:false}}).

setup_dual :-
    mcp_compat_cache_clear,
    retractall(fallback_phase(_)),
    assertz(fallback_phase(modern)).

connect(Handler, Client) :-
    client_info(Info),
    client_caps(Caps),
    mcp_client_connect(fixture(streamable_http, Handler),
                       Info,
                       Caps,
                       [cache_max_age(0)],
                       ok(Client)).

test(client_to_2026_only_server_uses_stateless_path,
     [setup(setup_dual), cleanup(mcp_compat_cache_clear)]) :-
    connect(plunit_rlm_mcp_dual:only_2026_exchange, Client0),
    mcp_client_protocol(Client0, '2026-07-28'),
    assertion(\+ get_dict(session_id, Client0.adapter_state, _)),
    mcp_client_command(Client0, list_tools, Client1, ok(Page)),
    Page.tools = [Tool],
    assertion(Tool.name == modern),
    mcp_client_trace(Client1, Trace),
    assertion(trace_has_type(Trace, discover_sent)),
    assertion(trace_has_protocol(Trace, '2026-07-28')),
    mcp_client_close(Client1, ok(closed)).

test(client_to_2025_only_server_falls_back_to_initialize,
     [setup(setup_dual), cleanup(mcp_compat_cache_clear)]) :-
    connect(plunit_rlm_mcp_dual:only_2025_exchange, Client0),
    mcp_client_protocol(Client0, '2025-11-25'),
    mcp_client_command(Client0, list_tools, Client1, ok(Page)),
    Page.tools = [Tool],
    assertion(Tool.name == legacy),
    mcp_client_trace(Client1, Trace),
    assertion(trace_has_type(Trace, protocol_fallback)),
    assertion(trace_has_type(Trace, initialized_negotiated)),
    mcp_client_close(Client1, ok(closed)).

test(client_to_dual_server_prefers_2026,
     [setup(setup_dual), cleanup(mcp_compat_cache_clear)]) :-
    connect(plunit_rlm_mcp_dual:dual_exchange, Client),
    mcp_client_protocol(Client, '2026-07-28'),
    mcp_client_trace(Client, Trace),
    assertion(trace_has_type(Trace, protocol_selected)),
    assertion(\+ trace_has_type(Trace, initialize_sent)),
    mcp_client_close(Client, ok(closed)).

test(unsupported_version_command_falls_back_once_to_2025,
     [setup(setup_dual), cleanup(mcp_compat_cache_clear)]) :-
    connect(plunit_rlm_mcp_dual:fallback_exchange, Client0),
    mcp_client_protocol(Client0, '2026-07-28'),
    mcp_client_command(Client0, list_tools, Client1, ok(Page)),
    mcp_client_protocol(Client1, '2025-11-25'),
    Page.tools = [Tool],
    assertion(Tool.name == fallback_legacy),
    assertion(Client1.protocol_retry_count =:= 1),
    mcp_client_trace(Client1, Trace),
    assertion(count_trace_type(Trace, protocol_fallback, 1)),
    assertion(trace_has_type(Trace, protocol_rejected)),
    mcp_client_close(Client1, ok(closed)).

test(dual_server_accepts_2026_discover_and_command) :-
    server_info(ServerInfo),
    server_caps(ServerCaps),
    mcp_server_new(streamable_http,
                   ServerInfo,
                   ServerCaps,
                   [session_id("legacy-session")],
                   ok(Server0)),
    client_info(ClientInfo),
    client_caps(ClientCaps),
    mcp_2026_client_state_new(ClientInfo,
                              ClientCaps,
                              streamable_http,
                              ok(ClientState)),
    mcp_2026_client_discover(ClientState, 1, Discover, DiscoverMeta, ok),
    mcp_server_handle(Server0,
                      Discover,
                      DiscoverMeta,
                      plunit_rlm_mcp_dual:server_dispatch,
                      Server1,
                      ok(DiscoverReply)),
    assertion(DiscoverReply.wire.result.resultType == "complete"),
    mcp_2026_client_command(ClientState,
                            2,
                            list_tools,
                            ListTools,
                            OperationMeta,
                            ok(_)),
    mcp_server_handle(Server1,
                      ListTools,
                      OperationMeta,
                      plunit_rlm_mcp_dual:server_dispatch,
                      Server2,
                      ok(Reply)),
    assertion(Reply.wire.result.resultType == "complete"),
    Reply.wire.result.tools = [WireTool],
    assertion(WireTool.name == "server_tool"),
    mcp_server_trace(Server2, Trace),
    assertion(trace_has_type(Trace, server_discovered)),
    assertion(trace_has_protocol(Trace, '2026-07-28')).

test(time_limit_exception_propagates_through_server,
     [throws(time_limit_exceeded)]) :-
    server_info(ServerInfo),
    server_caps(ServerCaps),
    mcp_server_new(streamable_http,
                   ServerInfo,
                   ServerCaps,
                   [],
                   ok(Server0)),
    client_info(ClientInfo),
    client_caps(ClientCaps),
    mcp_2026_client_state_new(ClientInfo,
                              ClientCaps,
                              streamable_http,
                              ok(ClientState)),
    mcp_2026_client_command(ClientState,
                            1,
                            list_tools,
                            Wire,
                            Meta,
                            ok(_)),
    mcp_server_handle(Server0,
                      Wire,
                      Meta,
                      plunit_rlm_mcp_dual:throw_time_limit,
                      _,
                      _).

only_2026_exchange(Wire, Meta, Response) :-
    get_dict(method, Wire, Method),
    modern_method(Method, Wire, Meta, ["2026-07-28"], modern, Response).

only_2025_exchange(Wire, Meta, Response) :-
    get_dict(method, Wire, Method),
    legacy_method(Method, Wire, Meta, Response).

only_2025_exchange(Wire, _, Response) :-
    get_dict(method, Wire, "server/discover"),
    Response = mcp_transport_response{
                   status:404,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          error:_{code: -32601,
                                  message:"Method not found"}},
                   headers:transport_headers{},
                   content_type:'application/json'}.

dual_exchange(Wire, Meta, Response) :-
    get_dict(method, Wire, Method),
    modern_method(Method,
                  Wire,
                  Meta,
                  ["2026-07-28", "2025-11-25"],
                  dual,
                  Response).

fallback_exchange(Wire, Meta, Response) :-
    get_dict(method, Wire, Method),
    fallback_method(Method, Wire, Meta, Response).

fallback_method("server/discover", Wire, Meta, Response) :-
    modern_method("server/discover",
                  Wire,
                  Meta,
                  ["2026-07-28", "2025-11-25"],
                  ignored,
                  Response).
fallback_method("tools/list", Wire, Meta, Response) :-
    fallback_phase(Phase),
    (   Phase == modern
    ->  require_modern_meta(Wire, Meta),
        retractall(fallback_phase(_)),
        assertz(fallback_phase(legacy_init)),
        Response = mcp_transport_response{
                       status:400,
                       body:_{jsonrpc:"2.0",
                              id:Wire.id,
                              error:_{code: -32022,
                                      message:"Unsupported protocol version",
                                      data:_{supported:["2025-11-25"],
                                             requested:"2026-07-28"}}},
                       headers:transport_headers{},
                       content_type:'application/json'}
    ;   Phase == legacy_ready,
        require_legacy_meta(Meta),
        Response = legacy_tools_response(Wire.id, fallback_legacy)
    ).
fallback_method("initialize", Wire, _, Response) :-
    fallback_phase(legacy_init),
    retractall(fallback_phase(_)),
    assertz(fallback_phase(legacy_initialized)),
    legacy_initialize_response(Wire, Response).
fallback_method("notifications/initialized", _, Meta, null) :-
    fallback_phase(legacy_initialized),
    require_legacy_meta(Meta),
    retractall(fallback_phase(_)),
    assertz(fallback_phase(legacy_ready)).

modern_method("server/discover", Wire, Meta, Versions, _, Response) :-
    require_modern_meta(Wire, Meta),
    server_info(Info),
    server_caps(Caps),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{resultType:"complete",
                                   supportedVersions:Versions,
                                   capabilities:Caps,
                                   '_meta':_{
                                      'io.modelcontextprotocol/serverInfo':Info}}},
                   headers:transport_headers{},
                   content_type:'application/json'}.
modern_method("tools/list", Wire, Meta, _, ToolName, Response) :-
    require_modern_meta(Wire, Meta),
    atom_string(ToolName, ToolText),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{resultType:"complete",
                                   tools:[_{name:ToolText,
                                            inputSchema:_{type:"object"}}]}},
                   headers:transport_headers{},
                   content_type:'application/json'}.

legacy_method("server/discover", Wire, _, Response) :-
    Response = mcp_transport_response{
                   status:404,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          error:_{code: -32601,
                                  message:"Method not found"}},
                   headers:transport_headers{},
                   content_type:'application/json'}.
legacy_method("initialize", Wire, _, Response) :-
    legacy_initialize_response(Wire, Response).
legacy_method("notifications/initialized", _, Meta, null) :-
    require_legacy_meta(Meta).
legacy_method("tools/list", Wire, Meta, Response) :-
    require_legacy_meta(Meta),
    Response = legacy_tools_response(Wire.id, legacy).

legacy_initialize_response(Wire,
                           mcp_transport_response{
                               status:200,
                               body:_{jsonrpc:"2.0",
                                      id:Wire.id,
                                      result:_{protocolVersion:"2025-11-25",
                                               capabilities:Caps,
                                               serverInfo:Info}},
                               headers:transport_headers{
                                          'mcp-session-id':"legacy-session"},
                               content_type:'application/json'}) :-
    server_info(Info),
    server_caps(Caps).

legacy_tools_response(Id, ToolName,
                      mcp_transport_response{
                          status:200,
                          body:_{jsonrpc:"2.0",
                                 id:Id,
                                 result:_{tools:[_{name:ToolText,
                                                  inputSchema:_{type:"object"}}]}},
                          headers:transport_headers{},
                          content_type:'application/json'}) :-
    atom_string(ToolName, ToolText).

legacy_tools_response(Id, ToolName, Response) :-
    legacy_tools_response(Id, ToolName, Response).

require_modern_meta(Wire, Meta) :-
    assertion(Wire.params.'_meta'.'io.modelcontextprotocol/protocolVersion' ==
              '2026-07-28'),
    assertion(memberchk('MCP-Protocol-Version'='2026-07-28', Meta.headers)),
    assertion(memberchk('Mcp-Method'=Wire.method, Meta.headers)),
    assertion(\+ memberchk('MCP-Session-Id'=_, Meta.headers)).

require_legacy_meta(Meta) :-
    assertion(memberchk('MCP-Protocol-Version'='2025-11-25', Meta.headers)),
    assertion(memberchk('MCP-Session-Id'="legacy-session", Meta.headers)).

server_dispatch(Command, Result) :-
    assertion(Command.op == list_tools),
    Result = mcp_tools_page{
                 tools:[mcp_tool{name:server_tool,
                                 title:null,
                                 description:null,
                                 input_schema:mcp_json{type:"object"},
                                 output_schema:none,
                                 annotations:none,
                                 icons:none}],
                 next_cursor:null
             }.

throw_time_limit(_, _) :- throw(time_limit_exceeded).

trace_has_type(Trace, Type) :-
    member(Event, Trace), Event.type == Type, !.

trace_has_protocol(Trace, Protocol) :-
    member(Event, Trace), Event.protocol_version == Protocol, !.

count_trace_type(Trace, Type, Count) :-
    include(event_type(Type), Trace, Events),
    length(Events, Count).

event_type(Type, Event) :- Event.type == Type.

:- end_tests(rlm_mcp_dual).
