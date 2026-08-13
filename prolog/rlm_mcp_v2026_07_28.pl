:- module(rlm_mcp_v2026_07_28,
          [ mcp_2026_protocol_version/1,
            mcp_2026_client_state_new/4,
            mcp_2026_client_discover/5,
            mcp_2026_client_accept_discover/5,
            mcp_2026_client_command/6,
            mcp_2026_client_decode/5,
            mcp_2026_server_state_new/4,
            mcp_2026_server_receive/5,
            mcp_2026_server_discover_response/5,
            mcp_2026_server_command_response/6,
            mcp_2026_server_error_reply/4
          ]).

/** <module> MCP 2026-07-28 stateless protocol adapter

All 2026-07-28 wire behavior lives here: self-describing request metadata,
server/discover, HTTP routing headers, resultType, and protocol-version errors.
There is intentionally no initialize phase, initialized notification, session
identifier, or session recovery state in this module.
*/

:- use_module(rlm_mcp_model).
:- use_module(library(base64)).

mcp_2026_protocol_version('2026-07-28').

mcp_2026_client_state_new(ClientInfo0, ClientCaps0, Transport, Outcome) :-
    adapter_outcome(client_state,
                    client_state_new(ClientInfo0, ClientCaps0, Transport),
                    Outcome).

client_state_new(ClientInfo0, ClientCaps0, Transport, State) :-
    normalize_implementation(ClientInfo0, ClientInfo),
    require_model_ok(mcp_capabilities_normalize(client, ClientCaps0), ClientCaps),
    require_transport_kind(Transport),
    mcp_2026_protocol_version(Version),
    State = mcp_2026_client{
                client_info:ClientInfo,
                client_capabilities:ClientCaps,
                server_info:none,
                server_capabilities:none,
                supported_versions:[Version],
                protocol_version:Version,
                transport:Transport
            }.

mcp_2026_client_discover(State, Id, Wire, Meta, Outcome) :-
    adapter_status(client_discover,
                   client_discover(State, Id, Wire, Meta),
                   Outcome).

client_discover(State, Id, Wire, Meta) :-
    require_client_state(State),
    require_jsonrpc_id(Id),
    request_params(State, json{}, Params),
    Wire = json{jsonrpc:"2.0", id:Id, method:"server/discover", params:Params},
    request_meta(State, "server/discover", none, Meta).

mcp_2026_client_accept_discover(State0, ExpectedId, Response,
                                State, Outcome) :-
    adapter_status(client_discover_response,
                   client_accept_discover(State0, ExpectedId, Response, State),
                   Outcome).

client_accept_discover(State0, ExpectedId, Response, State) :-
    require_client_state(State0),
    require_transport_response(Response),
    response_result(Response, ExpectedId, Result),
    require_key(Result, supportedVersions, Supported0),
    normalize_versions(Supported0, Supported),
    mcp_2026_protocol_version(Version),
    (   memberchk(Version, Supported)
    ->  true
    ;   throw(mcp_2026_fault(unsupported_by_peer(Version, Supported)))
    ),
    require_key(Result, capabilities, ServerCaps0),
    require_model_ok(mcp_capabilities_normalize(server, ServerCaps0), ServerCaps),
    result_server_info(Result, ServerInfo),
    put_dict(_{server_info:ServerInfo,
               server_capabilities:ServerCaps,
               supported_versions:Supported},
             State0,
             State).

mcp_2026_client_command(State, Id, Command0, Wire, Meta, Outcome) :-
    adapter_outcome(client_command,
                    client_command(State, Id, Command0, Wire, Meta),
                    Outcome).

client_command(State, Id, Command0, Wire, Meta, Command) :-
    require_client_state(State),
    require_jsonrpc_id(Id),
    require_model_ok(mcp_command_normalize(Command0), Command),
    require_server_capability_if_known(State, Command),
    encode_command(Command, Method, Params0, RoutingName),
    request_params(State, Params0, Params),
    Wire = json{jsonrpc:"2.0", id:Id, method:Method, params:Params},
    request_meta(State, Method, RoutingName, Meta).

mcp_2026_client_decode(State, ExpectedId, Command0, Response, Outcome) :-
    adapter_outcome(client_decode,
                    client_decode(State, ExpectedId, Command0, Response),
                    Outcome).

client_decode(State, ExpectedId, Command0, Response, Result) :-
    require_client_state(State),
    require_model_ok(mcp_command_normalize(Command0), Command),
    require_transport_response(Response),
    response_result(Response, ExpectedId, RawResult),
    decode_command_result(Command, RawResult, Result).

