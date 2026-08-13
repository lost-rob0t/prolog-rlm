:- begin_tests(rlm_mcp_2026).

:- use_module('../prolog/rlm_mcp_v2026_07_28').
:- use_module('../prolog/rlm_mcp_compat').

client_info(_{name:"prolog-rlm-2026-test", version:"1.0"}).
client_caps(_{extensions:_{'io.modelcontextprotocol/tasks':_{}}}).
server_info(_{name:"fixture-2026-server", version:"1.0"}).
server_caps(_{tools:_{listChanged:true},
              resources:_{listChanged:true},
              prompts:_{listChanged:true},
              extensions:_{'io.modelcontextprotocol/tasks':_{}}}).

new_http_client(State) :-
    client_info(Info),
    client_caps(Caps),
    mcp_2026_client_state_new(Info, Caps, streamable_http, ok(State)).

new_http_server(State) :-
    server_info(Info),
    server_caps(Caps),
    mcp_2026_server_state_new(Info, Caps, streamable_http, ok(State)).

discovered_client(State) :-
    new_http_client(State0),
    server_info(Info),
    server_caps(Caps),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:1,
                          result:_{resultType:"complete",
                                   supportedVersions:["2026-07-28"],
                                   capabilities:Caps,
                                   '_meta':_{
                                      'io.modelcontextprotocol/serverInfo':Info}}},
                   headers:transport_headers{},
                   content_type:'application/json'},
    mcp_2026_client_accept_discover(State0, 1, Response, State, ok).

test(discover_request_is_self_describing_and_routed) :-
    new_http_client(State),
    mcp_2026_client_discover(State, 7, Wire, Meta, ok),
    assertion(Wire.jsonrpc == "2.0"),
    assertion(Wire.method == "server/discover"),
    assertion(Wire.params.'_meta'.'io.modelcontextprotocol/protocolVersion' ==
              '2026-07-28'),
    assertion(Wire.params.'_meta'.'io.modelcontextprotocol/clientInfo'.name ==
              "prolog-rlm-2026-test"),
    get_dict(extensions,
             Wire.params.'_meta'.'io.modelcontextprotocol/clientCapabilities',
             Extensions),
    assertion(get_dict('io.modelcontextprotocol/tasks', Extensions, _)),
    assertion(memberchk('MCP-Protocol-Version'='2026-07-28', Meta.headers)),
    assertion(memberchk('Mcp-Method'="server/discover", Meta.headers)),
    assertion(\+ memberchk('MCP-Session-Id'=_, Meta.headers)).

test(discover_response_selects_2026_and_server_capabilities) :-
    discovered_client(State),
    assertion(State.protocol_version == '2026-07-28'),
    assertion(State.supported_versions == ['2026-07-28']),
    assertion(State.server_info.name == "fixture-2026-server"),
    assertion(State.server_capabilities.tools.listChanged == true),
    assertion(\+ get_dict(session_id, State, _)),
    assertion(\+ get_dict(phase, State, _)).

test(tool_call_has_per_request_metadata_and_routing_headers) :-
    discovered_client(State),
    mcp_2026_client_command(State,
                            2,
                            call_tool(lookup, _{query:"hello"}),
                            Wire,
                            Meta,
                            ok(Command)),
    assertion(Command.op == call_tool),
    assertion(Wire.method == "tools/call"),
    assertion(Wire.params.name == "lookup"),
    assertion(Wire.params.'_meta'.'io.modelcontextprotocol/protocolVersion' ==
              '2026-07-28'),
    assertion(memberchk('Mcp-Method'="tools/call", Meta.headers)),
    assertion(memberchk('Mcp-Name'="lookup", Meta.headers)),
    assertion(\+ memberchk('MCP-Session-Id'=_, Meta.headers)).

test(unsafe_routing_name_uses_base64_sentinel) :-
    discovered_client(State),
    mcp_2026_client_command(State,
                            2,
                            call_tool('lookup tool', _{}),
                            _,
                            Meta,
                            ok(_)),
    memberchk('Mcp-Name'=Header, Meta.headers),
    assertion(sub_string(Header, 0, _, _, ":(b64):")).

test(tool_result_requires_result_type_and_preserves_structured_output) :-
    discovered_client(State),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:2,
                          result:_{resultType:"complete",
                                   content:[_{type:"text", text:"ok"}],
                                   structuredContent:_{answer:42},
                                   isError:false}},
                   headers:transport_headers{},
                   content_type:'application/json'},
    mcp_2026_client_decode(State,
                           2,
                           call_tool(lookup, _{}),
                           Response,
                           ok(Result)),
    Result.content = [Content],
    assertion(Content.text == "ok"),
    assertion(Result.structured.answer =:= 42),
    assertion(Result.is_error == false).

