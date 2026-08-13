:- module(rlm_mcp_v2025_11_25,
          [ mcp_2025_protocol_version/1,
            mcp_2025_client_state_new/4,
            mcp_2025_client_initialize/5,
            mcp_2025_client_accept_initialize/5,
            mcp_2025_client_initialized/4,
            mcp_2025_client_command/6,
            mcp_2025_client_decode/4,
            mcp_2025_client_decode/5,
            mcp_2025_client_notification/3,
            mcp_2025_client_recover_404/2,
            mcp_2025_server_state_new/5,
            mcp_2025_server_receive/5,
            mcp_2025_server_initialize_response/5,
            mcp_2025_server_command_response/6,
            mcp_2025_server_notification/4
          ]).

/** <module> MCP 2025-11-25 protocol adapter

This module is the only place where 2025-11-25 method names, JSON-RPC envelope
fields, protocol headers, initialization phases, and Streamable HTTP session
semantics are interpreted.
*/

:- use_module(rlm_mcp_model).

mcp_2025_protocol_version('2025-11-25').

mcp_2025_client_state_new(ClientInfo0, ClientCaps0, Transport, Outcome) :-
    adapter_outcome(client_state,
                    client_state_new(ClientInfo0, ClientCaps0, Transport),
                    Outcome).

client_state_new(ClientInfo0, ClientCaps0, Transport, State) :-
    normalize_implementation(ClientInfo0, ClientInfo),
    require_model_ok(mcp_capabilities_normalize(client, ClientCaps0), ClientCaps),
    require_transport_kind(Transport),
    State = mcp_2025_client{phase:new,
                            client_info:ClientInfo,
                            client_capabilities:ClientCaps,
                            server_info:none,
                            server_capabilities:none,
                            protocol_version:null,
                            session_id:null,
                            transport:Transport,
                            reinitialize_count:0,
                            reinitialize_limit:1}.

mcp_2025_client_initialize(State, Id, Wire, Meta, Outcome) :-
    adapter_status(client_initialize,
                   client_initialize(State, Id, Wire, Meta),
                   Outcome).

client_initialize(State, Id, Wire, Meta) :-
    require_phase(State, mcp_2025_client, new),
    require_jsonrpc_id(Id),
    get_dict(client_info, State, ClientInfo),
    get_dict(client_capabilities, State, ClientCaps),
    implementation_wire(ClientInfo, ClientInfoWire),
    capabilities_wire(ClientCaps, CapabilitiesWire),
    mcp_2025_protocol_version(Version),
    Params = json{protocolVersion:Version,
                  capabilities:CapabilitiesWire,
                  clientInfo:ClientInfoWire},
    Wire = json{jsonrpc:"2.0", id:Id, method:"initialize", params:Params},
    request_meta(State, initialize, Meta).

mcp_2025_client_accept_initialize(State0, ExpectedId, Response,
                                  State, Outcome) :-
    adapter_status(client_initialize_response,
                   client_accept_initialize(State0, ExpectedId, Response, State),
                   Outcome).

client_accept_initialize(State0, ExpectedId, Response, State) :-
    require_phase(State0, mcp_2025_client, new),
    require_jsonrpc_id(ExpectedId),
    require_transport_response(Response),
    get_dict(status, Response, Status),
    require_success_status(Status),
    get_dict(body, Response, Body),
    require_jsonrpc_result(Body, ExpectedId, InitializeResult),
    require_key(InitializeResult, protocolVersion, Version0),
    normalize_protocol_version(Version0, Version),
    mcp_2025_protocol_version(Version),
    require_key(InitializeResult, serverInfo, ServerInfo0),
    normalize_implementation(ServerInfo0, ServerInfo),
    require_key(InitializeResult, capabilities, ServerCaps0),
    require_model_ok(mcp_capabilities_normalize(server, ServerCaps0), ServerCaps),
    response_session_id(Response, SessionId),
    put_dict(_{phase:initialized_pending,
               server_info:ServerInfo,
               server_capabilities:ServerCaps,
               protocol_version:Version,
               session_id:SessionId}, State0, State).

