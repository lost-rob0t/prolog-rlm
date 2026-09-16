:- module(rlm_zai_protocols,
          [ zai_protocol_complete/5,
            responses_request_payload/3,
            anthropic_request_payload/4,
            normalize_openai_responses_response/5,
            normalize_anthropic_messages_response/5
          ]).

/** <module> Responses and Anthropic Messages protocol adapters

Non-streaming adapters for the OpenAI Responses and Anthropic Messages wire
protocols exposed by Z.AI and the official Claude API. Chat Completions
continues through the established `rlm_openai_compatible` transport.
Provider-native reasoning blocks are retained in `reasoning_details` so tool
continuations can replay them unchanged.
*/

:- use_module(library(http/http_client)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_ssl_plugin)).
:- use_module(library(http/json)).
:- use_module(library(lists)).
:- use_module(rlm_openai_compatible,
              [ classify_provider_exception/2,
                redact_secret/3
              ]).

zai_protocol_complete(Protocol, Provider, Config, Request, Outcome) :-
    protocol_config(Protocol, Provider, Config, ConfigOutcome),
    complete_from_config(ConfigOutcome, Protocol, Provider, Request, Outcome).

complete_from_config(error(Error), _, _, _, error(Error)) :- !.
complete_from_config(ok(Endpoint, Credential, Model, Timeout, AddressFamily,
                        UserAgent, DefaultMaxTokens),
                     Protocol, Provider, Request, Outcome) :-
    protocol_payload(Protocol, Request, Model, DefaultMaxTokens, PayloadOutcome),
    complete_payload(PayloadOutcome, Protocol, Provider, Endpoint, Credential,
                     Model, Timeout, AddressFamily, UserAgent, Outcome).

complete_payload(error(Error), _, _, _, _, _, _, _, _, error(Error)) :- !.
complete_payload(ok(Payload), Protocol, Provider, Endpoint, Credential, Model,
                 Timeout, AddressFamily, UserAgent, Outcome) :-
    resolve_credential(Provider, Credential, CredentialOutcome),
    execute_credentialed(CredentialOutcome, Protocol, Provider, Endpoint, Model,
                         Timeout, AddressFamily, UserAgent, Payload, Outcome).

execute_credentialed(error(Error), _, _, _, _, _, _, _, _, error(Error)) :- !.
execute_credentialed(ok(Key), Protocol, Provider, Endpoint, Model, Timeout,
                     AddressFamily, UserAgent, Payload, Outcome) :-
    protocol_http_options(Protocol, Provider, Key, Timeout, AddressFamily,
                          UserAgent, Status, HttpOptions),
    catch(http_post(Endpoint, json(Payload), Reply, HttpOptions),
          Exception,
          transport_exception_handler(Exception)),
    (   var(Exception)
    ->  normalize_protocol_response(Protocol, Provider, Model, Status, Reply,
                                    Outcome)
    ;   classify_provider_exception(Exception, Kind),
        safe_exception_text(Exception, Key, SafeException),
        Outcome = error(provider_error{provider:Provider,
                                       kind:Kind,
                                       exception:SafeException,
                                       response_received:false})
    ).

protocol_payload(responses, Request, Model, _, Outcome) :-
    responses_request_payload(Request, Model, Outcome).
protocol_payload(anthropic_messages, Request, Model, DefaultMaxTokens, Outcome) :-
    anthropic_request_payload(Request, Model, DefaultMaxTokens, Outcome).

normalize_protocol_response(responses, Provider, Model, Status, Raw, Outcome) :-
    normalize_openai_responses_response(Provider, Model, Status, Raw, Outcome).
normalize_protocol_response(anthropic_messages, Provider, Model, Status, Raw,
                            Outcome) :-
    normalize_anthropic_messages_response(Provider, Model, Status, Raw, Outcome).

/* OpenAI Responses requests --------------------------------------------- */

responses_request_payload(Request, Model, Outcome) :-
    catch(( canonical_protocol_value(Request, CanonicalRequest),
            require_ground_request(CanonicalRequest, Model),
            responses_request_payload_(CanonicalRequest, Model, Payload),
            Result = ok(Payload)
          ),
          zai_protocol_fault(Field, Message),
          protocol_validation_error(Field, Message, Result)),
    Outcome = Result.

responses_request_payload_(Request, Model, Payload) :-
    request_messages(Request, Messages),
    validate_tool_history(Messages),
    maplist(responses_message_items, Messages, ItemLists),
    append(ItemLists, Input),
    request_options(Request, Options),
    responses_options(Options, OptionPayload),
    put_dict(responses_request{model:Model, input:Input, stream:false},
             OptionPayload, Payload).

responses_message_items(Message, Items) :-
    message_role_content(Message, Role, Content),
    responses_message_items(Role, Content, Message, Items).

responses_message_items(tool, Content, Message, [Item]) :-
    !,
    required_message_key(Message, tool_call_id, CallId),
    text_content(Content, Output),
    Item = responses_output{type:"function_call_output",
                            call_id:CallId,
                            output:Output}.
responses_message_items(assistant, Content, Message, Items) :-
    !,
    (   native_sequence(Message, responses, Items)
    ->  true
    ;   native_details(Message, reasoning, NativeItems),
        validate_responses_output(NativeItems),
        optional_text_item(assistant, Content, TextItems),
        assistant_calls(Message, Calls),
        maplist(responses_call_item, Calls, CallItems),
        append([NativeItems, TextItems, CallItems], Items)
    ).
responses_message_items(Role, Content, _, [Item]) :-
    memberchk(Role, [system,user]),
    !,
    text_content(Content, Text),
    Item = responses_message{role:Role, content:Text}.
responses_message_items(Role, _, _, _) :-
    throw(zai_protocol_fault(messages, unsupported_message_role(Role))).

optional_text_item(_, Content, []) :-
    text_content(Content, ""),
    !.
optional_text_item(Role, Content, [responses_message{role:Role, content:Text}]) :-
    text_content(Content, Text).