test(missing_result_type_fails_closed) :-
    discovered_client(State),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0", id:2, result:_{tools:[]}},
                   headers:transport_headers{},
                   content_type:'application/json'},
    mcp_2026_client_decode(State,
                           2,
                           list_tools,
                           Response,
                           error(Error)),
    assertion(Error.kind == protocol_error).

test(server_discover_is_stateless_and_advertises_versions) :-
    new_http_client(Client),
    mcp_2026_client_discover(Client, 1, Wire, Meta, ok),
    new_http_server(Server),
    mcp_2026_server_receive(Server,
                            Wire,
                            Meta,
                            discover(1, _, _),
                            ok(Server1)),
    assertion(Server1 == Server),
    mcp_2026_server_discover_response(Server1,
                                      1,
                                      Reply,
                                      ReplyMeta,
                                      ok),
    assertion(Reply.result.resultType == "complete"),
    assertion(memberchk('2026-07-28', Reply.result.supportedVersions)),
    assertion(memberchk('2025-11-25', Reply.result.supportedVersions)),
    assertion(ReplyMeta.headers == []),
    assertion(\+ get_dict(session_id, Server1, _)).

test(server_command_decodes_without_persisting_client_state) :-
    new_http_client(Client),
    mcp_2026_client_command(Client, 9, list_tools, Wire, Meta, ok(_)),
    new_http_server(Server),
    mcp_2026_server_receive(Server,
                            Wire,
                            Meta,
                            command(9, Command),
                            ok(Server1)),
    assertion(Command.op == list_tools),
    assertion(Server1 == Server),
    assertion(\+ get_dict(client_info, Server1, _)).

test(header_body_protocol_mismatch_uses_standard_error) :-
    new_http_client(Client),
    mcp_2026_client_command(Client, 3, list_tools, Wire, Meta0, ok(_)),
    select('MCP-Protocol-Version'='2026-07-28',
           Meta0.headers,
           'MCP-Protocol-Version'='2025-11-25',
           Headers),
    put_dict(headers, Meta0, Headers, Meta),
    new_http_server(Server),
    mcp_2026_server_receive(Server,
                            Wire,
                            Meta,
                            _,
                            error(Error)),
    assertion(Error.kind == header_mismatch),
    assertion(Error.jsonrpc_code =:= -32020),
    mcp_2026_server_error_reply(3, Error, Reply, Status),
    assertion(Status =:= 400),
    assertion(Reply.error.code =:= -32020).

test(unsupported_protocol_version_advertises_supported_versions) :-
    new_http_client(Client),
    mcp_2026_client_command(Client, 4, list_tools, Wire0, Meta0, ok(_)),
    MetaBody0 = Wire0.params.'_meta',
    put_dict('io.modelcontextprotocol/protocolVersion',
             MetaBody0,
             '2099-01-01',
             MetaBody),
    put_dict('_meta', Wire0.params, MetaBody, Params),
    put_dict(params, Wire0, Params, Wire),
    select('MCP-Protocol-Version'='2026-07-28',
           Meta0.headers,
           'MCP-Protocol-Version'='2099-01-01',
           Headers),
    put_dict(headers, Meta0, Headers, Meta),
    new_http_server(Server),
    mcp_2026_server_receive(Server,
                            Wire,
                            Meta,
                            _,
                            error(Error)),
    assertion(Error.kind == unsupported_protocol_version),
    assertion(Error.jsonrpc_code =:= -32022),
    assertion(memberchk('2026-07-28', Error.supported)),
    assertion(memberchk('2025-11-25', Error.supported)).

test(compatibility_cache_stale_generation_is_invalidated,
     [setup(mcp_compat_cache_clear), cleanup(mcp_compat_cache_clear)]) :-
    Endpoint = endpoint_fixture,
    mcp_compat_cache_store(Endpoint,
                           streamable_http,
                           ['2025-11-25', '2026-07-28'],
                           '2026-07-28',
                           discovery,
                           1,
                           ok(_)),
    mcp_compat_cache_lookup(Endpoint,
                            streamable_http,
                            2,
                            8,
                            ok(Entry)),
    assertion(Entry.selected == '2026-07-28'),
    mcp_compat_cache_lookup(Endpoint,
                            streamable_http,
                            20,
                            8,
                            miss),
    mcp_compat_cache_lookup(Endpoint,
                            streamable_http,
                            20,
                            8,
                            miss).

test(compatibility_cache_malformed_entry_fails_closed,
     [setup(mcp_compat_cache_clear), cleanup(mcp_compat_cache_clear)]) :-
    assertz(rlm_mcp_compat:compatibility_entry(bad,
                                               _{transport:streamable_http})),
    mcp_compat_cache_lookup(bad,
                            streamable_http,
                            1,
                            8,
                            miss),
    assertion(\+ rlm_mcp_compat:compatibility_entry(bad, _)).

:- end_tests(rlm_mcp_2026).