mcp_2025_client_initialized(State0, Wire, Meta, Outcome) :-
    adapter_outcome(client_initialized,
                    client_initialized(State0, Wire, Meta),
                    Outcome).

client_initialized(State0, Wire, Meta, State) :-
    require_phase(State0, mcp_2025_client, initialized_pending),
    Wire = json{jsonrpc:"2.0", method:"notifications/initialized"},
    request_meta(State0, operation, Meta),
    put_dict(phase, State0, ready, State).

mcp_2025_client_command(State, Id, Command0, Wire, Meta, Outcome) :-
    adapter_outcome(client_command,
                    client_command(State, Id, Command0, Wire, Meta),
                    Outcome).

client_command(State, Id, Command0, Wire, Meta, Command) :-
    require_phase(State, mcp_2025_client, ready),
    require_jsonrpc_id(Id),
    require_model_ok(mcp_command_normalize(Command0), Command),
    get_dict(server_capabilities, State, ServerCaps),
    require_declared_capability(ServerCaps, Command),
    encode_command(Command, Method, Params),
    Wire = json{jsonrpc:"2.0", id:Id, method:Method, params:Params},
    request_meta(State, operation, Meta).

mcp_2025_client_decode(State, Command, Response, Outcome) :-
    mcp_2025_client_decode(State, any, Command, Response, Outcome).

mcp_2025_client_decode(State, ExpectedId, Command0, Response, Outcome) :-
    adapter_outcome(client_decode,
                    client_decode(State, ExpectedId, Command0, Response),
                    Outcome).

client_decode(State, ExpectedId, Command0, Response, Result) :-
    require_phase(State, mcp_2025_client, ready),
    require_model_ok(mcp_command_normalize(Command0), Command),
    require_transport_response(Response),
    get_dict(status, Response, Status),
    require_success_status(Status),
    get_dict(body, Response, Body),
    decode_jsonrpc_body(Body, ExpectedId, RawResult),
    decode_command_result(Command, RawResult, Result).

mcp_2025_client_notification(State, Wire, Outcome) :-
    adapter_outcome(client_notification, client_notification(State, Wire), Outcome).

client_notification(State, Wire, Notification) :-
    require_phase(State, mcp_2025_client, ready),
    require_key(Wire, method, Method),
    dict_default(Wire, params, json{}, Params),
    decode_notification(Method, Params, Notification0),
    require_model_ok(mcp_notification_normalize(Notification0), Notification).

mcp_2025_client_recover_404(State0, Outcome) :-
    (   is_dict(State0, mcp_2025_client),
        get_dict(transport, State0, streamable_http),
        get_dict(session_id, State0, SessionId), SessionId \== null,
        get_dict(reinitialize_count, State0, Count0),
        get_dict(reinitialize_limit, State0, Limit), Count0 < Limit
    ->  Count is Count0+1,
        put_dict(_{phase:new,
                   server_info:none,
                   server_capabilities:none,
                   protocol_version:null,
                   session_id:null,
                   reinitialize_count:Count}, State0, State),
        Outcome = ok(State)
    ;   Outcome = error(mcp_error{phase:session,
                                  kind:reinitialize_exhausted,
                                  protocol_version:'2025-11-25',
                                  message:"MCP 2025 session recovery budget exhausted"})
    ).

mcp_2025_server_state_new(ServerInfo0, ServerCaps0, Transport,
                          Session0, Outcome) :-
    adapter_outcome(server_state,
                    server_state_new(ServerInfo0, ServerCaps0, Transport, Session0),
                    Outcome).

server_state_new(ServerInfo0, ServerCaps0, Transport, Session0, State) :-
    normalize_implementation(ServerInfo0, ServerInfo),
    require_model_ok(mcp_capabilities_normalize(server, ServerCaps0), ServerCaps),
    require_transport_kind(Transport),
    normalize_server_session(Transport, Session0, SessionId),
    State = mcp_2025_server{phase:new,
                            server_info:ServerInfo,
                            server_capabilities:ServerCaps,
                            client_info:none,
                            client_capabilities:none,
                            protocol_version:null,
                            transport:Transport,
                            session_id:SessionId}.