responses_call_item(Call, Item) :-
    function_call_fields(Call, Id, Name, Arguments),
    Item = responses_call{type:"function_call", call_id:Id,
                          name:Name, arguments:Arguments}.

responses_options(Options, Payload) :-
    validate_option_keys(Options,
                         [max_tokens,max_completion_tokens,temperature,top_p,
                          tools,tool_choice,response_format,reasoning],
                         responses),
    empty_dict(responses_options, Empty),
    max_output_tokens_option(Options, Empty, P1),
    copy_option(temperature, Options, P1, P2),
    copy_option(top_p, Options, P2, P3),
    copy_option(reasoning, Options, P3, P4),
    responses_tools_option(Options, P4, P5),
    responses_tool_choice_option(Options, P5, P6),
    responses_format_option(Options, P6, Payload).

max_output_tokens_option(Options, Payload0, Payload) :-
    (   get_dict(max_completion_tokens, Options, Value)
    ->  put_dict(max_output_tokens, Payload0, Value, Payload)
    ;   get_dict(max_tokens, Options, Value)
    ->  put_dict(max_output_tokens, Payload0, Value, Payload)
    ;   Payload = Payload0
    ).

responses_tools_option(Options, Payload0, Payload) :-
    (   get_dict(tools, Options, Tools0)
    ->  require_list(Tools0, tools),
        maplist(responses_tool, Tools0, Tools),
        put_dict(tools, Payload0, Tools, Payload)
    ;   Payload = Payload0
    ).

responses_tool(Tool, ResponseTool) :-
    openai_tool_fields(Tool, Name, Description, Parameters),
    Base = responses_tool{type:function, name:Name, parameters:Parameters},
    optional_dict_value(description, Description, Base, ResponseTool).

responses_tool_choice_option(Options, Payload0, Payload) :-
    (   get_dict(tool_choice, Options, Choice0)
    ->  responses_tool_choice(Choice0, Choice),
        put_dict(tool_choice, Payload0, Choice, Payload)
    ;   Payload = Payload0
    ).

responses_tool_choice(Choice, Choice) :-
    atom(Choice), memberchk(Choice, [auto,none,required]), !.
responses_tool_choice(Choice0, Choice) :-
    string(Choice0), atom_string(Choice, Choice0),
    memberchk(Choice, [auto,none,required]), !.
responses_tool_choice(Choice0, responses_tool_choice{type:"function",name:Name}) :-
    is_dict(Choice0), get_dict(type, Choice0, Type), text_atom(Type, function),
    get_dict(function, Choice0, Function), is_dict(Function),
    get_dict(name, Function, Name), !.
responses_tool_choice(_, _) :-
    throw(zai_protocol_fault(tool_choice, unsupported_tool_choice)).

responses_format_option(Options, Payload0, Payload) :-
    (   get_dict(response_format, Options, Format0)
    ->  responses_text_format(Format0, Format),
        put_dict(text, Payload0, responses_text{format:Format}, Payload)
    ;   Payload = Payload0
    ).

responses_text_format(Format0, Format) :-
    is_dict(Format0), get_dict(type, Format0, Type),
    text_atom(Type, json_schema),
    get_dict(json_schema, Format0, Schema), is_dict(Schema),
    dict_pairs(Schema, _, Pairs),
    dict_pairs(Format, responses_format, [type-json_schema|Pairs]), !.
responses_text_format(Format0, responses_format{type:json_object}) :-
    is_dict(Format0), get_dict(type, Format0, Type),
    text_atom(Type, json_object), !.
responses_text_format(_, _) :-
    throw(zai_protocol_fault(response_format, unsupported_response_format)).

/* Anthropic Messages requests ------------------------------------------ */

anthropic_request_payload(Request, Model, DefaultMaxTokens, Outcome) :-
    catch(( canonical_protocol_value(Request, CanonicalRequest),
            require_ground_request(CanonicalRequest, Model),
            anthropic_request_payload_(CanonicalRequest, Model,
                                       DefaultMaxTokens, Payload),
            Result = ok(Payload)
          ),
          zai_protocol_fault(Field, Message),
          protocol_validation_error(Field, Message, Result)),
    Outcome = Result.

anthropic_request_payload_(Request, Model, DefaultMaxTokens, Payload) :-
    request_messages(Request, Messages),
    validate_tool_history(Messages),
    anthropic_split_system(Messages, SystemMessages, Conversation),
    maplist(anthropic_system_block, SystemMessages, System),
    maplist(anthropic_message, Conversation, AnthropicMessages),
    request_options(Request, Options),
    anthropic_max_tokens(Options, DefaultMaxTokens, MaxTokens),
    validate_option_keys(Options,
                         [max_tokens,max_completion_tokens,temperature,top_p,
                          stop,tools,tool_choice,reasoning],
                         anthropic_messages),
    empty_dict(anthropic_options, Empty),
    copy_option(temperature, Options, Empty, P1),
    copy_option(top_p, Options, P1, P2),
    anthropic_stop_option(Options, P2, P3),
    anthropic_reasoning_option(Options, P3, P4),
    anthropic_tools_option(Options, P4, P5),
    anthropic_tool_choice_option(Options, P5, OptionPayload),
    Base = anthropic_request{model:Model, max_tokens:MaxTokens,
                             messages:AnthropicMessages, stream:false},
    put_dict(Base, OptionPayload, Payload0),
    (   System == []
    ->  Payload = Payload0
    ;   put_dict(system, Payload0, System, Payload)
    ).

anthropic_split_system(Messages, System, Conversation) :-
    anthropic_leading_system(Messages, System, Conversation),
    (   member(Message, Conversation), get_dict(role, Message, system)
    ->  throw(zai_protocol_fault(messages, interspersed_system_message))
    ;   true
    ).

anthropic_leading_system([Message|Messages], [Message|System], Conversation) :-
    get_dict(role, Message, system), !,
    anthropic_leading_system(Messages, System, Conversation).
