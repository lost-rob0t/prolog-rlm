:- begin_tests(rlm_mcp_2026_matrix).

:- use_module('../prolog/rlm_mcp').
:- use_module('../prolog/rlm_mcp_compat').
:- use_module('../prolog/rlm_mcp_v2026_07_28').

:- dynamic cache_fixture_phase/1.

client_info(_{name:"matrix-client", version:"1.0"}).
client_caps(_{roots:_{listChanged:false}}).
server_info(_{name:"matrix-server", version:"1.0"}).
server_caps(_{tools:_{listChanged:true},
              resources:_{listChanged:true},
              prompts:_{listChanged:true}}).

new_client(State) :-
    client_info(Info),
    client_caps(Caps),
    mcp_2026_client_state_new(Info, Caps, streamable_http, ok(State)).

new_server(State) :-
    server_info(Info),
    server_caps(Caps),
    mcp_2026_server_state_new(Info, Caps, streamable_http, ok(State)).

discovery_response(Id, Versions, Capabilities,
                   mcp_transport_response{
                       status:200,
                       body:_{jsonrpc:"2.0",
                              id:Id,
                              result:_{resultType:"complete",
                                       supportedVersions:Versions,
                                       capabilities:Capabilities,
                                       '_meta':_{
                                          'io.modelcontextprotocol/serverInfo':Info}}},
                       headers:transport_headers{},
                       content_type:'application/json'}) :-
    server_info(Info).

response(Id, Result,
         mcp_transport_response{
             status:200,
             body:_{jsonrpc:"2.0", id:Id, result:Result},
             headers:transport_headers{},
             content_type:'application/json'}).

test(all_canonical_commands_encode_to_2026_wire_methods) :-
    new_client(State),
    Cases = [ list_tools-"tools/list"-none,
              call_tool(fetch, _{})-"tools/call"-"fetch",
              list_resources-"resources/list"-none,
              read_resource("file:///matrix")-"resources/read"-"file:///matrix",
              list_prompts-"prompts/list"-none,
              get_prompt(welcome, _{})-"prompts/get"-"welcome"
            ],
    forall(nth1(Id, Cases, Command-Method-NameHeader),
           ( mcp_2026_client_command(State,
                                     Id,
                                     Command,
                                     Wire,
                                     Meta,
                                     ok(_)),
             assertion(Wire.method == Method),
             assertion(memberchk('Mcp-Method'=Method, Meta.headers)),
             assert_name_header(NameHeader, Meta.headers),
             assertion(\+ memberchk('MCP-Session-Id'=_, Meta.headers)) )).

test(all_canonical_result_families_decode) :-
    new_client(State),
    response(1,
             _{resultType:"complete",
               tools:[_{name:"lookup", inputSchema:_{type:"object"}}]},
             ToolsResponse),
    mcp_2026_client_decode(State, 1, list_tools, ToolsResponse, ok(ToolsPage)),
    ToolsPage.tools = [Tool],
    assertion(Tool.name == lookup),

    response(2,
             _{resultType:"complete",
               content:[_{type:"text", text:"done"}],
               structuredContent:_{answer:42},
               isError:false},
             ToolResponse),
    mcp_2026_client_decode(State,
                           2,
                           call_tool(lookup, _{}),
                           ToolResponse,
                           ok(ToolResult)),
    assertion(ToolResult.structured.answer =:= 42),

    response(3,
             _{resultType:"complete",
               resources:[_{uri:"file:///matrix",
                            name:"matrix",
                            mimeType:"text/plain"}]},
             ResourcesResponse),
    mcp_2026_client_decode(State,
                           3,
                           list_resources,
                           ResourcesResponse,
                           ok(ResourcesPage)),
    ResourcesPage.resources = [Resource],
    assertion(Resource.uri == "file:///matrix"),

    response(4,
             _{resultType:"complete",
               contents:[_{uri:"file:///matrix",
                           mimeType:"text/plain",
                           text:"payload"}]},
             ReadResponse),
    mcp_2026_client_decode(State,
                           4,
                           read_resource("file:///matrix"),
                           ReadResponse,
                           ok(ReadResult)),
    ReadResult.contents = [ResourceContent],
    assertion(ResourceContent.data == "payload"),

    response(5,
             _{resultType:"complete",
               prompts:[_{name:"welcome", description:"hello"}]},
             PromptsResponse),
    mcp_2026_client_decode(State,
                           5,
                           list_prompts,
                           PromptsResponse,
                           ok(PromptsPage)),
    PromptsPage.prompts = [Prompt],
    assertion(Prompt.name == welcome),

    response(6,
             _{resultType:"complete",
               description:"hello",
               messages:[_{role:"user",
                           content:_{type:"text", text:"hi"}}]},
             PromptResponse),
    mcp_2026_client_decode(State,
                           6,
                           get_prompt(welcome, _{}),
                           PromptResponse,
                           ok(PromptResult)),
    PromptResult.messages = [Message],
    assertion(Message.role == user),
    assertion(Message.content.text == "hi").