mcp_2025_server_receive(State0, Wire, RequestMeta, Event, Outcome) :-
    adapter_outcome(server_receive,
                    server_receive(State0, Wire, RequestMeta, Event),
                    Outcome).

server_receive(State0, Wire, RequestMeta, Event, State) :-
    get_dict(phase, State0, Phase),
    server_receive_phase(Phase, State0, Wire, RequestMeta, Event, State).

server_receive_phase(new, State0, Wire, _, Event, State) :-
    require_wire_method(Wire, "initialize"),
    require_key(Wire, id, Id),
    require_jsonrpc_id(Id),
    require_key(Wire, params, Params),
    require_key(Params, protocolVersion, Version0),
    normalize_protocol_version(Version0, Version),
    mcp_2025_protocol_version(Version),
    require_key(Params, clientInfo, ClientInfo0),
    normalize_implementation(ClientInfo0, ClientInfo),
    require_key(Params, capabilities, ClientCaps0),
    require_model_ok(mcp_capabilities_normalize(client, ClientCaps0), ClientCaps),
    put_dict(_{phase:initialized_pending,
               client_info:ClientInfo,
               client_capabilities:ClientCaps,
               protocol_version:Version}, State0, State),
    Event = initialize(Id, ClientInfo, ClientCaps).
server_receive_phase(initialized_pending, State0, Wire, RequestMeta,
                     initialized, State) :-
    require_wire_method(Wire, "notifications/initialized"),
    require_operation_meta(State0, RequestMeta),
    put_dict(phase, State0, ready, State).
server_receive_phase(ready, State0, Wire, RequestMeta,
                     command(Id, Command), State0) :-
    require_operation_meta(State0, RequestMeta),
    require_key(Wire, id, Id),
    require_jsonrpc_id(Id),
    require_key(Wire, method, Method),
    dict_default(Wire, params, json{}, Params),
    decode_command(Method, Params, Command0),
    require_model_ok(mcp_command_normalize(Command0), Command),
    get_dict(server_capabilities, State0, ServerCaps),
    require_declared_capability(ServerCaps, Command),
    !.
server_receive_phase(ready, State0, Wire, RequestMeta,
                     notification(Notification), State0) :-
    require_operation_meta(State0, RequestMeta),
    \+ get_dict(id, Wire, _),
    require_key(Wire, method, Method),
    dict_default(Wire, params, json{}, Params),
    decode_notification(Method, Params, Notification0),
    require_model_ok(mcp_notification_normalize(Notification0), Notification),
    !.
server_receive_phase(Phase, _, Wire, _, _, _) :-
    throw(mcp_adapter_fault(unexpected_server_message(Phase, Wire))).

mcp_2025_server_initialize_response(State, Id, Wire, ResponseMeta, Outcome) :-
    adapter_status(server_initialize_response,
                   server_initialize_response(State, Id, Wire, ResponseMeta),
                   Outcome).

server_initialize_response(State, Id, Wire, ResponseMeta) :-
    require_phase(State, mcp_2025_server, initialized_pending),
    require_jsonrpc_id(Id),
    get_dict(server_info, State, ServerInfo),
    get_dict(server_capabilities, State, ServerCaps),
    implementation_wire(ServerInfo, ServerInfoWire),
    capabilities_wire(ServerCaps, CapabilitiesWire),
    mcp_2025_protocol_version(Version),
    Result = json{protocolVersion:Version,
                  capabilities:CapabilitiesWire,
                  serverInfo:ServerInfoWire},
    Wire = json{jsonrpc:"2.0", id:Id, result:Result},
    response_meta(State, ResponseMeta).

mcp_2025_server_command_response(State, Id, Command0, CanonicalResult,
                                 Wire, Outcome) :-
    adapter_status(server_command_response,
                   server_command_response(State, Id, Command0,
                                           CanonicalResult, Wire),
                   Outcome).

