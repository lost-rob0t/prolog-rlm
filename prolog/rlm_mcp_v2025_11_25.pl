:- module(rlm_mcp_v2025_11_25,
          [ mcp_2025_protocol_version/1,
            mcp_2025_client_state_new/4,
            mcp_2025_client_initialize/5,
            mcp_2025_client_accept_initialize/5,
            mcp_2025_client_initialized/4,
            mcp_2025_client_command/6,
            mcp_2025_client_decode/4,
            mcp_2025_client_recover_404/2,
            mcp_2025_server_state_new/5,
            mcp_2025_server_receive/5,
            mcp_2025_server_initialize_response/5,
            mcp_2025_server_command_response/6
          ]).

/** <module> MCP 2025-11-25 adapter

All 2025-11-25 JSON-RPC methods, protocol headers, initialization phases and
legacy Streamable HTTP session semantics are contained in this module.
*/

:- use_module(library(lists)).
:- use_module(rlm_mcp_model).

mcp_2025_protocol_version('2025-11-25').

/* -------------------------------------------------------------------------
 * Client lifecycle
 * ---------------------------------------------------------------------- */

mcp_2025_client_state_new(ClientInfo0, ClientCaps0, TransportKind, Outcome) :-
    catch(( normalize_implementation(ClientInfo0, ClientInfo),
            mcp_capabilities_normalize(client, ClientCaps0, ok(ClientCaps)),
            memberchk(TransportKind, [stdio,streamable_http]),
            State = mcp_2025_client{phase:new,
                                    client_info:ClientInfo,
                                    client_capabilities:ClientCaps,
                                    server_info:none,
                                    server_capabilities:none,
                                    protocol_version:null,
                                    session_id:null,
                                    transport:TransportKind,
                                    reinitialize_count:0,
                                    reinitialize_limit:1},
            Result = ok(State)
          ),
          Exception,
          adapter_exception(client_state, Exception, Result)),
    Outcome = Result.

mcp_2025_client_initialize(State0, Id, Wire, Meta, Outcome) :-
    catch(( require_client_phase(State0, new),
            require_jsonrpc_id(Id),
            mcp_2025_protocol_version(Version),
            capabilities_wire(State0.client_capabilities, Capabilities),
            implementation_wire(State0.client_info, ClientInfo),
            Params = _{protocolVersion:Version,
                       capabilities:Capabilities,
                       clientInfo:ClientInfo},
            Wire = _{jsonrpc:"2.0",
                     id:Id,
                     method:"initialize",
                     params:Params},
            request_meta(State0, initialize, Meta),
            Result = ok
          ),
          Exception,
          adapter_exception(client_initialize, Exception, Result)),
    Outcome = Result.

mcp_2025_client_accept_initialize(State0, ExpectedId, TransportResponse,
                                  State, Outcome) :-
    catch(( require_client_phase(State0, new),
            require_jsonrpc_id(ExpectedId),
            require_transport_response(TransportResponse),
            require_success_status(TransportResponse.status),
            require_jsonrpc_result(TransportResponse.body,
                                   ExpectedId,
                                   InitializeResult),
            require_key(InitializeResult, protocolVersion, Version0),
            normalize_protocol_version(Version0, Version),
            mcp_2025_protocol_version(Version),
            require_key(InitializeResult, serverInfo, ServerInfo0),
            normalize_implementation(ServerInfo0, ServerInfo),
            require_key(InitializeResult, capabilities, ServerCaps0),
            mcp_capabilities_normalize(server,
                                       ServerCaps0,
                                       ok(ServerCaps)),
            response_session_id(TransportResponse, SessionId),
            put_dict(_{phase:initialized_pending,
                       server_info:ServerInfo,
                       server_capabilities:ServerCaps,
                       protocol_version:Version,
                       session_id:SessionId},
                     State0,
                     State),
            Result = ok
          ),
          Exception,
          adapter_exception(client_initialize_response, Exception, Result)),
    Outcome = Result.

mcp_2025_client_initialized(State0, Wire, Meta, Outcome) :-
    catch(( require_client_phase(State0, initialized_pending),
            Wire = _{jsonrpc:"2.0",
                     method:"notifications/initialized"},
            request_meta(State0, operation, Meta),
            Result = ok(State0.put(phase, ready))
          ),
          Exception,
          adapter_exception(client_initialized, Exception, Result)),
    (   Result = ok(State)
    ->  Outcome = ok(State)
    ;   Outcome = Result
    ).