anthropic_leading_system(Messages, [], Messages).

anthropic_system_block(Message, anthropic_block{type:"text", text:Text}) :-
    get_dict(content, Message, Content),
    text_content(Content, Text).

anthropic_message(Message, AnthropicMessage) :-
    message_role_content(Message, Role, Content),
    anthropic_message(Role, Content, Message, AnthropicMessage).

anthropic_message(user, Content, _, anthropic_message{role:user, content:Text}) :-
    !, text_content(Content, Text).
anthropic_message(assistant, Content, Message,
                  anthropic_message{role:assistant, content:Blocks}) :-
    !,
    (   native_sequence(Message, anthropic_messages, Blocks)
    ->  true
    ;   native_details(Message, anthropic, NativeBlocks),
        anthropic_text_blocks(Content, TextBlocks),
        assistant_calls(Message, Calls),
        maplist(anthropic_tool_use_block, Calls, ToolBlocks),
        append([NativeBlocks, TextBlocks, ToolBlocks], Blocks)
    ),
    validate_anthropic_output(Blocks),
    (   Blocks == []
    ->  throw(zai_protocol_fault(messages, empty_assistant_message))
    ;   true
    ).
anthropic_message(tool, Content, Message,
                  anthropic_message{role:user, content:[Block]}) :-
    !,
    required_message_key(Message, tool_call_id, CallId),
    text_content(Content, Text),
    Block = anthropic_block{type:"tool_result", tool_use_id:CallId,
                            content:Text}.
anthropic_message(Role, _, _, _) :-
    throw(zai_protocol_fault(messages, unsupported_message_role(Role))).

anthropic_text_blocks(Content, []) :- text_content(Content, ""), !.
anthropic_text_blocks(Content, [anthropic_block{type:"text",text:Text}]) :-
    text_content(Content, Text).

anthropic_tool_use_block(Call, Block) :-
    function_call_fields(Call, Id, Name, Arguments),
    parse_json_object(Arguments, Input),
    Block = anthropic_block{type:"tool_use", id:Id, name:Name, input:Input}.

anthropic_max_tokens(Options, _, Value) :-
    get_dict(max_completion_tokens, Options, Value), !.
anthropic_max_tokens(Options, _, Value) :-
    get_dict(max_tokens, Options, Value), !.
anthropic_max_tokens(_, Default, Default) :-
    integer(Default), Default > 0, !.
anthropic_max_tokens(_, _, _) :-
    throw(zai_protocol_fault(max_tokens, missing_positive_default)).

anthropic_stop_option(Options, Payload0, Payload) :-
    (   get_dict(stop, Options, Stop0)
    ->  stop_sequences(Stop0, Stop),
        put_dict(stop_sequences, Payload0, Stop, Payload)
    ;   Payload = Payload0
    ).

stop_sequences(Stop, [Stop]) :- string(Stop), !.
stop_sequences(Stop, [Text]) :- atom(Stop), !, atom_string(Stop, Text).
stop_sequences(Stops, Stops) :- is_list(Stops), maplist(string, Stops), !.
stop_sequences(_, _) :-
    throw(zai_protocol_fault(stop, "stop must be text or a list of strings")).

anthropic_reasoning_option(Options, Payload0, Payload) :-
    (   get_dict(reasoning, Options, Reasoning), is_dict(Reasoning),
        get_dict(effort, Reasoning, Effort)
    ->  put_dict(output_config, Payload0,
                 anthropic_output_config{effort:Effort}, Payload)
    ;   get_dict(reasoning, Options, _)
    ->  throw(zai_protocol_fault(reasoning,
                                 "reasoning must contain an effort value"))
    ;   Payload = Payload0
    ).

anthropic_tools_option(Options, Payload0, Payload) :-
    (   get_dict(tools, Options, Tools0)
    ->  require_list(Tools0, tools),
        maplist(anthropic_tool, Tools0, Tools),
        put_dict(tools, Payload0, Tools, Payload)
    ;   Payload = Payload0
    ).

anthropic_tool(Tool, AnthropicTool) :-
    openai_tool_fields(Tool, Name, Description, Parameters),
    Base = anthropic_tool{name:Name, input_schema:Parameters},
    optional_dict_value(description, Description, Base, AnthropicTool).

anthropic_tool_choice_option(Options, Payload0, Payload) :-
    (   get_dict(tool_choice, Options, Choice0)
    ->  anthropic_tool_choice(Choice0, Choice),
        put_dict(tool_choice, Payload0, Choice, Payload)
    ;   Payload = Payload0
    ).

anthropic_tool_choice(Choice0, anthropic_tool_choice{type:Type}) :-
    text_atom(Choice0, Choice),
    memberchk(Choice-Type, [auto-"auto", required-"any", none-"none"]), !.
anthropic_tool_choice(Choice0,
                      anthropic_tool_choice{type:"tool", name:Name}) :-
    is_dict(Choice0), get_dict(type, Choice0, Type0),
    text_atom(Type0, function), get_dict(function, Choice0, Function),
    is_dict(Function), get_dict(name, Function, Name), !.
anthropic_tool_choice(_, _) :-
    throw(zai_protocol_fault(tool_choice, unsupported_tool_choice)).

/* Response normalization ------------------------------------------------ */

normalize_openai_responses_response(Provider, RequestedModel, HttpInfo, Raw,
                                    Outcome) :-
    catch(normalize_openai_responses_response_(Provider, RequestedModel,
                                               HttpInfo, Raw, Outcome),
          zai_protocol_fault(Field, Detail),
          protocol_response_error(Provider, HttpInfo, Field, Detail, Outcome)).

normalize_openai_responses_response_(Provider, RequestedModel, HttpInfo, Raw,
                                     Outcome) :-
    http_status(HttpInfo, Status),
    (   success_status(Status)
    ->  normalize_responses_success(Provider, RequestedModel, Status, Raw,
                                    Outcome)
    ;   normalize_protocol_error(Provider, Status, Raw, Outcome)
    ).

