:- module(rlm_mcp_model,
          [ mcp_command_normalize/2,
            mcp_command_capability/2,
            mcp_capabilities_normalize/3,
            mcp_tool_normalize/2,
            mcp_resource_normalize/2,
            mcp_prompt_normalize/2,
            mcp_content_normalize/2,
            mcp_notification_normalize/2,
            mcp_json_canonical/2
          ]).

/** <module> Version-neutral MCP data model

Canonical MCP terms contain no JSON-RPC ids, wire method names, protocol dates,
HTTP headers, or transport session state. Those details belong to adapters.
*/

mcp_command_normalize(Input, Outcome) :-
    model_outcome(command, normalize_command(Input), Outcome).

normalize_command(list_tools,
                  mcp_command{op:list_tools, cursor:null}) :- !.
normalize_command(list_tools(Cursor0),
                  mcp_command{op:list_tools, cursor:Cursor}) :-
    !,
    normalize_cursor(Cursor0, Cursor).
normalize_command(call_tool(Name0, Arguments0),
                  mcp_command{op:call_tool,
                              name:Name,
                              arguments:Arguments}) :-
    !,
    require_name(Name0, Name),
    require_object(Arguments0, Arguments).
normalize_command(list_resources,
                  mcp_command{op:list_resources, cursor:null}) :- !.
normalize_command(list_resources(Cursor0),
                  mcp_command{op:list_resources, cursor:Cursor}) :-
    !,
    normalize_cursor(Cursor0, Cursor).
normalize_command(read_resource(Uri0),
                  mcp_command{op:read_resource, uri:Uri}) :-
    !,
    require_text(Uri0, Uri).
normalize_command(list_prompts,
                  mcp_command{op:list_prompts, cursor:null}) :- !.
normalize_command(list_prompts(Cursor0),
                  mcp_command{op:list_prompts, cursor:Cursor}) :-
    !,
    normalize_cursor(Cursor0, Cursor).
normalize_command(get_prompt(Name0, Arguments0),
                  mcp_command{op:get_prompt,
                              name:Name,
                              arguments:Arguments}) :-
    !,
    require_name(Name0, Name),
    require_object(Arguments0, Arguments).
normalize_command(Command, Command) :-
    is_dict(Command, mcp_command),
    ground(Command),
    !.
normalize_command(Input, _) :-
    throw(mcp_model_fault(unsupported_command(Input))).

mcp_command_capability(Command0, Capability) :-
    normalize_command(Command0, Command),
    get_dict(op, Command, Operation),
    command_capability(Operation, Capability).

command_capability(list_tools, tools).
command_capability(call_tool, tools).
command_capability(list_resources, resources).
command_capability(read_resource, resources).
command_capability(list_prompts, prompts).
command_capability(get_prompt, prompts).

mcp_capabilities_normalize(Role, Input, Outcome) :-
    model_outcome(capabilities,
                  normalize_capabilities(Role, Input),
                  Outcome).

normalize_capabilities(Role, Input, Capabilities) :-
    memberchk(Role, [client, server]),
    is_dict(Input),
    !,
    capability_value(Input, tools, Tools),
    capability_value(Input, resources, Resources),
    capability_value(Input, prompts, Prompts),
    capability_value(Input, logging, Logging),
    capability_value(Input, completions, Completions),
    capability_value(Input, roots, Roots),
    capability_value(Input, sampling, Sampling),
    capability_value(Input, elicitation, Elicitation),
    capability_value(Input, experimental, Experimental),
    capability_value(Input, extensions, Extensions),
    Capabilities = mcp_capabilities{
                       role:Role,
                       tools:Tools,
                       resources:Resources,
                       prompts:Prompts,
                       logging:Logging,
                       completions:Completions,
                       roots:Roots,
                       sampling:Sampling,
                       elicitation:Elicitation,
                       experimental:Experimental,
                       extensions:Extensions
                   }.
normalize_capabilities(Role, Input, _) :-
    throw(mcp_model_fault(invalid_capabilities(Role, Input))).