server_command_response(State, Id, Command0, CanonicalResult, Wire) :-
    require_phase(State, mcp_2025_server, ready),
    require_jsonrpc_id(Id),
    require_model_ok(mcp_command_normalize(Command0), Command),
    encode_command_result(Command, CanonicalResult, ResultBody),
    Wire = json{jsonrpc:"2.0", id:Id, result:ResultBody}.

mcp_2025_server_notification(State, Notification0, Wire, Outcome) :-
    adapter_status(server_notification,
                   server_notification(State, Notification0, Wire), Outcome).

server_notification(State, Notification0, Wire) :-
    require_phase(State, mcp_2025_server, ready),
    require_model_ok(mcp_notification_normalize(Notification0), Notification),
    encode_notification(Notification, Method, Params),
    Wire = json{jsonrpc:"2.0", method:Method, params:Params}.

encode_command(Command, Method, Params) :-
    get_dict(op, Command, Operation),
    encode_operation(Operation, Command, Method, Params).

encode_operation(list_tools, Command, "tools/list", Params) :-
    get_dict(cursor, Command, Cursor), cursor_params(Cursor, Params).
encode_operation(call_tool, Command, "tools/call", Params) :-
    get_dict(name, Command, Name), atom_string(Name, NameText),
    get_dict(arguments, Command, Arguments),
    Params = json{name:NameText, arguments:Arguments}.
encode_operation(list_resources, Command, "resources/list", Params) :-
    get_dict(cursor, Command, Cursor), cursor_params(Cursor, Params).
encode_operation(read_resource, Command, "resources/read", json{uri:Uri}) :-
    get_dict(uri, Command, Uri).
encode_operation(list_prompts, Command, "prompts/list", Params) :-
    get_dict(cursor, Command, Cursor), cursor_params(Cursor, Params).
encode_operation(get_prompt, Command, "prompts/get", Params) :-
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
    throw(mcp_adapter_fault(unsupported_method(Method))).

decode_jsonrpc_body(Body, _, _) :-
    is_dict(Body), get_dict(error, Body, Error0), !,
    normalize_remote_error(Error0, Error),
    throw(mcp_adapter_fault(remote_error(Error))).
decode_jsonrpc_body(Body, ExpectedId, Result) :-
    is_dict(Body), validate_response_id(Body, ExpectedId),
    require_key(Body, result, Result), !.
decode_jsonrpc_body(Body, _, _) :-
    throw(mcp_adapter_fault(invalid_jsonrpc_response(Body))).

validate_response_id(_, any) :- !.
validate_response_id(Body, ExpectedId) :-
    require_key(Body, id, ActualId),
    ( ActualId == ExpectedId -> true
    ; throw(mcp_adapter_fault(response_id_mismatch(ExpectedId, ActualId))) ).

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
    Result = mcp_tool_result{content:Content, structured:Structured,
                             is_error:IsError}.
decode_operation_result(list_resources, Raw, Result) :-
    require_key(Raw, resources, Resources0),
    normalize_model_list(mcp_resource_normalize, Resources0, Resources),
    dict_default(Raw, nextCursor, null, Cursor),
    Result = mcp_resources_page{resources:Resources, next_cursor:Cursor}.
decode_operation_result(read_resource, Raw, Result) :-
    require_key(Raw, contents, Contents0), require_list(Contents0),
    maplist(normalize_resource_content, Contents0, Contents),
    Result = mcp_resource_result{contents:Contents}.
decode_operation_result(list_prompts, Raw, Result) :-
    require_key(Raw, prompts, Prompts0),
    normalize_model_list(mcp_prompt_normalize, Prompts0, Prompts),
    dict_default(Raw, nextCursor, null, Cursor),
    Result = mcp_prompts_page{prompts:Prompts, next_cursor:Cursor}.
decode_operation_result(get_prompt, Raw, Result) :-
    dict_default(Raw, description, null, Description),
    require_key(Raw, messages, Messages0), require_list(Messages0),
    maplist(normalize_prompt_message, Messages0, Messages),
    Result = mcp_prompt_result{description:Description, messages:Messages}.