normalize_responses_success(Provider, RequestedModel, Status, Raw, Outcome) :-
    (   \+ is_dict(Raw)
    ->  invalid_response(Provider, Status, "Responses response is not a JSON object", Outcome)
    ;   get_dict(error, Raw, Error), Error \== null
    ->  protocol_error_from_wire(Provider, Status, Raw, Error, Outcome)
    ;   get_dict(output, Raw, Output), is_list(Output)
    ->  validate_responses_output(Output),
        responses_output(Output, Text, ToolCalls, ReasoningDetails),
        response_finish_reason(Raw, FinishReason),
        responses_usage(Raw, Usage),
        normalized_response(Provider, RequestedModel, Status, Raw,
                            Text, ToolCalls, "", ReasoningDetails,
                            FinishReason, Usage, Outcome)
    ;   invalid_response(Provider, Status, "Responses response has no output list", Outcome)
    ).

responses_output(Output, Text, ToolCalls, ReasoningDetails) :-
    findall(Piece,
            ( member(Item, Output), responses_text_piece(Item, Piece) ),
            Pieces),
    atomics_to_string(Pieces, "", Text),
    findall(Call,
            ( member(Item, Output), responses_output_call(Item, Call) ),
            ToolCalls),
    canonical_native_value(Output, NativeOutput),
    ReasoningDetails =
        [provider_native_sequence{type:provider_native_sequence,
                                  protocol:responses,
                                  items:NativeOutput}].

validate_responses_output([]).
validate_responses_output([Item|Items]) :-
    (   native_item_type(Item, function_call)
    ->  (   get_dict(call_id, Item, CallId), text_value(CallId),
            get_dict(name, Item, Name), text_value(Name),
            get_dict(arguments, Item, Arguments),
            text_value(Arguments)
        ->  true
        ;   throw(zai_protocol_fault(response,
                                     malformed_responses_function_call))
        )
    ;   native_item_type(Item, message)
    ->  (get_dict(content, Item, Content), is_list(Content)
        -> maplist(validate_responses_content_block, Content)
        ;  throw(zai_protocol_fault(response, malformed_responses_message)))
    ;   native_item_type(Item, reasoning)
    ->  (get_dict(id, Item, Id), text_value(Id)
        -> true
        ;  throw(zai_protocol_fault(response, malformed_responses_reasoning)))
    ;   throw(zai_protocol_fault(response, unsupported_responses_output_item))
    ),
    validate_responses_output(Items).

validate_responses_content_block(Block) :-
    (   native_item_type(Block, output_text), get_dict(text, Block, Text),
        (string(Text) ; atom(Text))
    ->  true
    ;   throw(zai_protocol_fault(response,
                                 malformed_responses_content_block))
    ).

responses_text_piece(Item, Text) :-
    native_item_type(Item, message),
    get_dict(content, Item, Content), is_list(Content),
    member(Block, Content), native_item_type(Block, output_text),
    get_dict(text, Block, Text).

responses_output_call(Item, Call) :-
    native_item_type(Item, function_call),
    get_dict(call_id, Item, Id), get_dict(name, Item, Name),
    get_dict(arguments, Item, Arguments),
    Call = tool_call{id:Id, type:"function",
                     function:tool_function{name:Name, arguments:Arguments}}.

response_finish_reason(Raw, Reason) :-
    (   get_dict(status, Raw, Status), Status \== null
    ->  Reason = Status
    ;   Reason = null
    ).

responses_usage(Raw, Usage) :-
    (   get_dict(usage, Raw, Wire), is_dict(Wire)
    ->  dict_default(input_tokens, Wire, null, Input),
        dict_default(output_tokens, Wire, null, Output),
        dict_default(total_tokens, Wire, null, Total),
        Usage = usage{present:true, prompt_tokens:Input,
                      completion_tokens:Output, total_tokens:Total, cost:null}
    ;   empty_usage(Usage)
    ).

normalize_anthropic_messages_response(Provider, RequestedModel, HttpInfo, Raw,
                                      Outcome) :-
    catch(normalize_anthropic_messages_response_(Provider, RequestedModel,
                                                 HttpInfo, Raw, Outcome),
          zai_protocol_fault(Field, Detail),
          protocol_response_error(Provider, HttpInfo, Field, Detail, Outcome)).

normalize_anthropic_messages_response_(Provider, RequestedModel, HttpInfo, Raw,
                                       Outcome) :-
    http_status(HttpInfo, Status),
    (   success_status(Status)
    ->  normalize_anthropic_success(Provider, RequestedModel, Status, Raw,
                                    Outcome)
    ;   normalize_protocol_error(Provider, Status, Raw, Outcome)
    ).

normalize_anthropic_success(Provider, RequestedModel, Status, Raw, Outcome) :-
    (   \+ is_dict(Raw)
    ->  invalid_response(Provider, Status, "Anthropic response is not a JSON object", Outcome)
    ;   get_dict(error, Raw, Error), Error \== null
    ->  protocol_error_from_wire(Provider, Status, Raw, Error, Outcome)
    ;   get_dict(content, Raw, Content), is_list(Content)
    ->  validate_anthropic_output(Content),
        anthropic_output(Content, Text, ToolCalls, Reasoning, ReasoningDetails),
        dict_default(stop_reason, Raw, null, FinishReason),
        anthropic_usage(Raw, Usage),
        normalized_response(Provider, RequestedModel, Status, Raw,
                            Text, ToolCalls, Reasoning, ReasoningDetails,
                            FinishReason, Usage, Outcome)
    ;   invalid_response(Provider, Status, "Anthropic response has no content list", Outcome)
    ).