mcp_2025_client_command(State, Id, Command0, Wire, Meta, Outcome) :-
    catch(( require_client_phase(State, ready),
            require_jsonrpc_id(Id),
            mcp_command_normalize(Command0, ok(Command)),
            require_server_capability(State, Command),
            encode_command(Command, Method, Params),
            Wire = _{jsonrpc:"2.0", id:Id, method:Method, params:Params},
            request_meta(State, operation, Meta),
            Result = ok(Command)
          ),
          Exception,
          adapter_exception(client_command, Exception, Result)),
    Outcome = Result.

mcp_2025_client_decode(State, Command0, TransportResponse, Outcome) :-
    catch(( require_client_phase(State, ready),
            mcp_command_normalize(Command0, ok(Command)),
            require_transport_response(TransportResponse),
            require_success_status(TransportResponse.status),
            decode_jsonrpc_body(TransportResponse.body, RawResult),
            decode_command_result(Command, RawResult, Canonical),
            Result = ok(Canonical)
          ),
          Exception,
          adapter_exception(client_decode, Exception, Result)),
    Outcome = Result.

mcp_2025_client_recover_404(State0, Outcome) :-
    (   State0.transport == streamable_http,
        State0.session_id \== null,
        State0.reinitialize_count < State0.reinitialize_limit
    ->  Count is State0.reinitialize_count+1,
        put_dict(_{phase:new,
                   server_info:none,
                   server_capabilities:none,
                   protocol_version:null,
                   session_id:null,
                   reinitialize_count:Count},
                 State0,
                 State),
        Outcome = ok(State)
    ;   Outcome = error(mcp_error{phase:session,
                                  kind:reinitialize_exhausted,
                                  message:"MCP 2025 session recovery budget exhausted"})
    ).

/* -------------------------------------------------------------------------
 * Server lifecycle
 * ---------------------------------------------------------------------- */

mcp_2025_server_state_new(ServerInfo0, ServerCaps0, TransportKind,
                          SessionId0, Outcome) :-
    catch(( normalize_implementation(ServerInfo0, ServerInfo),
            mcp_capabilities_normalize(server, ServerCaps0, ok(ServerCaps)),
            memberchk(TransportKind, [stdio,streamable_http]),
            normalize_server_session(TransportKind, SessionId0, SessionId),
            State = mcp_2025_server{phase:new,
                                    server_info:ServerInfo,
                                    server_capabilities:ServerCaps,
                                    client_info:none,
                                    client_capabilities:none,
                                    transport:TransportKind,
                                    session_id:SessionId,
                                    protocol_version:null},
            Result = ok(State)
          ),
          Exception,
          adapter_exception(server_state, Exception, Result)),
    Outcome = Result.

mcp_2025_server_receive(State0, Wire, RequestMeta, Event, Outcome) :-
    catch(( decode_server_message(State0,
                                  Wire,
                                  RequestMeta,
                                  Event0,
                                  State),
            Result = ok(Event0, State)
          ),
          Exception,
          adapter_exception(server_receive, Exception, Result)),
    (   Result = ok(Event1, State1)
    ->  Event = Event1,
        Outcome = ok(State1)
    ;   Outcome = Result
    ).

decode_server_message(State0, Wire, _, Event, State) :-
    State0.phase == new,
    require_wire_method(Wire, "initialize"),
    !,
    require_key(Wire, id, Id),
    require_jsonrpc_id(Id),
    require_key(Wire, params, Params),
    require_key(Params, protocolVersion, Version0),
    normalize_protocol_version(Version0, Version),
    mcp_2025_protocol_version(Version),
    require_key(Params, clientInfo, ClientInfo0),
    normalize_implementation(ClientInfo0, ClientInfo),
    require_key(Params, capabilities, ClientCaps0),
    mcp_capabilities_normalize(client, ClientCaps0, ok(ClientCaps)),
    put_dict(_{phase:initialized_pending,
               client_info:ClientInfo,
               client_capabilities:ClientCaps,
               protocol_version:Version},
             State0,
             State),
    Event = initialize(Id, ClientInfo, ClientCaps).