test(server_decodes_every_canonical_operation_without_session_state) :-
    new_client(Client),
    new_server(Server),
    Commands = [list_tools,
                call_tool(fetch, _{}),
                list_resources,
                read_resource("file:///matrix"),
                list_prompts,
                get_prompt(welcome, _{})],
    forall(nth1(Id, Commands, Command0),
           ( mcp_2026_client_command(Client,
                                     Id,
                                     Command0,
                                     Wire,
                                     Meta,
                                     ok(Expected)),
             mcp_2026_server_receive(Server,
                                     Wire,
                                     Meta,
                                     command(Id, Actual),
                                     ok(Server1)),
             assertion(Actual == Expected),
             assertion(Server1 == Server),
             assertion(\+ get_dict(session_id, Server1, _)) )).

test(discovery_rejects_malformed_capability_advertisement) :-
    new_client(State0),
    discovery_response(1, ["2026-07-28"], "not-an-object", Response),
    mcp_2026_client_accept_discover(State0,
                                    1,
                                    Response,
                                    _,
                                    error(Error)),
    assertion(Error.kind == protocol_error),
    assertion(Error.detail = canonical_error(_)).

test(discovery_version_mismatch_fails_closed_with_supported_versions) :-
    new_client(State0),
    server_caps(Caps),
    discovery_response(1, ["2025-11-25"], Caps, Response),
    mcp_2026_client_accept_discover(State0,
                                    1,
                                    Response,
                                    _,
                                    error(Error)),
    assertion(Error.kind == unsupported_protocol_version),
    assertion(Error.requested == '2026-07-28'),
    assertion(Error.supported == ['2025-11-25']).

test(malformed_unsupported_version_response_does_not_trigger_version_selection) :-
    new_client(State),
    Response = mcp_transport_response{
                   status:400,
                   body:_{jsonrpc:"2.0",
                          id:1,
                          error:_{code: -32022,
                                  message:"Unsupported protocol version",
                                  data:_{supported:"broken",
                                         requested:"2026-07-28"}}},
                   headers:transport_headers{},
                   content_type:'application/json'},
    mcp_2026_client_decode(State,
                           1,
                           list_tools,
                           Response,
                           error(Error)),
    assertion(Error.kind == protocol_error),
    assertion(\+ get_dict(supported, Error, _)).

test(response_id_mismatch_fails_closed) :-
    new_client(State),
    response(999, _{resultType:"complete", tools:[]}, Response),
    mcp_2026_client_decode(State,
                           1,
                           list_tools,
                           Response,
                           error(Error)),
    assertion(Error.kind == protocol_error),
    assertion(Error.detail == response_id_mismatch(1, 999)).

test(streamable_http_requires_matching_protocol_routing_metadata) :-
    new_client(Client),
    mcp_2026_client_command(Client, 1, list_tools, Wire, _, ok(_)),
    new_server(Server),
    MissingMeta = mcp_transport_request{
                      headers:[],
                      protocol_version:'2026-07-28',
                      transport:streamable_http},
    mcp_2026_server_receive(Server,
                            Wire,
                            MissingMeta,
                            _,
                            error(Error)),
    assertion(Error.kind == header_mismatch),
    assertion(Error.jsonrpc_code =:= -32020).

test(successful_discovery_refreshes_cache_and_next_connect_skips_discovery,
     [ setup((mcp_compat_cache_clear,
              retractall(cache_fixture_phase(_)),
              assertz(cache_fixture_phase(expect_discover)))),
       cleanup((mcp_compat_cache_clear,
                retractall(cache_fixture_phase(_))))
     ]) :-
    client_info(Info),
    client_caps(Caps),
    Spec = fixture(streamable_http,
                   plunit_rlm_mcp_2026_matrix:cache_fixture),
    mcp_client_connect(Spec, Info, Caps, [], ok(Client0)),
    mcp_client_protocol(Client0, '2026-07-28'),
    mcp_client_close(Client0, ok(closed)),
    assertion(cache_fixture_phase(expect_command)),

    mcp_client_connect(Spec, Info, Caps, [], ok(Client1)),
    mcp_client_protocol(Client1, '2026-07-28'),
    mcp_client_command(Client1, list_tools, Client2, ok(Page)),
    Page.tools = [Tool],
    assertion(Tool.name == cached),
    assertion(cache_fixture_phase(done)),
    mcp_client_close(Client2, ok(closed)).