mcp_2026_server_state_new(ServerInfo0, ServerCaps0, Transport, Outcome) :-
    adapter_outcome(server_state,
                    server_state_new(ServerInfo0, ServerCaps0, Transport),
                    Outcome).

server_state_new(ServerInfo0, ServerCaps0, Transport, State) :-
    normalize_implementation(ServerInfo0, ServerInfo),
    require_model_ok(mcp_capabilities_normalize(server, ServerCaps0), ServerCaps),
    require_transport_kind(Transport),
    mcp_2026_protocol_version(Version),
    State = mcp_2026_server{
                server_info:ServerInfo,
                server_capabilities:ServerCaps,
                supported_versions:[Version, '2025-11-25'],
                protocol_version:Version,
                transport:Transport
            }.

mcp_2026_server_receive(State, Wire, RequestMeta, Event, Outcome) :-
    adapter_outcome(server_receive,
                    server_receive(State, Wire, RequestMeta, Event),
                    Outcome).

server_receive(State, Wire, RequestMeta, Event, State) :-
    require_server_state(State),
    require_jsonrpc_request(Wire, Id, Method, Params),
    require_request_protocol(State, Params, RequestMeta, Method),
    request_client_metadata(Params, ClientInfo, ClientCaps),
    (   Method == "server/discover"
    ->  Event = discover(Id, ClientInfo, ClientCaps)
    ;   decode_command(Method, Params, Command0),
        require_model_ok(mcp_command_normalize(Command0), Command),
        get_dict(server_capabilities, State, ServerCaps),
        require_declared_capability(ServerCaps, Command),
        Event = command(Id, Command)
    ).

mcp_2026_server_discover_response(State, Id, Wire, ResponseMeta, Outcome) :-
    adapter_status(server_discover_response,
                   server_discover_response(State, Id, Wire, ResponseMeta),
                   Outcome).

server_discover_response(State, Id, Wire, ResponseMeta) :-
    require_server_state(State),
    require_jsonrpc_id(Id),
    get_dict(server_info, State, ServerInfo),
    get_dict(server_capabilities, State, ServerCaps),
    get_dict(supported_versions, State, Supported),
    capabilities_wire(ServerCaps, CapabilitiesWire),
    result_meta(ServerInfo, ResultMeta),
    Result = json{resultType:"complete",
                  supportedVersions:Supported,
                  capabilities:CapabilitiesWire,
                  '_meta':ResultMeta},
    Wire = json{jsonrpc:"2.0", id:Id, result:Result},
    ResponseMeta = mcp_transport_response_meta{headers:[]}.

mcp_2026_server_command_response(State, Id, Command0, CanonicalResult,
                                 Wire, Outcome) :-
    adapter_status(server_command_response,
                   server_command_response(State,
                                           Id,
                                           Command0,
                                           CanonicalResult,
                                           Wire),
                   Outcome).

server_command_response(State, Id, Command0, CanonicalResult, Wire) :-
    require_server_state(State),
    require_jsonrpc_id(Id),
    require_model_ok(mcp_command_normalize(Command0), Command),
    encode_command_result(Command, CanonicalResult, Result0),
    get_dict(server_info, State, ServerInfo),
    result_meta(ServerInfo, ResultMeta),
    put_dict(_{resultType:"complete", '_meta':ResultMeta}, Result0, Result),
    Wire = json{jsonrpc:"2.0", id:Id, result:Result}.

mcp_2026_server_error_reply(Id, Error, Wire, Status) :-
    require_jsonrpc_id(Id),
    is_dict(Error),
    get_dict(jsonrpc_code, Error, Code),
    get_dict(message, Error, Message),
    error_data(Error, Data),
    ErrorWire = json{code:Code, message:Message, data:Data},
    Wire = json{jsonrpc:"2.0", id:Id, error:ErrorWire},
    (   get_dict(http_status, Error, Status0)
    ->  Status = Status0
    ;   Status = 400
    ).

/* Request metadata ------------------------------------------------------- */