decode_server_message(State0, Wire, RequestMeta, initialized, State) :-
    State0.phase == initialized_pending,
    require_wire_method(Wire, "notifications/initialized"),
    !,
    require_operation_meta(State0, RequestMeta),
    put_dict(phase, State0, ready, State).
decode_server_message(State0, Wire, RequestMeta, command(Id, Command), State0) :-
    State0.phase == ready,
    require_operation_meta(State0, RequestMeta),
    require_key(Wire, id, Id),
    require_jsonrpc_id(Id),
    require_key(Wire, method, Method),
    dict_default(Wire, params, _{}, Params),
    decode_command(Method, Params, Command0),
    mcp_command_normalize(Command0, ok(Command)),
    require_declared_capability(State0.server_capabilities, Command),
    !.
decode_server_message(State, Wire, _, _, _) :-
    throw(mcp_adapter_fault(unexpected_server_message(State.phase, Wire))).

mcp_2025_server_initialize_response(State, Id, Wire, ResponseMeta, Outcome) :-
    catch(( State.phase == initialized_pending,
            require_jsonrpc_id(Id),
            mcp_2025_protocol_version(Version),
            capabilities_wire(State.server_capabilities, Capabilities),
            implementation_wire(State.server_info, ServerInfo),
            ResultBody = _{protocolVersion:Version,
                           capabilities:Capabilities,
                           serverInfo:ServerInfo},
            Wire = _{jsonrpc:"2.0", id:Id, result:ResultBody},
            response_meta(State, ResponseMeta),
            Result = ok
          ),
          Exception,
          adapter_exception(server_initialize_response, Exception, Result)),
    Outcome = Result.

mcp_2025_server_command_response(State, Id, Command0, CanonicalResult,
                                 Wire, Outcome) :-
    catch(( State.phase == ready,
            require_jsonrpc_id(Id),
            mcp_command_normalize(Command0, ok(Command)),
            encode_command_result(Command, CanonicalResult, ResultBody),
            Wire = _{jsonrpc:"2.0", id:Id, result:ResultBody},
            Result = ok
          ),
          Exception,
          adapter_exception(server_command_response, Exception, Result)),
    Outcome = Result.

/* -------------------------------------------------------------------------
 * Command wire mapping
 * ---------------------------------------------------------------------- */

encode_command(Command, "tools/list", Params) :-
    Command.op == list_tools, !, cursor_params(Command.cursor, Params).
encode_command(Command, "tools/call", Params) :-
    Command.op == call_tool,
    !,
    atom_string(Command.name, Name),
    Params = _{name:Name, arguments:Command.arguments}.
encode_command(Command, "resources/list", Params) :-
    Command.op == list_resources, !, cursor_params(Command.cursor, Params).
encode_command(Command, "resources/read", _{uri:Command.uri}) :-
    Command.op == read_resource, !.
encode_command(Command, "prompts/list", Params) :-
    Command.op == list_prompts, !, cursor_params(Command.cursor, Params).
encode_command(Command, "prompts/get", Params) :-
    Command.op == get_prompt,
    !,
    atom_string(Command.name, Name),
    Params = _{name:Name, arguments:Command.arguments}.

cursor_params(null, _{}) :- !.
cursor_params(Cursor, _{cursor:Cursor}).

decode_command("tools/list", Params, list_tools(Cursor)) :-
    !, dict_default(Params, cursor, null, Cursor).
decode_command("tools/call", Params, call_tool(Name, Args)) :-
    !,
    require_key(Params, name, Name),
    dict_default(Params, arguments, _{}, Args).
decode_command("resources/list", Params, list_resources(Cursor)) :-
    !, dict_default(Params, cursor, null, Cursor).
decode_command("resources/read", Params, read_resource(Uri)) :-
    !, require_key(Params, uri, Uri).
decode_command("prompts/list", Params, list_prompts(Cursor)) :-
    !, dict_default(Params, cursor, null, Cursor).
decode_command("prompts/get", Params, get_prompt(Name, Args)) :-
    !,
    require_key(Params, name, Name),
    dict_default(Params, arguments, _{}, Args).
decode_command(Method, _, _) :-
    throw(mcp_adapter_fault(unsupported_method(Method))).

/* -------------------------------------------------------------------------
 * Result normalization
 * ---------------------------------------------------------------------- */