capability_value(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Raw)
    ->  mcp_json_canonical(Raw, Value)
    ;   Value = none
    ).

mcp_tool_normalize(Input, Outcome) :-
    model_outcome(tool, normalize_tool(Input), Outcome).

normalize_tool(Input, Tool) :-
    is_dict(Input),
    !,
    require_dict_key(Input, name, Name0),
    require_name(Name0, Name),
    optional_text(Input, title, Title),
    optional_text(Input, description, Description),
    require_dict_key(Input, inputSchema, InputSchema0),
    require_object(InputSchema0, InputSchema),
    optional_object(Input, outputSchema, OutputSchema),
    optional_json(Input, annotations, Annotations),
    optional_json(Input, icons, Icons),
    Tool = mcp_tool{name:Name,
                    title:Title,
                    description:Description,
                    input_schema:InputSchema,
                    output_schema:OutputSchema,
                    annotations:Annotations,
                    icons:Icons}.
normalize_tool(Input, _) :-
    throw(mcp_model_fault(invalid_tool(Input))).

mcp_resource_normalize(Input, Outcome) :-
    model_outcome(resource, normalize_resource(Input), Outcome).

normalize_resource(Input, Resource) :-
    is_dict(Input),
    !,
    require_dict_key(Input, uri, Uri0),
    require_text(Uri0, Uri),
    require_dict_key(Input, name, Name0),
    require_text(Name0, Name),
    optional_text(Input, title, Title),
    optional_text(Input, description, Description),
    optional_text(Input, mimeType, MimeType),
    optional_number(Input, size, Size),
    optional_json(Input, annotations, Annotations),
    optional_json(Input, icons, Icons),
    Resource = mcp_resource{uri:Uri,
                            name:Name,
                            title:Title,
                            description:Description,
                            mime_type:MimeType,
                            size:Size,
                            annotations:Annotations,
                            icons:Icons}.
normalize_resource(Input, _) :-
    throw(mcp_model_fault(invalid_resource(Input))).

mcp_prompt_normalize(Input, Outcome) :-
    model_outcome(prompt, normalize_prompt(Input), Outcome).

normalize_prompt(Input, Prompt) :-
    is_dict(Input),
    !,
    require_dict_key(Input, name, Name0),
    require_name(Name0, Name),
    optional_text(Input, title, Title),
    optional_text(Input, description, Description),
    optional_json(Input, arguments, Arguments),
    optional_json(Input, icons, Icons),
    Prompt = mcp_prompt{name:Name,
                        title:Title,
                        description:Description,
                        arguments:Arguments,
                        icons:Icons}.
normalize_prompt(Input, _) :-
    throw(mcp_model_fault(invalid_prompt(Input))).

mcp_content_normalize(Input, Outcome) :-
    model_outcome(content, normalize_content(Input), Outcome).

normalize_content(Input, Content) :-
    is_dict(Input),
    !,
    require_dict_key(Input, type, Type0),
    require_atom(Type0, Type),
    normalize_content_type(Type, Input, Content).
normalize_content(Input, _) :-
    throw(mcp_model_fault(invalid_content(Input))).

normalize_content_type(text, Input,
                       mcp_content{type:text, text:Text}) :-
    !,
    require_dict_key(Input, text, Text0),
    require_text(Text0, Text).
normalize_content_type(image, Input,
                       mcp_content{type:image,
                                   data:Data,
                                   mime_type:MimeType}) :-
    !,
    require_binary_content(Input, Data, MimeType).
normalize_content_type(audio, Input,
                       mcp_content{type:audio,
                                   data:Data,
                                   mime_type:MimeType}) :-
    !,
    require_binary_content(Input, Data, MimeType).
normalize_content_type(resource_link, Input, Content) :-
    !,
    require_dict_key(Input, uri, Uri0),
    require_text(Uri0, Uri),
    require_dict_key(Input, name, Name0),
    require_text(Name0, Name),
    optional_text(Input, mimeType, MimeType),
    Content = mcp_content{type:resource_link,
                          uri:Uri,
                          name:Name,
                          mime_type:MimeType}.