request_params(State, Params0, Params) :-
    get_dict(client_info, State, ClientInfo),
    get_dict(client_capabilities, State, ClientCaps),
    implementation_wire(ClientInfo, ClientInfoWire),
    capabilities_wire(ClientCaps, ClientCapsWire),
    mcp_2026_protocol_version(Version),
    RequestMeta = json{
        'io.modelcontextprotocol/protocolVersion':Version,
        'io.modelcontextprotocol/clientInfo':ClientInfoWire,
        'io.modelcontextprotocol/clientCapabilities':ClientCapsWire
    },
    put_dict('_meta', Params0, RequestMeta, Params).

request_meta(State, Method, RoutingName,
             mcp_transport_request{headers:Headers,
                                   protocol_version:Version,
                                   transport:Transport}) :-
    get_dict(protocol_version, State, Version),
    get_dict(transport, State, Transport),
    request_headers(Transport, Version, Method, RoutingName, Headers).

request_headers(stdio, _, _, _, []) :- !.
request_headers(streamable_http, Version, Method, RoutingName, Headers) :-
    Base = ['Accept'='application/json, text/event-stream',
            'MCP-Protocol-Version'=Version,
            'Mcp-Method'=Method],
    (   RoutingName == none
    ->  Headers = Base
    ;   routing_header_value(RoutingName, HeaderValue),
        append(Base, ['Mcp-Name'=HeaderValue], Headers)
    ).

routing_header_value(Value0, Header) :-
    require_text(Value0, Text),
    (   safe_routing_header(Text)
    ->  Header = Text
    ;   base64_encoded(Text, Encoded, [as(string), encoding(utf8)]),
        string_concat(":(b64):", Encoded, Header)
    ).

safe_routing_header(Text) :-
    Text \== "",
    \+ sub_string(Text, 0, _, _, ":(b64):"),
    string_codes(Text, Codes),
    maplist(safe_header_code, Codes).

safe_header_code(Code) :- Code >= 33, Code =< 126.

require_request_protocol(State, Params, RequestMeta, Method) :-
    require_key(Params, '_meta', Meta),
    require_key(Meta, 'io.modelcontextprotocol/protocolVersion', Version0),
    normalize_protocol_version(Version0, Requested),
    mcp_2026_protocol_version(Supported),
    (   Requested == Supported
    ->  true
    ;   throw(mcp_2026_fault(unsupported_protocol_version(Requested)))
    ),
    get_dict(transport, State, Transport),
    require_http_routing(Transport, RequestMeta, Requested, Method, Params).

require_http_routing(stdio, _, _, _, _) :- !.
require_http_routing(streamable_http, RequestMeta, Version, Method, Params) :-
    require_request_headers(RequestMeta, Headers),
    require_header(Headers, 'MCP-Protocol-Version', HeaderVersion0),
    normalize_protocol_version(HeaderVersion0, HeaderVersion),
    (   HeaderVersion == Version
    ->  true
    ;   throw(mcp_2026_fault(header_mismatch(protocol_version,
                                             Version,
                                             HeaderVersion)))
    ),
    require_header(Headers, 'Mcp-Method', HeaderMethod0),
    require_text(HeaderMethod0, HeaderMethod),
    (   HeaderMethod == Method
    ->  true
    ;   throw(mcp_2026_fault(header_mismatch(method,
                                             Method,
                                             HeaderMethod)))
    ),
    require_name_header(Method, Params, Headers).

require_name_header(Method, Params, Headers) :-
    routing_name_for_method(Method, Params, Name),
    !,
    routing_header_value(Name, Expected),
    require_header(Headers, 'Mcp-Name', Actual0),
    require_text(Actual0, Actual),
    (   Actual == Expected
    ->  true
    ;   throw(mcp_2026_fault(header_mismatch(name, Expected, Actual)))
    ).
require_name_header(_, _, _).

routing_name_for_method("tools/call", Params, Name) :- require_key(Params, name, Name).
routing_name_for_method("resources/read", Params, Name) :- require_key(Params, uri, Name).
routing_name_for_method("prompts/get", Params, Name) :- require_key(Params, name, Name).

request_client_metadata(Params, ClientInfo, ClientCaps) :-
    require_key(Params, '_meta', Meta),
    require_key(Meta, 'io.modelcontextprotocol/clientCapabilities', ClientCaps0),
    require_model_ok(mcp_capabilities_normalize(client, ClientCaps0), ClientCaps),
    (   get_dict('io.modelcontextprotocol/clientInfo', Meta, ClientInfo0)
    ->  normalize_implementation(ClientInfo0, ClientInfo)
    ;   ClientInfo = none
    ).

/* Wire command mapping --------------------------------------------------- */