decode_jsonrpc_body(Body, _) :-
    is_dict(Body),
    get_dict(error, Body, Error0),
    !,
    normalize_remote_error(Error0, Error),
    throw(mcp_adapter_fault(remote_error(Error))).
decode_jsonrpc_body(Body, Result) :-
    is_dict(Body),
    require_key(Body, result, Result),
    !.
decode_jsonrpc_body(Body, _) :-
    throw(mcp_adapter_fault(invalid_jsonrpc_response(Body))).

decode_command_result(Command, Raw, Result) :-
    Command.op == list_tools,
    !,
    require_key(Raw, tools, Tools0),
    normalize_list(mcp_tool_normalize, Tools0, Tools),
    dict_default(Raw, nextCursor, null, Cursor),
    Result = mcp_tools_page{tools:Tools, next_cursor:Cursor}.
decode_command_result(Command, Raw, Result) :-
    Command.op == call_tool,
    !,
    dict_default(Raw, content, [], Content0),
    normalize_list(mcp_content_normalize, Content0, Content),
    optional_canonical(Raw, structuredContent, Structured),
    dict_default(Raw, isError, false, IsError),
    Result = mcp_tool_result{content:Content,
                             structured:Structured,
                             is_error:IsError}.
decode_command_result(Command, Raw, Result) :-
    Command.op == list_resources,
    !,
    require_key(Raw, resources, Resources0),
    normalize_list(mcp_resource_normalize, Resources0, Resources),
    dict_default(Raw, nextCursor, null, Cursor),
    Result = mcp_resources_page{resources:Resources, next_cursor:Cursor}.
decode_command_result(Command, Raw, Result) :-
    Command.op == read_resource,
    !,
    require_key(Raw, contents, Contents0),
    maplist(normalize_resource_content, Contents0, Contents),
    Result = mcp_resource_result{contents:Contents}.
decode_command_result(Command, Raw, Result) :-
    Command.op == list_prompts,
    !,
    require_key(Raw, prompts, Prompts0),
    normalize_list(mcp_prompt_normalize, Prompts0, Prompts),
    dict_default(Raw, nextCursor, null, Cursor),
    Result = mcp_prompts_page{prompts:Prompts, next_cursor:Cursor}.
decode_command_result(Command, Raw, Result) :-
    Command.op == get_prompt,
    !,
    dict_default(Raw, description, null, Description),
    require_key(Raw, messages, Messages0),
    maplist(normalize_prompt_message, Messages0, Messages),
    Result = mcp_prompt_result{description:Description, messages:Messages}.

encode_command_result(Command, Result, Wire) :-
    Command.op == list_tools,
    !,
    get_dict(tools, Result, Tools),
    maplist(tool_wire, Tools, WireTools),
    page_wire(WireTools, tools, Result, Wire).
encode_command_result(Command, Result, Wire) :-
    Command.op == call_tool,
    !,
    get_dict(content, Result, Content),
    maplist(content_wire, Content, WireContent),
    Base = _{content:WireContent},
    optional_result_field(Result, structured, structuredContent, Base, Base1),
    optional_result_field(Result, is_error, isError, Base1, Wire).
encode_command_result(Command, Result, Wire) :-
    Command.op == list_resources,
    !,
    get_dict(resources, Result, Resources),
    maplist(resource_wire, Resources, WireResources),
    page_wire(WireResources, resources, Result, Wire).
encode_command_result(Command, Result, Wire) :-
    Command.op == read_resource,
    !,
    get_dict(contents, Result, Contents),
    maplist(resource_content_wire, Contents, WireContents),
    Wire = _{contents:WireContents}.
encode_command_result(Command, Result, Wire) :-
    Command.op == list_prompts,
    !,
    get_dict(prompts, Result, Prompts),
    maplist(prompt_wire, Prompts, WirePrompts),
    page_wire(WirePrompts, prompts, Result, Wire).
encode_command_result(Command, Result, Wire) :-
    Command.op == get_prompt,
    !,
    get_dict(messages, Result, Messages),
    maplist(prompt_message_wire, Messages, WireMessages),
    Base = _{messages:WireMessages},
    optional_result_field(Result, description, description, Base, Wire).