anthropic_output(Content, Text, ToolCalls, Reasoning, ReasoningDetails) :-
    findall(Piece,
            ( member(Block, Content), native_item_type(Block, text),
              get_dict(text, Block, Piece) ),
            Pieces),
    atomics_to_string(Pieces, "", Text),
    findall(Call,
            ( member(Block, Content), anthropic_output_call(Block, Call) ),
            ToolCalls),
    canonical_native_value(Content, NativeContent),
    ReasoningDetails =
        [provider_native_sequence{type:provider_native_sequence,
                                  protocol:anthropic_messages,
                                  items:NativeContent}],
    findall(Piece,
            ( member(Block, Content), anthropic_reasoning_block(Block),
              get_dict(thinking, Block, Piece) ),
            ReasoningPieces),
    atomics_to_string(ReasoningPieces, "", Reasoning).

validate_anthropic_output([]).
validate_anthropic_output([Block|Blocks]) :-
    (   native_item_type(Block, tool_use)
    ->  (   get_dict(id, Block, Id), text_value(Id),
            get_dict(name, Block, Name), text_value(Name),
            get_dict(input, Block, Input), is_dict(Input)
        ->  true
        ;   throw(zai_protocol_fault(response,
                                     malformed_anthropic_tool_use))
        )
    ;   native_item_type(Block, text)
    ->  (get_dict(text, Block, Text), (string(Text) ; atom(Text))
        -> true
        ;  throw(zai_protocol_fault(response, malformed_anthropic_text)))
    ;   native_item_type(Block, thinking)
    ->  (get_dict(thinking, Block, Thinking),
         text_value(Thinking), get_dict(signature, Block, Signature),
         text_value(Signature)
        -> true
        ;  throw(zai_protocol_fault(response, malformed_anthropic_thinking)))
    ;   native_item_type(Block, redacted_thinking)
    ->  (get_dict(data, Block, Data), text_value(Data)
        -> true
        ;  throw(zai_protocol_fault(response,
                                    malformed_anthropic_redacted_thinking)))
    ;   throw(zai_protocol_fault(response,
                                 unsupported_anthropic_content_block))
    ),
    validate_anthropic_output(Blocks).

anthropic_output_call(Block, Call) :-
    native_item_type(Block, tool_use),
    get_dict(id, Block, Id), get_dict(name, Block, Name),
    get_dict(input, Block, Input), is_dict(Input),
    atom_json_dict(Atom, Input, []), atom_string(Atom, Arguments),
    Call = tool_call{id:Id, type:"function",
                     function:tool_function{name:Name, arguments:Arguments}}.

anthropic_reasoning_block(Block) :- native_item_type(Block, thinking), !.
anthropic_reasoning_block(Block) :- native_item_type(Block, redacted_thinking).

anthropic_usage(Raw, Usage) :-
    (   get_dict(usage, Raw, Wire), is_dict(Wire)
    ->  dict_default(input_tokens, Wire, null, Input),
        dict_default(output_tokens, Wire, null, Output),
        token_total(Input, Output, Total),
        Usage = usage{present:true, prompt_tokens:Input,
                      completion_tokens:Output, total_tokens:Total, cost:null}
    ;   empty_usage(Usage)
    ).

token_total(Input, Output, Total) :-
    integer(Input), integer(Output), !, Total is Input+Output.
token_total(_, _, null).

normalized_response(Provider, RequestedModel, Status, Raw,
                    Text, ToolCalls, Reasoning, ReasoningDetails,
                    FinishReason, Usage, Outcome) :-
    (   assistant_payload_present(Text, ToolCalls, Reasoning, ReasoningDetails)
    ->  dict_default(model, Raw, RequestedModel, SelectedModel),
        dict_default(id, Raw, null, ResponseId),
        Assistant = message{role:assistant, content:Text,
                            tool_calls:ToolCalls, reasoning:Reasoning,
                            reasoning_details:ReasoningDetails},
        Metadata = provider_metadata{provider:Provider, http_status:Status,
                                     response_received:true},
        Outcome = ok(model_response{provider:Provider,
                                    requested_model:RequestedModel,
                                    selected_model:SelectedModel,
                                    response_id:ResponseId,
                                    assistant:Assistant,
                                    text:Text,
                                    tool_calls:ToolCalls,
                                    reasoning:Reasoning,
                                    reasoning_details:ReasoningDetails,
                                    finish_reason:FinishReason,
                                    usage:Usage,
                                    metadata:Metadata})
    ;   invalid_response(Provider, Status,
                         "provider response contains no assistant output",
                         Outcome)
    ).

assistant_payload_present(Text, _, _, _) :- Text \== "", !.
assistant_payload_present(_, Calls, _, _) :- Calls \== [], !.
assistant_payload_present(_, _, Reasoning, _) :- Reasoning \== "", !.
assistant_payload_present(_, _, _, Details) :-
    member(Sequence, Details),
    get_dict(type, Sequence, provider_native_sequence),
    get_dict(protocol, Sequence, Protocol),
    get_dict(items, Sequence, Items),
    member(Item, Items),
    native_reasoning_item(Protocol, Item),
    !.

native_reasoning_item(responses, Item) :- native_item_type(Item, reasoning).
native_reasoning_item(anthropic_messages, Item) :-
    anthropic_reasoning_block(Item).

normalize_protocol_error(Provider, Status, Raw, Outcome) :-
    (   is_dict(Raw), get_dict(error, Raw, Error), Error \== null
    ->  protocol_error_from_wire(Provider, Status, Raw, Error, Outcome)
    ;   is_dict(Raw), get_dict(message, Raw, _)
    ->  protocol_error_from_wire(Provider, Status, Raw, Raw, Outcome)
    ;   Outcome = error(provider_error{provider:Provider, kind:http_error,
                                       http_status:Status,
                                       message:"provider returned a non-success HTTP response",
                                       response_received:true})
    ).

protocol_error_from_wire(Provider, Status, Raw, WireError, error(Error)) :-
    wire_error_fields(WireError, Code, Type, Message),
    (   is_dict(Raw), get_dict(request_id, Raw, RequestId0)
    ->  RequestId = RequestId0
    ;   RequestId = null
    ),
    Error = provider_error{provider:Provider, kind:provider_error,
                           http_status:Status, code:Code, error_type:Type,
                           request_id:RequestId, message:Message,
                           response_received:true}.