encode_command_result(Command, CanonicalResult, Wire) :-
    get_dict(op, Command, Operation),
    encode_operation_result(Operation, CanonicalResult, Wire).

encode_operation_result(list_tools, Result, Wire) :-
    require_key(Result, tools, Tools), maplist(tool_wire, Tools, WireTools),
    page_wire(WireTools, tools, Result, Wire).
encode_operation_result(call_tool, Result, Wire) :-
    require_key(Result, content, Content), maplist(content_wire, Content, WireContent),
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
    require_key(Result, prompts, Prompts), maplist(prompt_wire, Prompts, WirePrompts),
    page_wire(WirePrompts, prompts, Result, Wire).
encode_operation_result(get_prompt, Result, Wire) :-
    require_key(Result, messages, Messages),
    maplist(prompt_message_wire, Messages, WireMessages),
    Base = json{messages:WireMessages},
    optional_result_field(Result, description, description, Base, Wire).

normalize_resource_content(Input, Content) :-
    is_dict(Input), require_key(Input, uri, Uri),
    dict_default(Input, mimeType, null, MimeType),
    ( get_dict(text, Input, Text)
    -> Content = mcp_resource_content{uri:Uri, mime_type:MimeType,
                                      type:text, data:Text}
    ; get_dict(blob, Input, Blob)
    -> Content = mcp_resource_content{uri:Uri, mime_type:MimeType,
                                      type:blob, data:Blob}
    ; throw(mcp_adapter_fault(invalid_resource_content(Input))) ).

normalize_prompt_message(Input, Message) :-
    is_dict(Input), require_key(Input, role, Role0),
    normalize_prompt_role(Role0, Role), require_key(Input, content, Content0),
    require_model_ok(mcp_content_normalize(Content0), Content),
    Message = mcp_prompt_message{role:Role, content:Content}.

tool_wire(Tool, Wire) :-
    is_dict(Tool, mcp_tool), get_dict(name, Tool, Name), atom_string(Name, NameText),
    get_dict(input_schema, Tool, InputSchema),
    Base = json{name:NameText, inputSchema:InputSchema},
    optional_dict_field(Tool, title, title, Base, B1),
    optional_dict_field(Tool, description, description, B1, B2),
    optional_dict_field(Tool, output_schema, outputSchema, B2, B3),
    optional_dict_field(Tool, annotations, annotations, B3, B4),
    optional_dict_field(Tool, icons, icons, B4, Wire).

resource_wire(Resource, Wire) :-
    is_dict(Resource, mcp_resource), get_dict(uri, Resource, Uri),
    get_dict(name, Resource, Name), Base = json{uri:Uri, name:Name},
    optional_dict_field(Resource, title, title, Base, B1),
    optional_dict_field(Resource, description, description, B1, B2),
    optional_dict_field(Resource, mime_type, mimeType, B2, B3),
    optional_dict_field(Resource, size, size, B3, B4),
    optional_dict_field(Resource, annotations, annotations, B4, B5),
    optional_dict_field(Resource, icons, icons, B5, Wire).

prompt_wire(Prompt, Wire) :-
    is_dict(Prompt, mcp_prompt), get_dict(name, Prompt, Name), atom_string(Name, NameText),
    Base = json{name:NameText},
    optional_dict_field(Prompt, title, title, Base, B1),
    optional_dict_field(Prompt, description, description, B1, B2),
    optional_dict_field(Prompt, arguments, arguments, B2, B3),
    optional_dict_field(Prompt, icons, icons, B3, Wire).

content_wire(Content, Wire) :-
    get_dict(type, Content, Type), content_wire_type(Type, Content, Wire).
content_wire_type(text, Content, json{type:"text", text:Text}) :-
    get_dict(text, Content, Text).
content_wire_type(image, Content, json{type:"image", data:Data, mimeType:Mime}) :-
    get_dict(data, Content, Data), get_dict(mime_type, Content, Mime).
