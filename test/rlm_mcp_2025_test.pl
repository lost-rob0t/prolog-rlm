:- begin_tests(rlm_mcp_2025).

:- use_module('../prolog/rlm_mcp_v2025_11_25').

client_info(_{name:"prolog-rlm-test", version:"1.0"}).
client_caps(_{roots:_{listChanged:false}}).
server_info(_{name:"fixture-server", version:"1.0"}).
server_caps(_{tools:_{listChanged:true},
              resources:_{subscribe:false, listChanged:true},
              prompts:_{listChanged:true}}).

new_http_client(State) :-
    client_info(Info),
    client_caps(Caps),
    mcp_2025_client_state_new(Info, Caps, streamable_http, ok(State)).

initialized_http_client(State) :-
    new_http_client(State0),
    mcp_2025_client_initialize(State0, 1, _, _, ok),
    server_info(ServerInfo),
    server_caps(ServerCaps),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:1,
                          result:_{protocolVersion:"2025-11-25",
                                   capabilities:ServerCaps,
                                   serverInfo:ServerInfo}},
                   headers:transport_headers{'mcp-session-id':"session-1"},
                   content_type:'application/json'
               },
    mcp_2025_client_accept_initialize(State0, 1, Response, Pending, ok),
    mcp_2025_client_initialized(Pending, _, _, ReadyOutcome),
    (   ReadyOutcome = ok(State0Ready),
        is_dict(State0Ready, mcp_2025_client),
        State0Ready.phase == ready
    ->  State = State0Ready
    ;   put_dict(phase, Pending, ready, State)
    ).

test(initialize_wire_and_metadata) :-
    new_http_client(State),
    mcp_2025_client_initialize(State, 7, Wire, Meta, ok),
    assertion(Wire.jsonrpc == "2.0"),
    assertion(Wire.id =:= 7),
    assertion(Wire.method == "initialize"),
    assertion(Wire.params.protocolVersion == '2025-11-25'),
    assertion(Wire.params.clientInfo.name == "prolog-rlm-test"),
    assertion(\+ memberchk('MCP-Protocol-Version'=_, Meta.headers)),
    assertion(memberchk('Accept'='application/json, text/event-stream',
                        Meta.headers)).

test(accept_initialize_negotiates_session_and_capabilities) :-
    new_http_client(State0),
    server_info(ServerInfo),
    server_caps(ServerCaps),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:1,
                          result:_{protocolVersion:"2025-11-25",
                                   capabilities:ServerCaps,
                                   serverInfo:ServerInfo}},
                   headers:transport_headers{'mcp-session-id':"abc"},
                   content_type:'application/json'
               },
    mcp_2025_client_accept_initialize(State0, 1, Response, State, ok),
    assertion(State.phase == initialized_pending),
    assertion(State.protocol_version == '2025-11-25'),
    assertion(State.session_id == "abc"),
    assertion(State.server_capabilities.tools.listChanged == true).

test(operation_metadata_has_version_and_session_headers) :-
    initialized_http_client(State),
    mcp_2025_client_command(State,
                            2,
                            list_tools,
                            Wire,
                            Meta,
                            ok(Command)),
    assertion(Command.op == list_tools),
    assertion(Wire.method == "tools/list"),
    assertion(memberchk('MCP-Protocol-Version'='2025-11-25', Meta.headers)),
    assertion(memberchk('MCP-Session-Id'="session-1", Meta.headers)).

test(tool_result_decodes_to_canonical_terms) :-
    initialized_http_client(State),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:2,
                          result:_{tools:[_{name:"lookup",
                                           description:"lookup",
                                           inputSchema:_{type:"object"}}]}},
                   headers:transport_headers{},
                   content_type:'application/json'
               },
    mcp_2025_client_decode(State, list_tools, Response, ok(Page)),
    Page.tools = [Tool],
    assertion(Tool.name == lookup),
    assertion(Page.next_cursor == null).

test(tool_call_result_decodes_content_and_structured_output) :-
    initialized_http_client(State),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:3,
                          result:_{content:[_{type:"text", text:"ok"}],
                                   structuredContent:_{answer:42},
                                   isError:false}},
                   headers:transport_headers{},
                   content_type:'application/json'
               },
    mcp_2025_client_decode(State,
                           call_tool(lookup, _{}),
                           Response,
                           ok(Result)),
    Result.content = [Content],
    assertion(Content.type == text),
    assertion(Content.text == "ok"),
    assertion(Result.structured.answer =:= 42),
    assertion(Result.is_error == false).

test(session_404_recovery_is_bounded) :-
    initialized_http_client(State0),
    mcp_2025_client_recover_404(State0, ok(State1)),
    assertion(State1.phase == new),
    assertion(State1.session_id == null),
    assertion(State1.reinitialize_count =:= 1),
    put_dict(_{phase:ready,
               session_id:"session-2",
               protocol_version:'2025-11-25'},
             State1,
             State2),
    mcp_2025_client_recover_404(State2, error(Error)),
    assertion(Error.kind == reinitialize_exhausted).

test(server_lifecycle_and_command_decode) :-
    server_info(Info),
    server_caps(Caps),
    mcp_2025_server_state_new(Info,
                              Caps,
                              streamable_http,
                              "server-session",
                              ok(Server0)),
    client_info(ClientInfo),
    client_caps(ClientCaps),
    Init = _{jsonrpc:"2.0",
             id:1,
             method:"initialize",
             params:_{protocolVersion:"2025-11-25",
                      capabilities:ClientCaps,
                      clientInfo:ClientInfo}},
    mcp_2025_server_receive(Server0,
                            Init,
                            _{headers:[]},
                            initialize(1, _, _),
                            ok(Server1)),
    mcp_2025_server_initialize_response(Server1,
                                        1,
                                        InitReply,
                                        ReplyMeta,
                                        ok),
    assertion(InitReply.result.protocolVersion == '2025-11-25'),
    assertion(memberchk('MCP-Session-Id'="server-session",
                        ReplyMeta.headers)),
    OpMeta = _{headers:['MCP-Protocol-Version'='2025-11-25',
                        'MCP-Session-Id'="server-session"]},
    Initialized = _{jsonrpc:"2.0", method:"notifications/initialized"},
    mcp_2025_server_receive(Server1,
                            Initialized,
                            OpMeta,
                            initialized,
                            ok(Server2)),
    ListTools = _{jsonrpc:"2.0",
                  id:2,
                  method:"tools/list",
                  params:_{}},
    mcp_2025_server_receive(Server2,
                            ListTools,
                            OpMeta,
                            command(2, Command),
                            ok(Server3)),
    assertion(Command.op == list_tools),
    assertion(Server3.phase == ready).

test(server_rejects_missing_protocol_header_after_initialize) :-
    server_info(Info),
    server_caps(Caps),
    mcp_2025_server_state_new(Info, Caps, streamable_http, null, ok(Server0)),
    put_dict(_{phase:ready, protocol_version:'2025-11-25'}, Server0, Ready),
    Wire = _{jsonrpc:"2.0", id:1, method:"tools/list", params:_{}},
    mcp_2025_server_receive(Ready,
                            Wire,
                            _{headers:[]},
                            _,
                            error(Error)),
    assertion(Error.kind == protocol_error).

:- end_tests(rlm_mcp_2025).