encode_command(Command, Method, Params, RoutingName) :-
    get_dict(op, Command, Operation),
    encode_operation(Operation, Command, Method, Params, RoutingName).

encode_operation(list_tools, Command, "tools/list", Params, none) :-
    get_dict(cursor, Command, Cursor), cursor_params(Cursor, Params).
encode_operation(call_tool, Command, "tools/call", Params, NameText) :-
    get_dict(name, Command, Name), atom_string(Name, NameText),
    get_dict(arguments, Command, Arguments),
    Params = json{name:NameText, arguments:Arguments}.
encode_operation(list_resources, Command, "resources/list", Params, none) :-
    get_dict(cursor, Command, Cursor), cursor_params(Cursor, Params).
encode_operation(read_resource, Command, "resources/read", json{uri:Uri}, Uri) :-
    get_dict(uri, Command, Uri).
encode_operation(list_prompts, Command, "prompts/list", Params, none) :-
    get_dict(cursor, Command, Cursor), cursor_params(Cursor, Params).
encode_operation(get_prompt, Command, "prompts/get", Params, NameText) :-
    get_dict(name, Command, Name), atom_string(Name, NameText),
    get_dict(arguments, Command, Arguments),
    Params = json{name:NameText, arguments:Arguments}.

cursor_params(null, json{}) :- !.
cursor_params(Cursor, json{cursor:Cursor}).

decode_command("tools/list", Params, list_tools(Cursor)) :-
    !, dict_default(Params, cursor, null, Cursor).
decode_command("tools/call", Params, call_tool(Name, Arguments)) :-
    !, require_key(Params, name, Name),
    dict_default(Params, arguments, json{}, Arguments).
decode_command("resources/list", Params, list_resources(Cursor)) :-
    !, dict_default(Params, cursor, null, Cursor).
decode_command("resources/read", Params, read_resource(Uri)) :-
    !, require_key(Params, uri, Uri).
decode_command("prompts/list", Params, list_prompts(Cursor)) :-
    !, dict_default(Params, cursor, null, Cursor).
decode_command("prompts/get", Params, get_prompt(Name, Arguments)) :-
    !, require_key(Params, name, Name),
    dict_default(Params, arguments, json{}, Arguments).
decode_command(Method, _, _) :-
    throw(mcp_2026_fault(unsupported_method(Method))).

/* Response decoding/encoding ------------------------------------------- */

response_result(Response, ExpectedId, Result) :-
    get_dict(status, Response, Status),
    get_dict(body, Response, Body),
    (   is_dict(Body), get_dict(error, Body, Error0)
    ->  remote_error_exception(Error0)
    ;   require_success_status(Status),
        is_dict(Body),
        validate_response_id(Body, ExpectedId),
        require_key(Body, result, Result),
        require_key(Result, resultType, ResultType0),
        require_text(ResultType0, ResultType),
        (   ResultType == "complete"
        ->  true
        ;   throw(mcp_2026_fault(incomplete_result(ResultType)))
        )
    ).

remote_error_exception(Error0) :-
    is_dict(Error0),
    dict_default(Error0, code, null, Code),
    dict_default(Error0, message, "MCP peer returned an error", Message),
    dict_default(Error0, data, json{}, Data),
    (   Code =:= -32022,
        is_dict(Data),
        get_dict(supported, Data, Supported0),
        get_dict(requested, Data, Requested0)
    ->  normalize_versions(Supported0, Supported),
        normalize_protocol_version(Requested0, Requested),
        throw(mcp_2026_fault(unsupported_by_peer(Requested, Supported)))
    ;   throw(mcp_2026_fault(remote_error(Code, Message, Data)))
    ).

validate_response_id(Body, ExpectedId) :-
    require_key(Body, id, ActualId),
    (   ActualId == ExpectedId
    ->  true
    ;   throw(mcp_2026_fault(response_id_mismatch(ExpectedId, ActualId)))
    ).

decode_command_result(Command, Raw, Result) :-
    get_dict(op, Command, Operation),
    decode_operation_result(Operation, Raw, Result).

decode_operation_result(list_tools, Raw, Result) :-
    require_key(Raw, tools, Tools0),
    normalize_model_list(mcp_tool_normalize, Tools0, Tools),
    dict_default(Raw, nextCursor, null, Cursor),
    Result = mcp_tools_page{tools:Tools, next_cursor:Cursor}.