content_wire_type(audio, Content, json{type:"audio", data:Data, mimeType:Mime}) :-
    get_dict(data, Content, Data), get_dict(mime_type, Content, Mime).
content_wire_type(resource_link, Content, Wire) :-
    get_dict(uri, Content, Uri), get_dict(name, Content, Name),
    get_dict(mime_type, Content, Mime), Base = json{type:"resource_link",uri:Uri,name:Name},
    put_optional(mimeType, Mime, Base, Wire).
content_wire_type(resource, Content, json{type:"resource", resource:Resource}) :-
    get_dict(resource, Content, Resource).

resource_content_wire(Content, Wire) :-
    get_dict(uri, Content, Uri), get_dict(mime_type, Content, MimeType),
    get_dict(type, Content, Type), get_dict(data, Content, Data),
    Base = json{uri:Uri}, put_optional(mimeType, MimeType, Base, B1),
    ( Type == text -> put_dict(text, B1, Data, Wire)
    ; Type == blob -> put_dict(blob, B1, Data, Wire)
    ; throw(mcp_adapter_fault(invalid_resource_content_type(Type))) ).

prompt_message_wire(Message, json{role:RoleText, content:WireContent}) :-
    get_dict(role, Message, Role), atom_string(Role, RoleText),
    get_dict(content, Message, Content), content_wire(Content, WireContent).

page_wire(Items, Key, Result, Wire) :-
    put_dict(Key, json{}, Items, Base),
    ( get_dict(next_cursor, Result, Cursor), Cursor \== null
    -> put_dict(nextCursor, Base, Cursor, Wire) ; Wire = Base ).

optional_result_field(Result, SourceKey, WireKey, Base, Wire) :-
    ( get_dict(SourceKey, Result, Value), Value \== none, Value \== null
    -> put_dict(WireKey, Base, Value, Wire) ; Wire = Base ).
optional_dict_field(Source, SourceKey, WireKey, Base, Wire) :-
    ( get_dict(SourceKey, Source, Value), Value \== none, Value \== null
    -> put_dict(WireKey, Base, Value, Wire) ; Wire = Base ).
put_optional(_, none, Base, Base) :- !.
put_optional(_, null, Base, Base) :- !.
put_optional(Key, Value, Base, Wire) :- put_dict(Key, Base, Value, Wire).

decode_notification("notifications/tools/list_changed", _, tools_list_changed) :- !.
decode_notification("notifications/resources/list_changed", _, resources_list_changed) :- !.
decode_notification("notifications/prompts/list_changed", _, prompts_list_changed) :- !.
decode_notification("notifications/resources/updated", Params, resource_updated(Uri)) :-
    !, require_key(Params, uri, Uri).
decode_notification(Method, _, _) :-
    throw(mcp_adapter_fault(unsupported_notification(Method))).

encode_notification(Notification, Method, Params) :-
    get_dict(type, Notification, Type),
    encode_notification_type(Type, Notification, Method, Params).
encode_notification_type(tools_list_changed, _,
                         "notifications/tools/list_changed", json{}).
encode_notification_type(resources_list_changed, _,
                         "notifications/resources/list_changed", json{}).
encode_notification_type(prompts_list_changed, _,
                         "notifications/prompts/list_changed", json{}).
encode_notification_type(resource_updated, Notification,
                         "notifications/resources/updated", json{uri:Uri}) :-
    get_dict(uri, Notification, Uri).

require_declared_capability(Capabilities, Command) :-
    mcp_command_capability(Command, Capability), get_dict(Capability, Capabilities, Value),
    ( Value \== none -> true
    ; throw(mcp_adapter_fault(capability_not_negotiated(Capability))) ).

capabilities_wire(Capabilities, Wire) :-
    capability_pairs([tools,resources,prompts,logging,completions,
                      roots,sampling,elicitation,experimental],
                     Capabilities, Pairs),
    dict_pairs(Wire, json, Pairs).