wire_error_fields(Wire, Code, Type, Message) :-
    (   is_dict(Wire)
    ->  dict_default(code, Wire, null, Code),
        dict_default(type, Wire, null, Type),
        dict_default(message, Wire, "provider returned an error", Message0),
        text_content(Message0, Message)
    ;   Code = null, Type = null, text_content(Wire, Message)
    ).

invalid_response(Provider, Status, Message,
                 error(provider_error{provider:Provider,
                                      kind:invalid_response,
                                      http_status:Status,
                                      message:Message,
                                      response_received:true})).

protocol_response_error(Provider, HttpInfo, Field, Detail,
                        error(provider_error{provider:Provider,
                                             kind:invalid_response,
                                             http_status:Status,
                                             field:Field,
                                             detail:Detail,
                                             message:"provider response violates the selected protocol",
                                             response_received:true})) :-
    http_status(HttpInfo, Status).

empty_usage(usage{present:false, prompt_tokens:null, completion_tokens:null,
                  total_tokens:null, cost:null}).

/* Configuration and shared conversion ---------------------------------- */

protocol_config(Protocol, Provider, Config, Outcome) :-
    (   is_list(Config)
    ->  config_value(endpoint, Config, none, Endpoint),
        config_value(credential, Config, none, Credential),
        config_value(model, Config, none, Model),
        config_value(timeout, Config, 30, Timeout),
        config_value(address_family, Config, auto, AddressFamily),
        config_value(user_agent, Config, 'prolog-rlm/0.1', UserAgent),
        config_value(default_max_tokens, Config, 4096, DefaultMaxTokens),
        validate_protocol_config(Protocol, Provider, Endpoint, Credential,
                                 Model, Timeout, AddressFamily, UserAgent,
                                 DefaultMaxTokens, Outcome)
    ;   config_error(Provider, config, "provider config must be a list", Outcome)
    ).

validate_protocol_config(Protocol, Provider, Endpoint, Credential, Model,
                         Timeout, AddressFamily, UserAgent, DefaultMaxTokens,
                         Outcome) :-
    (   \+ memberchk(Protocol, [responses,anthropic_messages])
    ->  config_error(Provider, protocol, "unsupported Z.AI protocol", Outcome)
    ;   Endpoint == none
    ->  config_error(Provider, endpoint, "provider endpoint is not configured", Outcome)
    ;   Model == none
    ->  config_error(Provider, model, "provider model is not configured", Outcome)
    ;   \+ valid_credential(Credential)
    ->  config_error(Provider, credential, "credentials must use env(Name) or none", Outcome)
    ;   (\+ number(Timeout) ; Timeout =< 0)
    ->  config_error(Provider, timeout, "timeout must be a positive number", Outcome)
    ;   \+ memberchk(AddressFamily, [auto,inet,inet6])
    ->  config_error(Provider, address_family, "invalid address family", Outcome)
    ;   \+ valid_header_text(UserAgent)
    ->  config_error(Provider, user_agent,
                     "user_agent must be a nonempty atom or string without control characters",
                     Outcome)
    ;   Protocol == anthropic_messages,
        (\+ integer(DefaultMaxTokens) ; DefaultMaxTokens =< 0)
    ->  config_error(Provider, default_max_tokens,
                     "default_max_tokens must be a positive integer", Outcome)
    ;   Outcome = ok(Endpoint, Credential, Model, Timeout, AddressFamily,
                     UserAgent,
                     DefaultMaxTokens)
    ).

config_error(Provider, Field, Message,
             error(provider_error{provider:Provider, kind:configuration_error,
                                  field:Field, message:Message,
                                  response_received:false})).

valid_credential(none).
valid_credential(env(Name)) :- atom(Name) ; string(Name).

valid_header_text(Value) :-
    atom(Value),
    !,
    Value \== '',
    atom_codes(Value, Codes),
    maplist(valid_header_code, Codes).
valid_header_text(Value) :-
    string(Value),
    Value \== "",
    string_codes(Value, Codes),
    maplist(valid_header_code, Codes).

valid_header_code(Code) :-
    Code >= 32,
    Code =\= 127.

resolve_credential(_, none, ok(none)) :- !.
resolve_credential(Provider, env(Name), Outcome) :-
    (   getenv(Name, Key), Key \== '', Key \== ""
    ->  Outcome = ok(Key)
    ;   format(string(Message),
               "credential environment variable ~w is not configured", [Name]),
        Outcome = error(provider_error{provider:Provider,
                                       kind:missing_credential,
                                       credential:env(Name),
                                       message:Message,
                                       response_received:false})
    ).

protocol_http_options(Protocol, Provider, Key, Timeout, AddressFamily,
                      UserAgent, Status, Options) :-
    credential_options(Provider, Key, CredentialOptions),
    address_options(AddressFamily, AddressOptions),
    protocol_headers(Protocol, ProtocolHeaders),
    append([CredentialOptions, AddressOptions, ProtocolHeaders,
            [ timeout(Timeout), status_code(Status), json_object(dict),
              request_header('Accept'='application/json'),
              user_agent(UserAgent)
            ]], Options).

credential_options(_, none, []) :- !.
credential_options(claude_api, Key, [request_header('x-api-key'=Key)]) :- !.
credential_options(_, Key, [authorization(bearer(Key))]).
address_options(auto, []) :- !.
address_options(Family, [domain(Family)]).
protocol_headers(responses, []).
protocol_headers(anthropic_messages,
                 [request_header('anthropic-version'='2023-06-01')]).

transport_exception_handler(error(rlm_cancelled(Token), Context)) :- !,
    throw(error(rlm_cancelled(Token), Context)).
transport_exception_handler(time_limit_exceeded) :- !, throw(time_limit_exceeded).
transport_exception_handler(time_limit_exceeded(Context)) :- !,
    throw(time_limit_exceeded(Context)).
transport_exception_handler(_).