decode_operation_result(call_tool, Raw, Result) :-
    dict_default(Raw, content, [], Content0),
    normalize_model_list(mcp_content_normalize, Content0, Content),
    optional_canonical(Raw, structuredContent, Structured),
    dict_default(Raw, isError, false, IsError),
    Result = mcp_tool_result{content:Content,
                             structured:Structured,
                             is_error:IsError}.
decode_operation_result(list_resources, Raw, Result) :-
    require_key(Raw, resources, Resources0),
    normalize_model_list(mcp_resource_normalize, Resources0, Resources),
    dict_default(Raw, nextCursor, null, Cursor),
    Result = mcp_resources_page{resources:Resources, next_cursor:Cursor}.
decode_operation_result(read_resource, Raw, Result) :-
    require_key(Raw, contents, Contents0),
    require_list(Contents0),
    maplist(normalize_resource_content, Contents0, Contents),
    Result = mcp_resource_result{contents:Contents}.
decode_operation_result(list_prompts, Raw, Result) :-
    require_key(Raw, prompts, Prompts0),
    normalize_model_list(mcp_prompt_normalize, Prompts0, Prompts),
    dict_default(Raw, nextCursor, null, Cursor),
    Result = mcp_prompts_page{prompts:Prompts, next_cursor:Cursor}.
decode_operation_result(get_prompt, Raw, Result) :-
    dict_default(Raw, description, null, Description),
    require_key(Raw, messages, Messages0),
    require_list(Messages0),
    maplist(normalize_prompt_message, Messages0, Messages),
    Result = mcp_prompt_result{description:Description, messages:Messages}.

encode_command_result(Command, CanonicalResult, Wire) :-
    get_dict(op, Command, Operation),
    encode_operation_result(Operation, CanonicalResult, Wire).

encode_operation_result(list_tools, Result, Wire) :-
    require_key(Result, tools, Tools),
    maplist(tool_wire, Tools, WireTools),
    page_wire(WireTools, tools, Result, Wire).
encode_operation_result(call_tool, Result, Wire) :-
    require_key(Result, content, Content),
    maplist(content_wire, Content, WireContent),
    Base = json{content:WireContent},
    optional_result_field(Result, structured, structuredContent, Base, Base1),
    optional_result_field(Result, is_error, isError, Base1, Wire).
encode_operation_result(list_resources, Result, Wire) :-
    require_key(Result, resources, Resources),
    maplist(resource_wire, Resources, WireResources),
    page_wire(WireResources, resources, Result, Wire).
encode_operation_result(read_resource, Result, json{contents:WireContents}) :-
    require_key(Result, contents, Contents),
    maplist(resource_content_wire, Contents, WireContents).
encode_operation_result(list_prompts, Result, Wire) :-
    require_key(Result, prompts, Prompts),
    maplist(prompt_wire, Prompts, WirePrompts),
    page_wire(WirePrompts, prompts, Result, Wire).
encode_operation_result(get_prompt, Result, Wire) :-
    require_key(Result, messages, Messages),
    maplist(prompt_message_wire, Messages, WireMessages),
    Base = json{messages:WireMessages},
    optional_result_field(Result, description, description, Base, Wire).

tool_wire(Tool, Wire) :-
    is_dict(Tool, mcp_tool),
    get_dict(name, Tool, Name), atom_string(Name, NameText),
    get_dict(input_schema, Tool, InputSchema),
    Base = json{name:NameText, inputSchema:InputSchema},
    optional_dict_field(Tool, title, title, Base, B1),
    optional_dict_field(Tool, description, description, B1, B2),
    optional_dict_field(Tool, output_schema, outputSchema, B2, B3),
    optional_dict_field(Tool, annotations, annotations, B3, B4),
    optional_dict_field(Tool, icons, icons, B4, Wire).

resource_wire(Resource, Wire) :-
    is_dict(Resource, mcp_resource),
    get_dict(uri, Resource, Uri),
    get_dict(name, Resource, Name),
    Base = json{uri:Uri, name:Name},
    optional_dict_field(Resource, title, title, Base, B1),
    optional_dict_field(Resource, description, description, B1, B2),
    optional_dict_field(Resource, mime_type, mimeType, B2, B3),
    optional_dict_field(Resource, size, size, B3, B4),
    optional_dict_field(Resource, annotations, annotations, B4, B5),
    optional_dict_field(Resource, icons, icons, B5, Wire).