normalize_content_type(resource, Input,
                       mcp_content{type:resource,
                                   resource:Resource}) :-
    !,
    require_dict_key(Input, resource, Resource0),
    require_object(Resource0, Resource).
normalize_content_type(Type, _, _) :-
    throw(mcp_model_fault(unsupported_content_type(Type))).

require_binary_content(Input, Data, MimeType) :-
    require_dict_key(Input, data, Data0),
    require_text(Data0, Data),
    require_dict_key(Input, mimeType, Mime0),
    require_text(Mime0, MimeType).

mcp_notification_normalize(Input, Outcome) :-
    model_outcome(notification,
                  normalize_notification(Input),
                  Outcome).

normalize_notification(tools_list_changed,
                       mcp_notification{type:tools_list_changed}) :- !.
normalize_notification(resources_list_changed,
                       mcp_notification{type:resources_list_changed}) :- !.
normalize_notification(prompts_list_changed,
                       mcp_notification{type:prompts_list_changed}) :- !.
normalize_notification(resource_updated(Uri0),
                       mcp_notification{type:resource_updated, uri:Uri}) :-
    !,
    require_text(Uri0, Uri).
normalize_notification(Notification, Notification) :-
    is_dict(Notification, mcp_notification),
    ground(Notification),
    !.
normalize_notification(Input, _) :-
    throw(mcp_model_fault(unsupported_notification(Input))).

mcp_json_canonical(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_pair, Pairs0, Pairs),
    dict_pairs(Value, mcp_json, Pairs).
mcp_json_canonical(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(mcp_json_canonical, Values0, Values).
mcp_json_canonical(Value, Value) :-
    ground(Value),
    !.
mcp_json_canonical(Value, _) :-
    throw(mcp_model_fault(non_ground_json(Value))).

canonical_pair(Key-Value0, Key-Value) :-
    mcp_json_canonical(Value0, Value).

model_outcome(Phase, Goal, Outcome) :-
    catch(( call(Goal, Value), Result = ok(Value) ),
          Exception,
          model_exception(Phase, Exception, Result)),
    Outcome = Result.

normalize_cursor(null, null) :- !.
normalize_cursor(Cursor0, Cursor) :- require_text(Cursor0, Cursor).

require_name(Value0, Name) :-
    require_text(Value0, Text),
    (   Text == ""
    ->  throw(mcp_model_fault(empty_name))
    ;   atom_string(Name, Text)
    ).

require_atom(Value, Value) :- atom(Value), !.
require_atom(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
require_atom(Value, _) :- throw(mcp_model_fault(expected_atom(Value))).

require_text(Value, Value) :- string(Value), !.
require_text(Value, Text) :- atom(Value), !, atom_string(Value, Text).
require_text(Value, _) :- throw(mcp_model_fault(expected_text(Value))).

require_object(Value0, Value) :-
    is_dict(Value0),
    !,
    mcp_json_canonical(Value0, Value).
require_object(Value, _) :- throw(mcp_model_fault(expected_object(Value))).

require_dict_key(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(mcp_model_fault(missing_key(Key)))
    ).

optional_text(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Raw), Raw \== null
    ->  require_text(Raw, Value)
    ;   Value = null
    ).

optional_object(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Raw), Raw \== null
    ->  require_object(Raw, Value)
    ;   Value = none
    ).

optional_json(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Raw), Raw \== null
    ->  mcp_json_canonical(Raw, Value)
    ;   Value = none
    ).

optional_number(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Raw), Raw \== null
    ->  ( number(Raw)
        -> Value = Raw
        ;  throw(mcp_model_fault(expected_number(Key, Raw))) )
    ;   Value = null
    ).

model_exception(Phase, mcp_model_fault(Detail), error(Error)) :-
    !,
    Error = mcp_error{phase:Phase,
                      kind:validation_error,
                      detail:Detail,
                      message:"canonical MCP validation failed"}.
model_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = mcp_error{phase:Phase,
                      kind:exception,
                      exception:Safe,
                      message:"canonical MCP normalization raised an exception"}.