safe_exception_text(Exception, Secret, SafeText) :-
    redact_secret(Exception, Secret, Safe),
    term_string(Safe, SafeText, [quoted(true), numbervars(true)]).

request_messages(Request, Messages) :-
    (   is_dict(Request, model_request), get_dict(messages, Request, Messages),
        is_list(Messages), Messages \== []
    ->  maplist(protocol_message_shape, Messages)
    ;   throw(zai_protocol_fault(messages,
                                 "model request requires non-empty messages"))
    ).

protocol_message_shape(Message) :-
    (   is_dict(Message), get_dict(role, Message, Role),
        memberchk(Role, [system,user,assistant,tool]),
        get_dict(content, Message, Content),
        text_value(Content)
    ->  (   Role == tool
        ->  required_message_key(Message, tool_call_id, CallId),
            (text_value(CallId)
            -> true
            ;  throw(zai_protocol_fault(messages, invalid_tool_call_id)))
        ;   true
        )
    ;   throw(zai_protocol_fault(messages, malformed_message))
    ).

request_options(Request, Options) :-
    (   get_dict(options, Request, Candidate)
    ->  (   is_dict(Candidate)
        ->  Options = Candidate
        ;   throw(zai_protocol_fault(options, expected_dict))
        )
    ;   empty_dict(generation_options, Options)
    ).

message_role_content(Message, Role, Content) :-
    (   is_dict(Message), get_dict(role, Message, Role),
        get_dict(content, Message, Content)
    ->  true
    ;   throw(zai_protocol_fault(messages, malformed_message))
    ).

required_message_key(Message, Key, Value) :-
    (   get_dict(Key, Message, Value)
    ->  true
    ;   throw(zai_protocol_fault(messages, missing_message_key(Key)))
    ).

assistant_calls(Message, Calls) :-
    (   get_dict(tool_calls, Message, Candidate)
    ->  require_list(Candidate, tool_calls), Calls = Candidate
    ;   Calls = []
    ).

function_call_fields(Call, Id, Name, Arguments) :-
    (   is_dict(Call), get_dict(id, Call, Id),
        get_dict(function, Call, Function), is_dict(Function),
        get_dict(name, Function, Name), get_dict(arguments, Function, Arguments),
        text_value(Id), text_value(Name), text_value(Arguments)
    ->  true
    ;   throw(zai_protocol_fault(tool_calls, malformed_function_call))
    ).

openai_tool_fields(Tool, Name, Description, Parameters) :-
    (   is_dict(Tool), get_dict(type, Tool, Type), text_atom(Type, function),
        get_dict(function, Tool, Function), is_dict(Function),
        get_dict(name, Function, Name), text_value(Name),
        get_dict(parameters, Function, Parameters), is_dict(Parameters)
    ->  dict_default(description, Function, none, Description)
    ;   throw(zai_protocol_fault(tools, malformed_function_tool))
    ).

native_details(Message, Protocol, Details) :-
    (   get_dict(reasoning_details, Message, Candidate)
    ->  require_list(Candidate, reasoning_details),
        include(native_detail_for(Protocol), Candidate, RawDetails),
        maplist(canonical_native_value, RawDetails, Details)
    ;   Details = []
    ).

native_sequence(Message, Protocol, Items) :-
    get_dict(reasoning_details, Message, Details),
    is_list(Details),
    findall(Sequence,
            ( member(Sequence, Details),
              is_dict(Sequence),
              get_dict(type, Sequence, Type),
              text_atom(Type, provider_native_sequence),
              get_dict(protocol, Sequence, FoundProtocol),
              text_atom(FoundProtocol, Protocol)
            ),
            Sequences),
    native_sequence_entry(Sequences, Protocol, Message, Items).

native_sequence_entry([], _, _, _) :- !, fail.
native_sequence_entry([Sequence], Protocol, Message, Items) :-
    !,
    get_dict(items, Sequence, Items0),
    (   is_list(Items0)
    ->  canonical_native_value(Items0, Items),
        validate_native_sequence(Protocol, Message, Items)
    ;   throw(zai_protocol_fault(reasoning_details,
                                 malformed_native_sequence))
    ).
native_sequence_entry(_, _, _, _) :-
    throw(zai_protocol_fault(reasoning_details,
                             duplicate_native_sequences)).

validate_native_sequence(responses, Message, Items) :-
    validate_responses_output(Items),
    findall(Call,
            (member(Item, Items), responses_output_call(Item, Call)),
            NativeCalls),
    native_calls_match_message(Message, NativeCalls).
validate_native_sequence(anthropic_messages, Message, Items) :-
    validate_anthropic_output(Items),
    findall(Call,
            (member(Item, Items), anthropic_output_call(Item, Call)),
            NativeCalls),
    native_calls_match_message(Message, NativeCalls).

native_calls_match_message(Message, NativeCalls) :-
    assistant_calls(Message, CanonicalCalls),
    maplist(call_signature, CanonicalCalls, CanonicalSignatures),
    maplist(call_signature, NativeCalls, NativeSignatures),
    (   CanonicalSignatures == NativeSignatures
    ->  true
    ;   throw(zai_protocol_fault(reasoning_details,
                                 native_tool_calls_mismatch))
    ).

call_signature(Call, call(Id, Name, Arguments)) :-
    function_call_fields(Call, Id, Name, Arguments).

native_detail_for(reasoning, Item) :- native_item_type(Item, reasoning).
native_detail_for(anthropic, Item) :- anthropic_reasoning_block(Item).

native_item_type(Item, Type) :-
    is_dict(Item), get_dict(type, Item, Value), text_atom(Value, Type).

parse_json_object(Text0, Dict) :-
    text_content(Text0, Text), atom_string(Atom, Text),
    catch(atom_json_dict(Atom, Parsed, []), _, fail), is_dict(Parsed), !,
    canonical_json_value(Parsed, Dict).
parse_json_object(_, _) :-
    throw(zai_protocol_fault(tool_calls,
                             "Anthropic tool arguments must encode a JSON object")).