test(selected_protocol_transport_and_trace_order_are_explicit,
     [setup(mcp_compat_cache_clear), cleanup(mcp_compat_cache_clear)]) :-
    client_info(Info),
    client_caps(Caps),
    mcp_client_connect(fixture(streamable_http,
                               plunit_rlm_mcp_2026_matrix:trace_fixture),
                       Info,
                       Caps,
                       [cache_max_age(0)],
                       ok(Client0)),
    mcp_client_command(Client0, list_tools, Client1, ok(_)),
    mcp_client_trace(Client1, Trace),
    maplist(event_sequence, Trace, Sequences),
    assertion(strictly_increasing(Sequences)),
    assertion(event_precedes(Trace, discover_sent, protocol_selected)),
    assertion(event_precedes(Trace, protocol_selected, command_sent)),
    assertion(event_precedes(Trace, command_sent, command_completed)),
    forall(member(Event, Trace),
           ( assertion(Event.transport == streamable_http),
             assertion(Event.protocol_version == '2026-07-28') )),
    mcp_client_close(Client1, ok(closed)).

test(cancellation_control_exception_propagates,
     [throws(rlm_cancelled(matrix_cancel))]) :-
    server_info(Info),
    server_caps(Caps),
    mcp_server_new(streamable_http, Info, Caps, [], ok(Server)),
    new_client(Client),
    mcp_2026_client_command(Client, 1, list_tools, Wire, Meta, ok(_)),
    mcp_server_handle(Server,
                      Wire,
                      Meta,
                      plunit_rlm_mcp_2026_matrix:throw_cancel,
                      _,
                      _).

assert_name_header(none, Headers) :-
    !,
    assertion(\+ memberchk('Mcp-Name'=_, Headers)).
assert_name_header(Name, Headers) :-
    assertion(memberchk('Mcp-Name'=Name, Headers)).

cache_fixture(Wire, Meta, Response) :-
    cache_fixture_phase(Phase),
    cache_fixture_phase_response(Phase, Wire, Meta, Response).

cache_fixture_phase_response(expect_discover, Wire, Meta, Response) :-
    assertion(Wire.method == "server/discover"),
    require_modern_meta(Wire, Meta),
    retractall(cache_fixture_phase(_)),
    assertz(cache_fixture_phase(expect_command)),
    server_caps(Caps),
    discovery_response(Wire.id, ["2026-07-28"], Caps, Response).
cache_fixture_phase_response(expect_command, Wire, Meta, Response) :-
    assertion(Wire.method == "tools/list"),
    require_modern_meta(Wire, Meta),
    retractall(cache_fixture_phase(_)),
    assertz(cache_fixture_phase(done)),
    response(Wire.id,
             _{resultType:"complete",
               tools:[_{name:"cached", inputSchema:_{type:"object"}}]},
             Response).

trace_fixture(Wire, Meta, Response) :-
    require_modern_meta(Wire, Meta),
    (   Wire.method == "server/discover"
    ->  server_caps(Caps),
        discovery_response(Wire.id, ["2026-07-28"], Caps, Response)
    ;   Wire.method == "tools/list"
    ->  response(Wire.id,
                 _{resultType:"complete", tools:[]},
                 Response)
    ).

require_modern_meta(Wire, Meta) :-
    assertion(Wire.params.'_meta'.'io.modelcontextprotocol/protocolVersion' ==
              '2026-07-28'),
    assertion(memberchk('MCP-Protocol-Version'='2026-07-28', Meta.headers)),
    assertion(memberchk('Mcp-Method'=Wire.method, Meta.headers)),
    assertion(\+ memberchk('MCP-Session-Id'=_, Meta.headers)).

throw_cancel(_, _) :- throw(rlm_cancelled(matrix_cancel)).

event_sequence(Event, Sequence) :- Sequence = Event.sequence.

strictly_increasing([]).
strictly_increasing([_]).
strictly_increasing([A,B|Rest]) :-
    A < B,
    strictly_increasing([B|Rest]).

event_precedes(Trace, First, Second) :-
    nth1(I, Trace, FirstEvent),
    FirstEvent.type == First,
    nth1(J, Trace, SecondEvent),
    SecondEvent.type == Second,
    I < J,
    !.

:- end_tests(rlm_mcp_2026_matrix).