normalize_resource_content(Input, Content) :-
    is_dict(Input),
    require_key(Input, uri, Uri),
    dict_default(Input, mimeType, null, Mime),
    (   get_dict(text, Input, Text)
    ->  Content = mcp_resource_content{uri:Uri,
                                       mime_type:Mime,
                                       type:text,
                                       data:Text}
    ;   get_dict(blob, Input, Blob)
    ->  Content = mcp_resource_content{uri:Uri,
                                       mime_type:Mime,
                                       type:blob,
                                       data:Blob}
    ;   throw(mcp_adapter_fault(invalid_resource_content(Input)))
    ).

normalize_prompt_message(Input, Message) :-
    is_dict(Input),
    require_key(Input, role, Role0),
    normalize_role(Role0, Role),
    require_key(Input, content, Content0),
    mcp_content_normalize(Content0, ok(Content)),
    Message = mcp_prompt_message{role:Role, content:Content}.

/* -------------------------------------------------------------------------
 * Server result wire helpers
 * ---------------------------------------------------------------------- */

tool_wire(Tool, Wire) :-
    is_dict(Tool, mcp_tool),
    atom_string(Tool.name, Name),
    Base = _{name:Name, inputSchema:Tool.input_schema},
    put_optional(title, Tool.title, Base, B1),
    put_optional(description, Tool.description, B1, B2),
    put_optional(outputSchema, Tool.output_schema, B2, B3),
    put_optional(annotations, Tool.annotations, B3, B4),
    put_optional(icons, Tool.icons, B4, Wire).

resource_wire(Resource, Wire) :-
    is_dict(Resource, mcp_resource),
    Base = _{uri:Resource.uri, name:Resource.name},
    put_optional(title, Resource.title, Base, B1),
    put_optional(description, Resource.description, B1, B2),
    put_optional(mimeType, Resource.mime_type, B2, B3),
    put_optional(size, Resource.size, B3, B4),
    put_optional(annotations, Resource.annotations, B4, B5),
    put_optional(icons, Resource.icons, B5, Wire).

prompt_wire(Prompt, Wire) :-
    is_dict(Prompt, mcp_prompt),
    atom_string(Prompt.name, Name),
    Base = _{name:Name},
    put_optional(title, Prompt.title, Base, B1),
    put_optional(description, Prompt.description, B1, B2),
    put_optional(arguments, Prompt.arguments, B2, B3),
    put_optional(icons, Prompt.icons, B3, Wire).

content_wire(Content, Wire) :-
    Content.type == text,
    !,
    Wire = _{type:"text", text:Content.text}.
content_wire(Content, Wire) :-
    memberchk(Content.type, [image,audio]),
    !,
    atom_string(Content.type, Type),
    Wire = _{type:Type, data:Content.data, mimeType:Content.mime_type}.
content_wire(Content, Wire) :-
    Content.type == resource_link,
    !,
    Wire = _{type:"resource_link",
             uri:Content.uri,
             name:Content.name,
             mimeType:Content.mime_type}.
content_wire(Content, Wire) :-
    Content.type == resource,
    !,
    Wire = _{type:"resource", resource:Content.resource}.

resource_content_wire(Content, Wire) :-
    Base = _{uri:Content.uri},
    put_optional(mimeType, Content.mime_type, Base, B1),
    (   Content.type == text
    ->  put_dict(text, B1, Content.data, Wire)
    ;   Content.type == blob
    ->  put_dict(blob, B1, Content.data, Wire)
    ).

prompt_message_wire(Message, Wire) :-
    atom_string(Message.role, Role),
    content_wire(Message.content, Content),
    Wire = _{role:Role, content:Content}.

page_wire(Items, Key, Result, Wire) :-
    put_dict(Key, _{}, Items, Base),
    (   get_dict(next_cursor, Result, Cursor), Cursor \== null
    ->  put_dict(nextCursor, Base, Cursor, Wire)
    ;   Wire = Base
    ).

optional_result_field(Result, SourceKey, WireKey, Base, Wire) :-
    (   get_dict(SourceKey, Result, Value),
        Value \== none,
        Value \== null
    ->  put_dict(WireKey, Base, Value, Wire)
    ;   Wire = Base
    ).

put_optional(_, none, Base, Base) :- !.
put_optional(_, null, Base, Base) :- !.
put_optional(Key, Value, Base, Wire) :- put_dict(Key, Base, Value, Wire).