capability_pairs([], _, []).
capability_pairs([Key|Keys], Capabilities, Pairs) :-
    get_dict(Key, Capabilities, Value), capability_pairs(Keys, Capabilities, Rest),
    ( Value == none -> Pairs = Rest ; Pairs = [Key-Value|Rest] ).

request_meta(State, Phase, Meta) :-
    get_dict(transport, State, Transport),
    request_headers(Transport, Phase, State, Headers),
    Meta = mcp_transport_request{headers:Headers,
                                 protocol_version:'2025-11-25',
                                 transport:Transport}.
request_headers(stdio, _, _, []) :- !.
request_headers(streamable_http, initialize, _,
                ['Accept'='application/json, text/event-stream']) :- !.
request_headers(streamable_http, operation, State, Headers) :-
    mcp_2025_protocol_version(Version),
    Base = ['Accept'='application/json, text/event-stream',
            'MCP-Protocol-Version'=Version],
    get_dict(session_id, State, SessionId),
    ( SessionId == null -> Headers = Base
    ; append(Base, ['MCP-Session-Id'=SessionId], Headers) ).

response_meta(State, mcp_transport_response_meta{headers:Headers}) :-
    get_dict(transport, State, Transport), get_dict(session_id, State, SessionId),
    ( Transport == streamable_http, SessionId \== null
    -> Headers = ['MCP-Session-Id'=SessionId] ; Headers = [] ).

require_operation_meta(State, _) :- get_dict(transport, State, stdio), !.
require_operation_meta(State, Meta) :-
    is_dict(Meta), require_key(Meta, headers, Headers),
    memberchk('MCP-Protocol-Version'='2025-11-25', Headers),
    get_dict(session_id, State, SessionId), require_session_header(SessionId, Headers).
require_session_header(null, _) :- !.
require_session_header(SessionId, Headers) :-
    ( memberchk('MCP-Session-Id'=SessionId, Headers) -> true
    ; throw(mcp_adapter_fault(invalid_session)) ).

response_session_id(Response, SessionId) :-
    get_dict(headers, Response, Headers),
    ( is_dict(Headers), get_dict('mcp-session-id', Headers, Raw), Raw \== "", Raw \== ''
    -> normalize_session_id(Raw, SessionId) ; SessionId = null ).

normalize_implementation(Input, Info) :-
    is_dict(Input), require_key(Input, name, Name0), require_text(Name0, Name),
    require_key(Input, version, Version0), require_text(Version0, Version),
    Info = mcp_implementation{name:Name, version:Version}.
implementation_wire(Info, json{name:Name, version:Version}) :-
    get_dict(name, Info, Name), get_dict(version, Info, Version).

normalize_server_session(stdio, _, null) :- !.
normalize_server_session(streamable_http, null, null) :- !.
normalize_server_session(streamable_http, Session0, Session) :- normalize_session_id(Session0, Session).
normalize_session_id(Value, Value) :- string(Value), Value \== "", !.
normalize_session_id(Value, Text) :- atom(Value), Value \== '', !, atom_string(Value, Text).
normalize_session_id(Value, _) :- throw(mcp_adapter_fault(invalid_session_id(Value))).

normalize_protocol_version(Value, Value) :- atom(Value), !.
normalize_protocol_version(Value, Version) :- string(Value), !, atom_string(Version, Value).
normalize_protocol_version(Value, _) :- throw(mcp_adapter_fault(invalid_protocol_version(Value))).
normalize_prompt_role(Value, Role) :-
    normalize_protocol_version(Value, Role), memberchk(Role, [user,assistant]), !.
normalize_prompt_role(Value, _) :- throw(mcp_adapter_fault(invalid_prompt_role(Value))).

require_transport_kind(Kind) :- memberchk(Kind, [stdio,streamable_http]), !.
require_transport_kind(Kind) :- throw(mcp_adapter_fault(invalid_transport_kind(Kind))).
require_phase(State, Tag, Phase) :-
    ( is_dict(State, Tag), get_dict(phase, State, Phase) -> true
    ; throw(mcp_adapter_fault(invalid_phase(Tag, Phase))) ).