prompt_wire(Prompt, Wire) :-
    is_dict(Prompt, mcp_prompt),
    get_dict(name, Prompt, Name), atom_string(Name, NameText),
    Base = json{name:NameText},
    optional_dict_field(Prompt, title, title, Base, B1),
    optional_dict_field(Prompt, description, description, B1, B2),
    optional_dict_field(Prompt, arguments, arguments, B2, B3),
    optional_dict_field(Prompt, icons, icons, B3, Wire).

content_wire(Content, Wire) :-
    get_dict(type, Content, Type),
    content_wire_type(Type, Content, Wire).
content_wire_type(text, Content, json{type:"text", text:Text}) :-
    get_dict(text, Content, Text).
content_wire_type(image, Content, json{type:"image", data:Data, mimeType:Mime}) :-
    get_dict(data, Content, Data), get_dict(mime_type, Content, Mime).
content_wire_type(audio, Content, json{type:"audio", data:Data, mimeType:Mime}) :-
    get_dict(data, Content, Data), get_dict(mime_type, Content, Mime).
content_wire_type(resource_link, Content, Wire) :-
    get_dict(uri, Content, Uri),
    get_dict(name, Content, Name),
    get_dict(mime_type, Content, Mime),
    Base = json{type:"resource_link", uri:Uri, name:Name},
    put_optional(mimeType, Mime, Base, Wire).
content_wire_type(resource, Content, json{type:"resource", resource:Resource}) :-
    get_dict(resource, Content, Resource).

normalize_resource_content(Input, Content) :-
    is_dict(Input),
    require_key(Input, uri, Uri),
    dict_default(Input, mimeType, null, MimeType),
    (   get_dict(text, Input, Text)
    ->  Content = mcp_resource_content{uri:Uri,
                                       mime_type:MimeType,
                                       type:text,
                                       data:Text}
    ;   get_dict(blob, Input, Blob)
    ->  Content = mcp_resource_content{uri:Uri,
                                       mime_type:MimeType,
                                       type:blob,
                                       data:Blob}
    ;   throw(mcp_2026_fault(invalid_resource_content(Input)))
    ).

resource_content_wire(Content, Wire) :-
    get_dict(uri, Content, Uri),
    get_dict(mime_type, Content, MimeType),
    get_dict(type, Content, Type),
    get_dict(data, Content, Data),
    Base = json{uri:Uri},
    put_optional(mimeType, MimeType, Base, B1),
    (   Type == text
    ->  put_dict(text, B1, Data, Wire)
    ;   Type == blob
    ->  put_dict(blob, B1, Data, Wire)
    ;   throw(mcp_2026_fault(invalid_resource_content_type(Type)))
    ).

normalize_prompt_message(Input, Message) :-
    is_dict(Input),
    require_key(Input, role, Role0),
    normalize_prompt_role(Role0, Role),
    require_key(Input, content, Content0),
    require_model_ok(mcp_content_normalize(Content0), Content),
    Message = mcp_prompt_message{role:Role, content:Content}.

prompt_message_wire(Message, json{role:RoleText, content:WireContent}) :-
    get_dict(role, Message, Role), atom_string(Role, RoleText),
    get_dict(content, Message, Content), content_wire(Content, WireContent).

page_wire(Items, Key, Result, Wire) :-
    put_dict(Key, json{}, Items, Base),
    (   get_dict(next_cursor, Result, Cursor), Cursor \== null
    ->  put_dict(nextCursor, Base, Cursor, Wire)
    ;   Wire = Base
    ).

optional_result_field(Result, SourceKey, WireKey, Base, Wire) :-
    (   get_dict(SourceKey, Result, Value), Value \== none, Value \== null
    ->  put_dict(WireKey, Base, Value, Wire)
    ;   Wire = Base
    ).
optional_dict_field(Source, SourceKey, WireKey, Base, Wire) :-
    (   get_dict(SourceKey, Source, Value), Value \== none, Value \== null
    ->  put_dict(WireKey, Base, Value, Wire)
    ;   Wire = Base
    ).
put_optional(_, none, Base, Base) :- !.
put_optional(_, null, Base, Base) :- !.
put_optional(Key, Value, Base, Wire) :- put_dict(Key, Base, Value, Wire).

/* Capability and metadata normalization -------------------------------- */

require_server_capability_if_known(State, Command) :-
    get_dict(server_capabilities, State, ServerCaps),
    (   ServerCaps == none
    ->  true
    ;   require_declared_capability(ServerCaps, Command)
    ).