/* -------------------------------------------------------------------------
 * Capability and metadata handling
 * ---------------------------------------------------------------------- */

require_server_capability(State, Command) :-
    require_declared_capability(State.server_capabilities, Command).

require_declared_capability(Caps, Command) :-
    mcp_command_capability(Command, Capability),
    get_dict(Capability, Caps, Value),
    (   Value \== none
    ->  true
    ;   throw(mcp_adapter_fault(capability_not_negotiated(Capability)))
    ).

capabilities_wire(Caps, Wire) :-
    capability_pairs([tools,resources,prompts,logging,completions,
                      roots,sampling,elicitation,experimental],
                     Caps,
                     Pairs),
    dict_pairs(Wire, _, Pairs).

capability_pairs([], _, []).
capability_pairs([Key|Keys], Caps, Pairs) :-
    get_dict(Key, Caps, Value),
    (   Value == none
    ->  Pairs = Rest
    ;   Pairs = [Key-Value|Rest]
    ),
    capability_pairs(Keys, Caps, Rest).

request_meta(State, initialize,
             mcp_transport_request{headers:Headers,
                                   protocol_version:'2025-11-25',
                                   transport:State.transport}) :-
    common_headers(Common),
    (   State.transport == streamable_http
    ->  Headers = Common
    ;   Headers = []
    ).
request_meta(State, operation,
             mcp_transport_request{headers:Headers,
                                   protocol_version:'2025-11-25',
                                   transport:State.transport}) :-
    common_headers(Common),
    operation_headers(State, VersionHeaders),
    append(Common, VersionHeaders, Headers0),
    (   State.transport == streamable_http
    ->  Headers = Headers0
    ;   Headers = []
    ).

common_headers(['Accept'='application/json, text/event-stream']).

operation_headers(State, Headers) :-
    mcp_2025_protocol_version(Version),
    Base = ['MCP-Protocol-Version'=Version],
    (   State.session_id == null
    ->  Headers = Base
    ;   Headers = ['MCP-Session-Id'=State.session_id|Base]
    ).

response_meta(State, mcp_transport_response_meta{headers:Headers}) :-
    (   State.transport == streamable_http,
        State.session_id \== null
    ->  Headers = ['MCP-Session-Id'=State.session_id]
    ;   Headers = []
    ).

require_operation_meta(State, Meta) :-
    (   State.transport == stdio
    ->  true
    ;   is_dict(Meta),
        get_dict(headers, Meta, Headers),
        memberchk('MCP-Protocol-Version'='2025-11-25', Headers),
        require_server_session_header(State, Headers)
    ).

require_server_session_header(State, _) :-
    State.session_id == null,
    !.
require_server_session_header(State, Headers) :-
    (   memberchk('MCP-Session-Id'=State.session_id, Headers)
    ->  true
    ;   throw(mcp_adapter_fault(invalid_session))
    ).

response_session_id(Response, SessionId) :-
    (   Response.headers = Headers,
        is_dict(Headers),
        get_dict('mcp-session-id', Headers, Raw),
        Raw \== "",
        Raw \== ''
    ->  normalize_session_id(Raw, SessionId)
    ;   SessionId = null
    ).

/* -------------------------------------------------------------------------
 * Generic validation
 * ---------------------------------------------------------------------- */

normalize_implementation(Input, Info) :-
    is_dict(Input),
    require_key(Input, name, Name0),
    require_text(Name0, Name),
    require_key(Input, version, Version0),
    require_text(Version0, Version),
    Info = mcp_implementation{name:Name, version:Version}.

implementation_wire(Info, _{name:Info.name, version:Info.version}).

normalize_server_session(stdio, _, null) :- !.
normalize_server_session(streamable_http, null, null) :- !.
normalize_server_session(streamable_http, Session0, Session) :-
    normalize_session_id(Session0, Session).

normalize_session_id(Value, Value) :- string(Value), Value \== "", !.
normalize_session_id(Value, Text) :-
    atom(Value), Value \== '', !, atom_string(Value, Text).
normalize_session_id(Value, _) :-
    throw(mcp_adapter_fault(invalid_session_id(Value))).

normalize_protocol_version(Value, Value) :- atom(Value), !.
normalize_protocol_version(Value, Version) :- string(Value), !, atom_string(Version, Value).
normalize_protocol_version(Value, _) :-
    throw(mcp_adapter_fault(invalid_protocol_version(Value))).