require_transport_response(Response) :-
    ( is_dict(Response, mcp_transport_response) -> true
    ; throw(mcp_adapter_fault(invalid_transport_response(Response))) ).
require_success_status(Status) :- integer(Status), Status >= 200, Status < 300, !.
require_success_status(Status) :- throw(mcp_adapter_fault(http_status(Status))).

require_jsonrpc_result(Body, ExpectedId, Result) :-
    is_dict(Body),
    ( get_dict(error, Body, Error0)
    -> normalize_remote_error(Error0, Error), throw(mcp_adapter_fault(remote_error(Error)))
    ; validate_response_id(Body, ExpectedId), require_key(Body, result, Result) ).

normalize_remote_error(Input, Error) :-
    ( is_dict(Input)
    -> dict_default(Input, code, null, Code),
       dict_default(Input, message, "MCP peer returned an error", Message),
       optional_canonical(Input, data, Data),
       Error = mcp_remote_error{code:Code,message:Message,data:Data}
    ; Error = mcp_remote_error{code:null,
                               message:"MCP peer returned an invalid error",
                               data:Input} ).

require_wire_method(Wire, Expected) :-
    require_key(Wire, method, Actual),
    ( Actual == Expected -> true
    ; throw(mcp_adapter_fault(expected_method(Expected, Actual))) ).
require_jsonrpc_id(Id) :- (integer(Id);string(Id);atom(Id)), !.
require_jsonrpc_id(Id) :- throw(mcp_adapter_fault(invalid_jsonrpc_id(Id))).
require_key(Dict, Key, Value) :-
    ( is_dict(Dict), get_dict(Key, Dict, Value) -> true
    ; throw(mcp_adapter_fault(missing_key(Key))) ).
dict_default(Dict, Key, Default, Value) :-
    ( is_dict(Dict), get_dict(Key, Dict, Found) -> Value = Found ; Value = Default ).
require_text(Value, Value) :- string(Value), !.
require_text(Value, Text) :- atom(Value), !, atom_string(Value, Text).
require_text(Value, _) :- throw(mcp_adapter_fault(expected_text(Value))).
require_list(Value) :- (is_list(Value) -> true ; throw(mcp_adapter_fault(expected_list(Value)))).
optional_canonical(Dict, Key, Value) :-
    ( get_dict(Key, Dict, Raw), Raw \== null -> mcp_json_canonical(Raw, Value) ; Value = none ).

normalize_model_list(Normalizer, Inputs, Outputs) :-
    require_list(Inputs), maplist(normalize_model_one(Normalizer), Inputs, Outputs).
normalize_model_one(Normalizer, Input, Output) :-
    call(Normalizer, Input, Outcome),
    ( Outcome = ok(Output) -> true
    ; Outcome = error(Error), throw(mcp_adapter_fault(canonical_error(Error))) ).
require_model_ok(Closure, Value) :-
    call(Closure, Outcome),
    ( Outcome = ok(Value) -> true
    ; Outcome = error(Error), throw(mcp_adapter_fault(canonical_error(Error))) ).

adapter_status(Operation, Goal, Outcome) :-
    catch((call(Goal), Result=ok), Exception, adapter_exception(Operation, Exception, Result)),
    Outcome = Result.
adapter_outcome(Operation, Goal, Outcome) :-
    catch((call(Goal, Value), Result=ok(Value)), Exception,
          adapter_exception(Operation, Exception, Result)),
    Outcome = Result.
adapter_exception(_, mcp_adapter_fault(Detail), error(Error)) :-
    !,
    Error = mcp_error{phase:adapter_2025_11_25,
                      kind:protocol_error,
                      detail:Detail,
                      protocol_version:'2025-11-25',
                      message:"MCP 2025-11-25 protocol operation failed"}.
adapter_exception(Operation, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true),numbervars(true)]),
    Error = mcp_error{phase:adapter_2025_11_25,
                      kind:exception,
                      operation:Operation,
                      exception:Safe,
                      protocol_version:'2025-11-25',
                      message:"MCP 2025-11-25 adapter raised an exception"}.
