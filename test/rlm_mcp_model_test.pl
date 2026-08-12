:- begin_tests(rlm_mcp_model).

:- use_module('../prolog/rlm_mcp_model').

test(command_normalization_is_version_neutral) :-
    mcp_command_normalize(call_tool("lookup", _{query:"x"}), ok(Command)),
    assertion(Command.op == call_tool),
    assertion(Command.name == lookup),
    assertion(Command.arguments.query == "x"),
    assertion(ground(Command)),
    term_string(Command, Text),
    assertion(\+ sub_string(Text, _, _, _, "jsonrpc")),
    assertion(\+ sub_string(Text, _, _, _, "2025-11-25")),
    assertion(\+ sub_string(Text, _, _, _, "tools/call")).

test(command_capability_mapping) :-
    mcp_command_capability(list_tools, tools),
    mcp_command_capability(read_resource("file:///x"), resources),
    mcp_command_capability(get_prompt(test, _{}), prompts).

test(server_capability_normalization) :-
    Input = _{tools:_{listChanged:true},
              resources:_{subscribe:true},
              prompts:_{listChanged:false}},
    mcp_capabilities_normalize(server, Input, ok(Caps)),
    assertion(Caps.role == server),
    assertion(Caps.tools.listChanged == true),
    assertion(Caps.resources.subscribe == true),
    assertion(Caps.prompts.listChanged == false),
    assertion(Caps.sampling == none),
    assertion(ground(Caps)).

test(tool_normalization) :-
    Input = _{name:"lookup",
              title:"Lookup",
              description:"Look something up",
              inputSchema:_{type:"object",
                            properties:_{query:_{type:"string"}}},
              outputSchema:_{type:"object"}},
    mcp_tool_normalize(Input, ok(Tool)),
    assertion(Tool.name == lookup),
    assertion(Tool.title == "Lookup"),
    assertion(Tool.input_schema.type == "object"),
    assertion(ground(Tool)).

test(resource_normalization) :-
    Input = _{uri:"file:///a",
              name:"a",
              description:"resource",
              mimeType:"text/plain",
              size:12},
    mcp_resource_normalize(Input, ok(Resource)),
    assertion(Resource.uri == "file:///a"),
    assertion(Resource.mime_type == "text/plain"),
    assertion(Resource.size =:= 12).

test(prompt_normalization) :-
    Input = _{name:"review",
              description:"Review input",
              arguments:[_{name:"text", required:true}]},
    mcp_prompt_normalize(Input, ok(Prompt)),
    assertion(Prompt.name == review),
    Prompt.arguments = [Argument],
    assertion(Argument.name == "text").

test(text_and_image_content_normalization) :-
    mcp_content_normalize(_{type:"text", text:"hello"}, ok(Text)),
    assertion(Text.type == text),
    mcp_content_normalize(_{type:"image",
                            data:"AAAA",
                            mimeType:"image/png"},
                          ok(Image)),
    assertion(Image.type == image),
    assertion(Image.mime_type == "image/png").

test(notification_normalization_is_version_neutral) :-
    mcp_notification_normalize(resource_updated("file:///a"),
                               ok(Notification)),
    assertion(Notification.type == resource_updated),
    assertion(Notification.uri == "file:///a"),
    assertion(ground(Notification)),
    term_string(Notification, Text),
    assertion(\+ sub_string(Text, _, _, _, "notifications/")),
    assertion(\+ sub_string(Text, _, _, _, "2025-11-25")).

test(invalid_command_fails_structurally) :-
    mcp_command_normalize(jsonrpc("tools/list"), error(Error)),
    assertion(Error.kind == validation_error),
    assertion(Error.phase == command).

:- end_tests(rlm_mcp_model).