normalize_role(Value, Role) :-
    normalize_protocol_version(Value, Role),
    memberchk(Role, [user,assistant]),
    !.
normalize_role(Value, _) :- throw(mcp_adapter_fault(invalid_prompt_role(Value))).

require_client_phase(State, Phase) :-
    (   is_dict(State, mcp_2025_client), State.phase == Phase
    ->  true
    ;   throw(mcp_adapter_fault(invalid_client_phase(Phase)))
    ).

require_transport_response(Response) :-
    (   is_dict(Response, mcp_transport_response)
    ->  true
    ;   throw(mcp_adapter_fault(invalid_transport_response(Response)))
    ).

require_success_status(Status) :-
    integer(Status), Status >= 200, Status < 300, !.
require_success_status(Status) :-
    throw(mcp_adapter_fault(http_status(Status))).

require_jsonrpc_result(Body, ExpectedId, Result) :-
    is_dict(Body),
    (   get_dict(error, Body, Error0)
    ->  normalize_remote_error(Error0, Error),
        throw(mcp_adapter_fault(remote_error(Error)))
    ;   require_key(Body, id, Id),
        Id == ExpectedId,
        require_key(Body, result, Result)
    ).

normalize_remote_error(Input, Error) :-
    (   is_dict(Input)
    ->  dict_default(Input, code, null, Code),
        dict_default(Input, message, "MCP peer returned an error", Message),
        optional_canonical(Input, data, Data),
        Error = mcp_remote_error{code:Code, message:Message, data:Data}
    ;   Error = mcp_remote_error{code:null,
                                 message:"MCP peer returned an invalid error",
                                 data:Input}
    ).

require_wire_method(Wire, Expected) :-
    is_dict(Wire),
    require_key(Wire, method, Method),
    (   Method == Expected
    ->  true
    ;   throw(mcp_adapter_fault(expected_method(Expected, Method)))
    ).

require_jsonrpc_id(Id) :-
    ( integer(Id) ; string(Id) ; atom(Id) ),
    !.
require_jsonrpc_id(Id) :- throw(mcp_adapter_fault(invalid_jsonrpc_id(Id))).

require_key(Dict, Key, Value) :-
    (   is_dict(Dict), get_dict(Key, Dict, Value)
    ->  true
    ;   throw(mcp_adapter_fault(missing_key(Key)))
    ).

dict_default(Dict, Key, Default, Value) :-
    (   is_dict(Dict), get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

require_text(Value, Value) :- string(Value), !.
require_text(Value, Text) :- atom(Value), !, atom_string(Value, Text).
require_text(Value, _) :- throw(mcp_adapter_fault(expected_text(Value))).

optional_canonical(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Raw), Raw \== null
    ->  mcp_json_canonical(Raw, Value)
    ;   Value = none
    ).

normalize_list(Normalizer, Inputs, Outputs) :-
    (   is_list(Inputs)
    ->  maplist(normalize_one(Normalizer), Inputs, Outputs)
    ;   throw(mcp_adapter_fault(expected_list(Inputs)))
    ).

normalize_one(Normalizer, Input, Output) :-
    call(Normalizer, Input, Outcome),
    (   Outcome = ok(Output)
    ->  true
    ;   Outcome = error(Error),
        throw(mcp_adapter_fault(canonical_error(Error)))
    ).

adapter_exception(_, mcp_adapter_fault(Detail), error(Error)) :-
    !,
    Error = mcp_error{phase:adapter_2025_11_25,
                      kind:protocol_error,
                      detail:Detail,
                      protocol_version:'2025-11-25',
                      message:"MCP 2025-11-25 protocol operation failed"}.
adapter_exception(_, mcp_model_fault(Detail), error(Error)) :-
    !,
    Error = mcp_error{phase:adapter_2025_11_25,
                      kind:model_error,
                      detail:Detail,
                      protocol_version:'2025-11-25',
                      message:"canonical MCP model rejected adapter data"}.
adapter_exception(Operation, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = mcp_error{phase:adapter_2025_11_25,
                      kind:exception,
                      operation:Operation,
                      exception:Safe,
                      protocol_version:'2025-11-25',
                      message:"MCP 2025-11-25 adapter raised an exception"}.