text_content(Value, Text) :- string(Value), !, Text = Value.
text_content(Value, Text) :- atom(Value), !, atom_string(Value, Text).
text_content(_, _) :-
    throw(zai_protocol_fault(messages, "this protocol adapter requires text content")).

text_atom(Value, Atom) :- atom(Value), !, Atom = Value.
text_atom(Value, Atom) :- string(Value), atom_string(Atom, Value).

text_value(Value) :- string(Value), !.
text_value(Value) :- atom(Value).

copy_option(Key, Source, Target0, Target) :-
    (   get_dict(Key, Source, Value)
    ->  put_dict(Key, Target0, Value, Target)
    ;   Target = Target0
    ).

optional_dict_value(_, none, Dict, Dict) :- !.
optional_dict_value(Key, Value, Dict0, Dict) :- put_dict(Key, Dict0, Value, Dict).

validate_option_keys(Options, Allowed, Protocol) :-
    dict_pairs(Options, _, Pairs),
    forall(member(Key-_, Pairs),
           (   memberchk(Key, Allowed)
           ->  true
           ;   throw(zai_protocol_fault(Key,
                                        unsupported_by_protocol(Protocol)))
           )).

require_list(Value, _) :- is_list(Value), !.
require_list(_, Field) :- throw(zai_protocol_fault(Field, expected_list)).

require_ground_request(Request, Model) :-
    (   ground(Request), ground(Model)
    ->  true
    ;   throw(zai_protocol_fault(request, non_ground_request))
    ).

validate_tool_history(Messages) :-
    validate_tool_history(Messages, [], []).

validate_tool_history([], [], _) :- !.
validate_tool_history([], [_|_], _) :-
    !,
    throw(zai_protocol_fault(messages, unresolved_tool_calls)).
validate_tool_history([Message|Messages], Pending0, Seen0) :-
    get_dict(role, Message, Role),
    validate_history_message(Role, Message, Pending0, Pending, Seen0, Seen),
    validate_tool_history(Messages, Pending, Seen).

validate_history_message(assistant, Message, Pending0, Pending, Seen0, Seen) :-
    Pending0 == [],
    !,
    assistant_calls(Message, Calls),
    maplist(call_id, Calls, Ids),
    append(Seen0, Pending0, Existing),
    (   member(Id, Ids), memberchk(Id, Existing)
    ->  throw(zai_protocol_fault(messages, duplicate_tool_call_id(Id)))
    ;   sort(Ids, Unique), length(Ids, Count), length(Unique, Count)
    ->  append(Pending0, Ids, Pending), append(Seen0, Ids, Seen)
    ;   throw(zai_protocol_fault(messages, duplicate_tool_call_id))
    ).
validate_history_message(tool, Message, Pending0, Pending, Seen, Seen) :-
    !,
    required_message_key(Message, tool_call_id, Id),
    (   select(Id, Pending0, Pending)
    ->  true
    ;   throw(zai_protocol_fault(messages, orphan_tool_result(Id)))
    ).
validate_history_message(Role, _, [_|_], _, _, _) :-
    !,
    throw(zai_protocol_fault(messages, intervening_turn_before_tool_results(Role))).
validate_history_message(_, _, [], [], Seen, Seen).

call_id(Call, Id) :- function_call_fields(Call, Id, _, _).

protocol_validation_error(Field, Detail,
                          error(provider_error{provider:client,
                                               kind:validation_error,
                                               field:Field,
                                               detail:Detail,
                                               message:"request cannot be represented by the selected protocol",
                                               response_received:false})).

config_value(Key, Config, Default, Value) :-
    (   member(Entry, Config), Entry =.. [Key, Found]
    ->  Value = Found
    ;   Value = Default
    ).

dict_default(Key, Dict, Default, Value) :-
    (get_dict(Key, Dict, Found) -> Value = Found ; Value = Default).

empty_dict(Tag, Dict) :- dict_pairs(Dict, Tag, []).

canonical_native_value(Value0, Value) :-
    is_dict(Value0), !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_native_pair, Pairs0, Pairs),
    dict_pairs(Value, provider_native, Pairs).
canonical_native_value(Values0, Values) :-
    is_list(Values0), !,
    maplist(canonical_native_value, Values0, Values).
canonical_native_value(Value, Value) :- ground(Value), !.
canonical_native_value(_, _) :-
    throw(zai_protocol_fault(reasoning_details, non_ground_native_value)).

canonical_native_pair(Key-Value0, Key-Value) :-
    canonical_native_value(Value0, Value).

canonical_json_value(Value0, Value) :-
    is_dict(Value0), !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_json_pair, Pairs0, Pairs),
    dict_pairs(Value, provider_json, Pairs).
canonical_json_value(Values0, Values) :-
    is_list(Values0), !,
    maplist(canonical_json_value, Values0, Values).
canonical_json_value(Value, Value) :- ground(Value).

canonical_json_pair(Key-Value0, Key-Value) :-
    canonical_json_value(Value0, Value).

canonical_protocol_value(Value0, Value) :-
    is_dict(Value0), !,
    dict_pairs(Value0, Tag0, Pairs0),
    canonical_protocol_tag(Tag0, Tag),
    maplist(canonical_protocol_pair, Pairs0, Pairs),
    dict_pairs(Value, Tag, Pairs).
canonical_protocol_value(Values0, Values) :-
    is_list(Values0), !,
    maplist(canonical_protocol_value, Values0, Values).
canonical_protocol_value(Value, Value).

canonical_protocol_tag(Tag0, protocol_data) :- var(Tag0), !.
canonical_protocol_tag(Tag, Tag).

canonical_protocol_pair(Key-Value0, Key-Value) :-
    canonical_protocol_value(Value0, Value).

http_status(Status, Status) :- integer(Status), !.
http_status(Options, Status) :- is_list(Options), memberchk(status_code(Status), Options), !.
http_status(_, unknown).

success_status(Status) :- integer(Status), Status >= 200, Status < 300.
