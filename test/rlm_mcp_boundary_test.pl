:- begin_tests(rlm_mcp_boundary).

:- use_module(library(readutil)).
:- use_module('../prolog/rlm_mcp').
:- use_module('../prolog/rlm_mcp_v2025_11_25').

client_info(_{name:"stdio-client", version:"1.0"}).
client_caps(_{roots:_{listChanged:false}}).
server_info(_{name:"stdio-server", version:"1.0"}).
server_caps(_{tools:_{listChanged:false}}).

test(stdio_fixture_negotiates_without_http_metadata) :-
    client_info(Info),
    client_caps(Caps),
    mcp_client_connect(fixture(stdio,
                               plunit_rlm_mcp_boundary:stdio_fixture),
                       Info,
                       Caps,
                       [],
                       ok(Client0)),
    mcp_client_command(Client0, list_tools, Client1, ok(Page)),
    Page.tools = [Tool],
    assertion(Tool.name == stdio_lookup),
    mcp_client_close(Client1, ok(closed)).

test(response_id_mismatch_fails_closed) :-
    client_info(Info),
    client_caps(ClientCaps),
    mcp_2025_client_state_new(Info, ClientCaps, stdio, ok(State0)),
    server_info(ServerInfo),
    server_caps(ServerCaps),
    InitResponse = mcp_transport_response{
                       status:200,
                       body:_{jsonrpc:"2.0",
                              id:1,
                              result:_{protocolVersion:"2025-11-25",
                                       capabilities:ServerCaps,
                                       serverInfo:ServerInfo}},
                       headers:transport_headers{},
                       content_type:'application/json'},
    mcp_2025_client_accept_initialize(State0, 1, InitResponse, Pending, ok),
    mcp_2025_client_initialized(Pending, _, _, ok(Ready)),
    BadResponse = mcp_transport_response{
                      status:200,
                      body:_{jsonrpc:"2.0",
                             id:999,
                             result:_{tools:[]}},
                      headers:transport_headers{},
                      content_type:'application/json'},
    mcp_2025_client_decode(Ready,
                           2,
                           list_tools,
                           BadResponse,
                           error(Error)),
    assertion(Error.kind == protocol_error),
    assertion(Error.detail == response_id_mismatch(2, 999)).

test(canonical_notification_decodes_without_wire_leakage) :-
    client_info(Info),
    client_caps(ClientCaps),
    mcp_2025_client_state_new(Info, ClientCaps, stdio, ok(State0)),
    server_info(ServerInfo),
    server_caps(ServerCaps),
    InitResponse = mcp_transport_response{
                       status:200,
                       body:_{jsonrpc:"2.0",
                              id:1,
                              result:_{protocolVersion:"2025-11-25",
                                       capabilities:ServerCaps,
                                       serverInfo:ServerInfo}},
                       headers:transport_headers{},
                       content_type:'application/json'},
    mcp_2025_client_accept_initialize(State0, 1, InitResponse, Pending, ok),
    mcp_2025_client_initialized(Pending, _, _, ok(Ready)),
    Wire = _{jsonrpc:"2.0",
             method:"notifications/tools/list_changed"},
    mcp_2025_client_notification(Ready, Wire, ok(Notification)),
    assertion(Notification.type == tools_list_changed),
    term_string(Notification, Text),
    assertion(\+ sub_string(Text, _, _, _, "notifications/")),
    assertion(\+ sub_string(Text, _, _, _, "2025-11-25")).

test(canonical_runtime_layers_have_no_protocol_version_branching) :-
    forall(member(Path,
                  ['../prolog/rlm_agent.pl',
                   '../prolog/rlm_graph.pl',
                   '../prolog/rlm_chain.pl',
                   '../prolog/rlm_completion.pl',
                   '../prolog/rlm_plan.pl']),
           assert_no_protocol_leak(Path)).

stdio_fixture(Wire, Meta, Response) :-
    assertion(Meta.headers == []),
    get_dict(method, Wire, Method),
    stdio_method(Method, Wire, Response).

stdio_method("server/discover", Wire, Response) :-
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          error:_{code: -32601,
                                  message:"Method not found"}},
                   headers:transport_headers{},
                   content_type:'application/json'}.
stdio_method("initialize", Wire, Response) :-
    server_info(ServerInfo),
    server_caps(ServerCaps),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{protocolVersion:"2025-11-25",
                                   capabilities:ServerCaps,
                                   serverInfo:ServerInfo}},
                   headers:transport_headers{},
                   content_type:'application/json'}.
stdio_method("notifications/initialized", _, null).
stdio_method("tools/list", Wire, Response) :-
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{tools:[_{name:"stdio_lookup",
                                           inputSchema:_{type:"object"}}]}},
                   headers:transport_headers{},
                   content_type:'application/json'}.

assert_no_protocol_leak(Path) :-
    read_file_to_string(Path, Text, []),
    forall(member(Needle,
                  ["2025-11-25",
                   "2026-07-28",
                   "server/discover",
                   "tools/list",
                   "tools/call",
                   "resources/list",
                   "resources/read",
                   "prompts/list",
                   "prompts/get",
                   "MCP-Protocol-Version",
                   "MCP-Session-Id",
                   "Mcp-Method",
                   "Mcp-Name",
                   "jsonrpc"]),
           assertion(\+ sub_string(Text, _, _, _, Needle))).

:- end_tests(rlm_mcp_boundary).