require_declared_capability(Capabilities, Command) :-
    mcp_command_capability(Command, Capability),
    get_dict(Capability, Capabilities, Value),
    (   Value \== none
    ->  true
    ;   throw(mcp_2026_fault(capability_not_negotiated(Capability)))
    ).

capabilities_wire(Capabilities, Wire) :-
    capability_pairs([tools, resources, prompts, logging, completions,
                      roots, sampling, elicitation, experimental, extensions],
                     Capabilities,
                     Pairs),
    dict_pairs(Wire, json, Pairs).

capability_pairs([], _, []).
capability_pairs([Key|Keys], Capabilities, Pairs) :-
    capability_pairs(Keys, Capabilities, Rest),
    (   get_dict(Key, Capabilities, Value), Value \== none
    ->  Pairs = [Key-Value|Rest]
    ;   Pairs = Rest
    ).

normalize_implementation(Input, Info) :-
    is_dict(Input),
    require_key(Input, name, Name0), require_text(Name0, Name),
    require_key(Input, version, Version0), require_text(Version0, Version),
    Info = mcp_implementation{name:Name, version:Version}.

implementation_wire(Info, json{name:Name, version:Version}) :-
    get_dict(name, Info, Name),
    get_dict(version, Info, Version).

result_meta(ServerInfo,
            json{'io.modelcontextprotocol/serverInfo':ServerInfoWire}) :-
    implementation_wire(ServerInfo, ServerInfoWire).

result_server_info(Result, ServerInfo) :-
    (   get_dict('_meta', Result, Meta),
        is_dict(Meta),
        get_dict('io.modelcontextprotocol/serverInfo', Meta, Info0)
    ->  normalize_implementation(Info0, ServerInfo)
    ;   ServerInfo = none
    ).

normalize_versions(Versions0, Versions) :-
    require_list(Versions0),
    maplist(normalize_protocol_version, Versions0, Versions).

normalize_protocol_version(Value, Value) :- atom(Value), !.
normalize_protocol_version(Value, Version) :-
    string(Value), !, atom_string(Version, Value).
normalize_protocol_version(Value, _) :-
    throw(mcp_2026_fault(invalid_protocol_version(Value))).

normalize_prompt_role(Value, Role) :-
    normalize_protocol_version(Value, Role),
    memberchk(Role, [user, assistant]),
    !.
normalize_prompt_role(Value, _) :-
    throw(mcp_2026_fault(invalid_prompt_role(Value))).

/* Validation and errors ------------------------------------------------- */

require_client_state(State) :-
    (   is_dict(State, mcp_2026_client)
    ->  true
    ;   throw(mcp_2026_fault(invalid_client_state(State)))
    ).

require_server_state(State) :-
    (   is_dict(State, mcp_2026_server)
    ->  true
    ;   throw(mcp_2026_fault(invalid_server_state(State)))
    ).

require_transport_kind(Kind) :-
    (   memberchk(Kind, [stdio, streamable_http])
    ->  true
    ;   throw(mcp_2026_fault(invalid_transport_kind(Kind)))
    ).

require_transport_response(Response) :-
    (   is_dict(Response, mcp_transport_response)
    ->  true
    ;   throw(mcp_2026_fault(invalid_transport_response(Response)))
    ).

require_jsonrpc_request(Wire, Id, Method, Params) :-
    is_dict(Wire),
    require_key(Wire, jsonrpc, JsonRpc),
    ( JsonRpc == "2.0" -> true ; throw(mcp_2026_fault(invalid_jsonrpc(JsonRpc))) ),
    require_key(Wire, id, Id), require_jsonrpc_id(Id),
    require_key(Wire, method, Method0), require_text(Method0, Method),
    require_key(Wire, params, Params),
    ( is_dict(Params) -> true ; throw(mcp_2026_fault(invalid_params(Params))) ).

require_jsonrpc_id(Id) :- (integer(Id);string(Id);atom(Id)), !.
require_jsonrpc_id(Id) :- throw(mcp_2026_fault(invalid_jsonrpc_id(Id))).

require_success_status(Status) :-
    integer(Status), Status >= 200, Status < 300, !.
require_success_status(Status) :- throw(mcp_2026_fault(http_status(Status))).

require_request_headers(RequestMeta, Headers) :-
    (   is_dict(RequestMeta), get_dict(headers, RequestMeta, Headers), is_list(Headers)
    ->  true
    ;   throw(mcp_2026_fault(header_mismatch(headers, required, missing)))
    ).

require_header(Headers, Name, Value) :-
    (   memberchk(Name=Value, Headers)
    ->  true
    ;   throw(mcp_2026_fault(header_mismatch(Name, required, missing)))
    ).

require_key(Dict, Key, Value) :-
    (   is_dict(Dict), get_dict(Key, Dict, Value)
    ->  true
    ;   throw(mcp_2026_fault(missing_key(Key)))
    ).

dict_default(Dict, Key, Default, Value) :-
    (   is_dict(Dict), get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

require_text(Value, Value) :- string(Value), !.
require_text(Value, Text) :- atom(Value), !, atom_string(Value, Text).
require_text(Value, _) :- throw(mcp_2026_fault(expected_text(Value))).

require_list(Value) :-
    ( is_list(Value) -> true ; throw(mcp_2026_fault(expected_list(Value))) ).

optional_canonical(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Raw), Raw \== null
    ->  mcp_json_canonical(Raw, Value)
    ;   Value = none
    ).

normalize_model_list(Normalizer, Inputs, Outputs) :-
    require_list(Inputs),
    maplist(normalize_model_one(Normalizer), Inputs, Outputs).

normalize_model_one(Normalizer, Input, Output) :-
    call(Normalizer, Input, Outcome),
    (   Outcome = ok(Output)
    ->  true
    ;   Outcome = error(Error),
        throw(mcp_2026_fault(canonical_error(Error)))
    ).

require_model_ok(Closure, Value) :-
    call(Closure, Outcome),
    (   Outcome = ok(Value)
    ->  true
    ;   Outcome = error(Error),
        throw(mcp_2026_fault(canonical_error(Error)))
    ).

error_data(Error, Data) :-
    (   get_dict(error_data, Error, Data0)
    ->  Data = Data0
    ;   Data = json{}
    ).

adapter_status(Operation, Goal, Outcome) :-
    catch((call(Goal), Result=ok),
          Exception,
          adapter_exception(Operation, Exception, Result)),
    Outcome = Result.

adapter_outcome(Operation, Goal, Outcome) :-
    catch((call(Goal, Value), Result=ok(Value)),
          Exception,
          adapter_exception(Operation, Exception, Result)),
    Outcome = Result.

adapter_exception(_, mcp_2026_fault(unsupported_by_peer(Requested, Supported)),
                  error(Error)) :-
    !,
    Error = mcp_error{phase:adapter_2026_07_28,
                      kind:unsupported_protocol_version,
                      protocol_version:'2026-07-28',
                      requested:Requested,
                      supported:Supported,
                      jsonrpc_code:-32022,
                      http_status:400,
                      error_data:json{supported:Supported, requested:Requested},
                      message:"MCP peer does not support the requested protocol version"}.
adapter_exception(_, mcp_2026_fault(unsupported_protocol_version(Requested)),
                  error(Error)) :-
    !,
    mcp_2026_protocol_version(Version),
    Error = mcp_error{phase:adapter_2026_07_28,
                      kind:unsupported_protocol_version,
                      protocol_version:Version,
                      requested:Requested,
                      supported:[Version, '2025-11-25'],
                      jsonrpc_code:-32022,
                      http_status:400,
                      error_data:json{supported:[Version, '2025-11-25'],
                                      requested:Requested},
                      message:"Unsupported MCP protocol version"}.
adapter_exception(_, mcp_2026_fault(header_mismatch(Field, Expected, Actual)),
                  error(Error)) :-
    !,
    Error = mcp_error{phase:adapter_2026_07_28,
                      kind:header_mismatch,
                      protocol_version:'2026-07-28',
                      detail:header_mismatch(Field, Expected, Actual),
                      jsonrpc_code:-32020,
                      http_status:400,
                      error_data:json{field:Field, expected:Expected, actual:Actual},
                      message:"MCP request metadata does not match the request body"}.
adapter_exception(Operation, mcp_2026_fault(Detail), error(Error)) :-
    !,
    Error = mcp_error{phase:adapter_2026_07_28,
                      kind:protocol_error,
                      operation:Operation,
                      detail:Detail,
                      protocol_version:'2026-07-28',
                      message:"MCP 2026-07-28 protocol operation failed"}.
adapter_exception(Operation, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = mcp_error{phase:adapter_2026_07_28,
                      kind:exception,
                      operation:Operation,
                      exception:Safe,
                      protocol_version:'2026-07-28',
                      message:"MCP 2026-07-28 adapter raised an exception"}.
