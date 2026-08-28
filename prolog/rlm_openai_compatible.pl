:- module(rlm_openai_compatible,
          [ openai_compatible_complete/4,
            openai_compatible_stream/5,
            openai_compatible_parse_sse_lines/5,
            normalize_openai_chat_response/5,
            redact_secret/3,
            classify_provider_exception/2
          ]).

/** <module> OpenAI-compatible HTTP transport

Production HTTPS transport and response normalization for OpenAI-compatible
chat-completions providers. Credentials are resolved only while executing a
request and are never returned in provider terms, results, errors, or traces.

Streaming uses `http_open/3` directly and consumes server-sent events from the
response stream as they arrive. It never simulates streaming by splitting a
completed response.
*/

:- use_module(library(http/http_client)).
:- use_module(library(http/http_open)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_ssl_plugin)).
:- use_module(library(http/json)).
:- use_module(library(readutil)).
:- use_module(library(lists)).
:- use_module(library(pairs)).

/* -------------------------------------------------------------------------
 * Non-streaming completion
 * ---------------------------------------------------------------------- */

openai_compatible_complete(Provider, Config, Request, Outcome) :-
    provider_config(Provider, Config, ConfigOutcome),
    complete_from_config(ConfigOutcome, Provider, Request, Outcome).

complete_from_config(error(Error), _, _, error(Error)) :-
    !.
complete_from_config(ok(Endpoint, Credential, RequestedModel, Timeout,
                        AddressFamily, Attribution),
                     Provider, Request, Outcome) :-
    request_payload(Request, RequestedModel, PayloadOutcome),
    complete_payload(PayloadOutcome, Provider, Endpoint, Credential,
                     RequestedModel, Timeout, AddressFamily, Attribution,
                     Outcome).

complete_payload(error(Error), _, _, _, _, _, _, _, error(Error)) :-
    !.
complete_payload(ok(Payload), Provider, Endpoint, Credential,
                 RequestedModel, Timeout, AddressFamily, Attribution,
                 Outcome) :-
    resolve_credential(Provider, Credential, CredentialOutcome),
    execute_credentialed(CredentialOutcome, Provider, Endpoint,
                         RequestedModel, Timeout, AddressFamily,
                         Attribution, Payload,
                         Outcome).

execute_credentialed(error(Error), _, _, _, _, _, _, _, error(Error)) :-
    !.
execute_credentialed(ok(Key), Provider, Endpoint, RequestedModel, Timeout,
                     AddressFamily, Attribution, Payload, Outcome) :-
    http_options(Key, Timeout, AddressFamily, Status, Attribution,
                 HttpOptions),
    catch(http_post(Endpoint, json(Payload), Reply, HttpOptions),
          Exception,
          transport_exception_handler(Exception)),
    (   var(Exception)
    ->  normalize_openai_chat_response(Provider, RequestedModel, Status,
                                       Reply, Outcome)
    ;   classify_provider_exception(Exception, Kind),
        safe_exception_text(Exception, Key, SafeException),
        Outcome = error(provider_error{provider:Provider,
                                       kind:Kind,
                                       exception:SafeException,
                                       response_received:false})
    ).

http_options(Key, Timeout, AddressFamily, Status, Attribution, Options) :-
    credential_http_options(Key, CredentialOptions),
    address_family_http_options(AddressFamily, AddressOptions),
    append([CredentialOptions,
            AddressOptions,
            [ timeout(Timeout),
              status_code(Status),
              json_object(dict),
              request_header('Accept'='application/json'),
              user_agent('prolog-rlm/0.1')
            ],
            Attribution],
           Options).

/* -------------------------------------------------------------------------
 * True SSE streaming
 * ---------------------------------------------------------------------- */

%!  openai_compatible_stream(+Provider, +Config, +Request,
%!                           +EventHandler, -Outcome) is det.
%
%   Execute an OpenAI-compatible chat-completions request with `stream:true`.
%   `EventHandler` is called synchronously and incrementally for canonical,
%   ground `stream_event{}` terms as SSE data arrives. The final outcome is
%   `ok(stream_result{response:ModelResponse, events:Events})`.

openai_compatible_stream(Provider, Config, Request, EventHandler, Outcome) :-
    (   callable(EventHandler)
    ->  provider_config(Provider, Config, ConfigOutcome),
        stream_from_config(ConfigOutcome,
                           Provider,
                           Request,
                           EventHandler,
                           Outcome)
    ;   Outcome = error(provider_error{provider:client,
                                       kind:validation_error,
                                       field:event_handler,
                                       message:"stream event handler must be callable",
                                       response_received:false})
    ).

stream_from_config(error(Error), _, _, _, error(Error)) :-
    !.
stream_from_config(ok(Endpoint, Credential, RequestedModel, Timeout,
                      AddressFamily, Attribution),
                   Provider, Request, EventHandler, Outcome) :-
    request_payload(Request, RequestedModel, PayloadOutcome),
    stream_payload(PayloadOutcome,
                   Provider,
                   Endpoint,
                   Credential,
                   RequestedModel,
                   Timeout,
                   AddressFamily,
                   Attribution,
                   EventHandler,
                   Outcome).

stream_payload(error(Error), _, _, _, _, _, _, _, _, error(Error)) :-
    !.
stream_payload(ok(Payload0), Provider, Endpoint, Credential,
               RequestedModel, Timeout, AddressFamily, Attribution,
               EventHandler,
               Outcome) :-
    put_dict(stream_request{stream:true,
                            stream_options:stream_options{include_usage:true}},
             Payload0,
             Payload),
    resolve_credential(Provider, Credential, CredentialOutcome),
    execute_stream_credentialed(CredentialOutcome,
                                Provider,
                                Endpoint,
                                RequestedModel,
                                Timeout,
                                AddressFamily,
                                Attribution,
                                Payload,
                                EventHandler,
                                Outcome).

execute_stream_credentialed(error(Error), _, _, _, _, _, _, _, _,
                            error(Error)) :-
    !.
execute_stream_credentialed(ok(Key), Provider, Endpoint, RequestedModel,
                            Timeout, AddressFamily, Attribution, Payload,
                            EventHandler,
                            Outcome) :-
    stream_http_options(Key, Timeout, AddressFamily, Status, Payload,
                        Attribution, HttpOptions),
    catch(setup_call_cleanup(
              http_open(Endpoint, In, HttpOptions),
              stream_http_result(Status,
                                 In,
                                 Provider,
                                 RequestedModel,
                                 EventHandler,
                                 StreamOutcome),
              close(In)),
          Exception,
          transport_exception_handler(Exception)),
    (   var(Exception)
    ->  Outcome = StreamOutcome
    ;   classify_provider_exception(Exception, Kind),
        safe_exception_text(Exception, Key, SafeException),
        Outcome = error(provider_error{provider:Provider,
                                       kind:Kind,
                                       exception:SafeException,
                                       response_received:false})
    ).

stream_http_options(Key, Timeout, AddressFamily, Status, Payload,
                    Attribution, Options) :-
    credential_http_options(Key, CredentialOptions),
    address_family_http_options(AddressFamily, AddressOptions),
    append([CredentialOptions,
            AddressOptions,
            [ post(json(Payload)),
              timeout(Timeout),
              status_code(Status),
              request_header('Accept'='text/event-stream'),
              user_agent('prolog-rlm/0.1')
            ],
            Attribution],
           Options).

credential_http_options(none, []) :-
    !.
credential_http_options(Key, [authorization(bearer(Key))]).

address_family_http_options(auto, []) :-
    !.
address_family_http_options(Family, [domain(Family)]).

stream_http_result(Status, In, Provider, RequestedModel, EventHandler,
                   Outcome) :-
    (   integer(Status), Status >= 200, Status < 300
    ->  stream_state_new(Provider, RequestedModel, Status, State0),
        catch(consume_sse_stream(In,
                                 EventHandler,
                                 State0,
                                 State),
              Exception,
              stream_parser_exception(Provider,
                                      Status,
                                      Exception,
                                      ParseOutcome)),
        (   var(ParseOutcome)
        ->  finalize_stream_state(State, Outcome)
        ;   Outcome = ParseOutcome
        )
    ;   read_string(In, _, Body),
        stream_http_error(Provider, Status, Body, Outcome)
    ).

stream_http_error(Provider, Status, Body, Outcome) :-
    (   string(Body), Body \== "",
        catch(( atom_string(Atom, Body),
                atom_json_dict(Atom, Raw, []) ),
              _,
              fail),
        is_dict(Raw)
    ->  normalize_http_error(Provider, Status, Raw, Outcome)
    ;   Outcome = error(provider_error{provider:Provider,
                                       kind:http_error,
                                       http_status:Status,
                                       message:"provider returned a non-success streaming HTTP response",
                                       response_received:true})
    ).

%!  openai_compatible_parse_sse_lines(+Provider, +RequestedModel, +Lines,
%!                                    +EventHandler, -Outcome) is det.
%
%   Deterministic parser entry point for conformance tests. It consumes the
%   same SSE line parser used by the network transport, including `[DONE]`,
%   usage chunks, tool-call deltas and final response aggregation.

openai_compatible_parse_sse_lines(Provider,
                                  RequestedModel,
                                  Lines,
                                  EventHandler,
                                  Outcome) :-
    (   is_list(Lines), callable(EventHandler)
    ->  stream_state_new(Provider, RequestedModel, 200, State0),
        catch(consume_sse_lines(Lines,
                                EventHandler,
                                State0,
                                State),
              Exception,
              stream_parser_exception(Provider,
                                      200,
                                      Exception,
                                      ParseOutcome)),
        (   var(ParseOutcome)
        ->  finalize_stream_state(State, Outcome)
        ;   Outcome = ParseOutcome
        )
    ;   Outcome = error(provider_error{provider:client,
                                       kind:validation_error,
                                       field:sse_lines,
                                       message:"SSE lines must be a list and event handler callable",
                                       response_received:false})
    ).

stream_state_new(Provider, RequestedModel, Status,
                 stream_state{provider:Provider,
                              requested_model:RequestedModel,
                              http_status:Status,
                              response_id:null,
                              selected_model:RequestedModel,
                              role:assistant,
                              text:"",
                              reasoning:"",
                              reasoning_details:[],
                              tool_states:[],
                              finish_reason:null,
                              usage:usage{present:false,
                                          prompt_tokens:null,
                                          completion_tokens:null,
                                          total_tokens:null,
                                          cost:null},
                              events_rev:[],
                              done:false}).

consume_sse_stream(In, EventHandler, State0, State) :-
    read_line_to_string(In, Line),
    (   Line == end_of_file
    ->  State = State0
    ;   consume_sse_line(Line,
                         EventHandler,
                         State0,
                         State1,
                         Stop),
        (   Stop == true
        ->  State = State1
        ;   consume_sse_stream(In, EventHandler, State1, State)
        )
    ).

consume_sse_lines([], _, State, State).
consume_sse_lines([Line|Lines], EventHandler, State0, State) :-
    consume_sse_line(Line, EventHandler, State0, State1, Stop),
    (   Stop == true
    ->  State = State1
    ;   consume_sse_lines(Lines, EventHandler, State1, State)
    ).

consume_sse_line(Line0, EventHandler, State0, State, Stop) :-
    line_string(Line0, Line),
    (   sse_data_line(Line, Data)
    ->  process_sse_data(Data, EventHandler, State0, State, Stop)
    ;   State = State0,
        Stop = false
    ).

line_string(Line, Line) :- string(Line), !.
line_string(Line, Text) :- atom(Line), !, atom_string(Line, Text).
line_string(Line, _) :- throw(openai_stream_fault(invalid_sse_line(Line))).

sse_data_line(Line, Data) :-
    sub_string(Line, 0, 5, _, "data:"),
    !,
    sub_string(Line, 5, _, 0, Rest),
    strip_single_space(Rest, Data).

strip_single_space(Rest, Data) :-
    (   sub_string(Rest, 0, 1, _, " ")
    ->  sub_string(Rest, 1, _, 0, Data)
    ;   Data = Rest
    ).

process_sse_data("[DONE]", EventHandler, State0, State, true) :-
    !,
    Event = stream_event{type:done},
    emit_stream_event(EventHandler, Event, State0, State1),
    put_dict(done, State1, true, State).
process_sse_data("", _, State, State, false) :-
    !.
process_sse_data(Data, EventHandler, State0, State, false) :-
    atom_string(Atom, Data),
    catch(atom_json_dict(Atom, RawChunk, []),
          Exception,
          throw(openai_stream_fault(invalid_json(Exception)))),
    (   is_dict(RawChunk)
    ->  canonical_stream_value(RawChunk, Chunk),
        process_stream_chunk(Chunk, EventHandler, State0, State)
    ;   throw(openai_stream_fault(non_object_chunk(RawChunk)))
    ).

canonical_stream_value(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_stream_pair, Pairs0, Pairs),
    dict_pairs(Value, stream_data, Pairs).
canonical_stream_value(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_stream_value, Values0, Values).
canonical_stream_value(Value, Value) :-
    ground(Value),
    !.
canonical_stream_value(Value, _) :-
    throw(openai_stream_fault(non_ground_json_value(Value))).

canonical_stream_pair(Key-Value0, Key-Value) :-
    canonical_stream_value(Value0, Value).

process_stream_chunk(Chunk, EventHandler, State0, State) :-
    update_stream_envelope(Chunk, State0, State1),
    dict_default(choices, Chunk, [], Choices0),
    (   is_list(Choices0)
    ->  Choices = Choices0
    ;   throw(openai_stream_fault(invalid_choices(Choices0)))
    ),
    process_stream_choices(Choices, EventHandler, State1, State2),
    process_stream_usage(Chunk, EventHandler, State2, State).

update_stream_envelope(Chunk, State0, State) :-
    (   get_dict(id, Chunk, Id), Id \== null
    ->  put_dict(response_id, State0, Id, State1)
    ;   State1 = State0
    ),
    (   get_dict(model, Chunk, Model), Model \== null
    ->  put_dict(selected_model, State1, Model, State)
    ;   State = State1
    ).

process_stream_choices([], _, State, State).
process_stream_choices([Choice|Choices], EventHandler, State0, State) :-
    (   is_dict(Choice)
    ->  process_stream_choice(Choice, EventHandler, State0, State1)
    ;   throw(openai_stream_fault(invalid_choice(Choice)))
    ),
    process_stream_choices(Choices, EventHandler, State1, State).

process_stream_choice(Choice, EventHandler, State0, State) :-
    dict_default(index, Choice, 0, ChoiceIndex),
    dict_default(delta, Choice, stream_data{}, Delta),
    (   is_dict(Delta)
    ->  true
    ;   throw(openai_stream_fault(invalid_delta(Delta)))
    ),
    process_stream_role(Delta, State0, State1),
    process_stream_text(ChoiceIndex, Delta, EventHandler, State1, State2),
    process_stream_reasoning(ChoiceIndex,
                             Delta,
                             EventHandler,
                             State2,
                             State3),
    process_stream_reasoning_details(ChoiceIndex,
                                     Delta,
                                     EventHandler,
                                     State3,
                                     State4),
    process_stream_tool_calls(ChoiceIndex,
                              Delta,
                              EventHandler,
                              State4,
                              State5),
    process_stream_finish(ChoiceIndex,
                          Choice,
                          EventHandler,
                          State5,
                          State).

process_stream_role(Delta, State0, State) :-
    (   get_dict(role, Delta, Role), Role \== null
    ->  put_dict(role, State0, Role, State)
    ;   State = State0
    ).

process_stream_text(ChoiceIndex, Delta, EventHandler, State0, State) :-
    (   get_dict(content, Delta, Content0),
        Content0 \== null
    ->  stream_text(Content0, Content),
        (   Content == ""
        ->  State = State0
        ;   string_concat(State0.text, Content, Text),
            put_dict(text, State0, Text, State1),
            Event = stream_event{type:text,
                                 choice_index:ChoiceIndex,
                                 delta:Content},
            emit_stream_event(EventHandler, Event, State1, State)
        )
    ;   State = State0
    ).

process_stream_reasoning(ChoiceIndex, Delta, EventHandler, State0, State) :-
    (   get_dict(reasoning, Delta, Reasoning0),
        Reasoning0 \== null
    ->  stream_text(Reasoning0, Reasoning),
        (   Reasoning == ""
        ->  State = State0
        ;   string_concat(State0.reasoning, Reasoning, Combined),
            put_dict(reasoning, State0, Combined, State1),
            Event = stream_event{type:reasoning,
                                 choice_index:ChoiceIndex,
                                 delta:Reasoning},
            emit_stream_event(EventHandler, Event, State1, State)
        )
    ;   State = State0
    ).

process_stream_reasoning_details(ChoiceIndex,
                                 Delta,
                                 EventHandler,
                                 State0,
                                 State) :-
    (   get_dict(reasoning_details, Delta, Details),
        is_list(Details), Details \== []
    ->  append(State0.reasoning_details, Details, Combined),
        put_dict(reasoning_details, State0, Combined, State1),
        Event = stream_event{type:reasoning,
                             choice_index:ChoiceIndex,
                             details:Details},
        emit_stream_event(EventHandler, Event, State1, State)
    ;   State = State0
    ).

process_stream_tool_calls(ChoiceIndex, Delta, EventHandler, State0, State) :-
    (   get_dict(tool_calls, Delta, Calls),
        is_list(Calls), Calls \== []
    ->  process_tool_call_deltas(Calls,
                                 ChoiceIndex,
                                 EventHandler,
                                 State0,
                                 State)
    ;   State = State0
    ).

process_tool_call_deltas([], _, _, State, State).
process_tool_call_deltas([Call|Calls], ChoiceIndex, EventHandler,
                         State0, State) :-
    (   is_dict(Call)
    ->  dict_default(index, Call, 0, ToolIndex),
        aggregate_tool_call(Call, ToolIndex, State0, State1),
        Event = stream_event{type:tool_call,
                             choice_index:ChoiceIndex,
                             tool_index:ToolIndex,
                             delta:Call},
        emit_stream_event(EventHandler, Event, State1, State2)
    ;   throw(openai_stream_fault(invalid_tool_call_delta(Call)))
    ),
    process_tool_call_deltas(Calls,
                             ChoiceIndex,
                             EventHandler,
                             State2,
                             State).

aggregate_tool_call(Call, ToolIndex, State0, State) :-
    take_tool_state(ToolIndex,
                    State0.tool_states,
                    Tool0,
                    Rest),
    update_tool_state(Call, Tool0, Tool),
    put_dict(tool_states, State0, [Tool|Rest], State).

take_tool_state(Index, [],
                tool_state{index:Index,
                           id:null,
                           type:"function",
                           name:"",
                           arguments:""},
                []).
take_tool_state(Index, [Tool|Tools], Found, Rest) :-
    (   Tool.index =:= Index
    ->  Found = Tool,
        Rest = Tools
    ;   take_tool_state(Index, Tools, Found, Tail),
        Rest = [Tool|Tail]
    ).

update_tool_state(Call, Tool0, Tool) :-
    update_tool_scalar(Call, id, Tool0, Tool1),
    update_tool_scalar(Call, type, Tool1, Tool2),
    (   get_dict(function, Call, Function), is_dict(Function)
    ->  dict_default(name, Function, null, Name0),
        append_stream_piece(Name0, Tool2.name, Name),
        dict_default(arguments, Function, null, Arguments0),
        append_stream_piece(Arguments0, Tool2.arguments, Arguments),
        put_dict(tool_update{name:Name, arguments:Arguments}, Tool2, Tool)
    ;   Tool = Tool2
    ).

update_tool_scalar(Call, Key, Tool0, Tool) :-
    (   get_dict(Key, Call, Value), Value \== null
    ->  put_dict(Key, Tool0, Value, Tool)
    ;   Tool = Tool0
    ).

append_stream_piece(null, Existing, Existing) :- !.
append_stream_piece(Piece0, Existing, Combined) :-
    stream_text(Piece0, Piece),
    string_concat(Existing, Piece, Combined).

process_stream_finish(ChoiceIndex, Choice, EventHandler, State0, State) :-
    (   get_dict(finish_reason, Choice, Finish),
        Finish \== null,
        Finish \== State0.finish_reason
    ->  put_dict(finish_reason, State0, Finish, State1),
        Event = stream_event{type:finish,
                             choice_index:ChoiceIndex,
                             finish_reason:Finish},
        emit_stream_event(EventHandler, Event, State1, State)
    ;   State = State0
    ).

process_stream_usage(Chunk, EventHandler, State0, State) :-
    (   get_dict(usage, Chunk, RawUsage), is_dict(RawUsage)
    ->  normalize_usage(Chunk, Usage),
        put_dict(usage, State0, Usage, State1),
        Event = stream_event{type:usage, usage:Usage},
        emit_stream_event(EventHandler, Event, State1, State)
    ;   State = State0
    ).

emit_stream_event(EventHandler, Event, State0, State) :-
    (   ground(Event)
    ->  true
    ;   throw(openai_stream_fault(non_ground_event(Event)))
    ),
    (   call(EventHandler, Event)
    ->  put_dict(events_rev, State0, [Event|State0.events_rev], State)
    ;   throw(openai_stream_fault(event_handler_failed(Event)))
    ).

finalize_stream_state(State, Outcome) :-
    (   State.done == true
    ->  finalize_stream_done(State, Outcome)
    ;   Outcome = error(provider_error{provider:State.provider,
                                       kind:invalid_stream,
                                       http_status:State.http_status,
                                       detail:missing_done,
                                       message:"stream ended before the [DONE] sentinel",
                                       response_received:true})
    ).

finalize_stream_done(State, Outcome) :-
    tool_states_calls(State.tool_states, ToolCalls),
    (   assistant_payload_present(State.text,
                                  ToolCalls,
                                  State.reasoning,
                                  State.reasoning_details)
    ->  Assistant = message{role:State.role,
                            content:State.text,
                            tool_calls:ToolCalls,
                            reasoning:State.reasoning,
                            reasoning_details:State.reasoning_details},
        Metadata = provider_metadata{provider:State.provider,
                                     http_status:State.http_status,
                                     response_received:true,
                                     streaming:true},
        Response = model_response{provider:State.provider,
                                  requested_model:State.requested_model,
                                  selected_model:State.selected_model,
                                  response_id:State.response_id,
                                  assistant:Assistant,
                                  text:State.text,
                                  tool_calls:ToolCalls,
                                  reasoning:State.reasoning,
                                  reasoning_details:State.reasoning_details,
                                  finish_reason:State.finish_reason,
                                  usage:State.usage,
                                  metadata:Metadata},
        reverse(State.events_rev, Events),
        Outcome = ok(stream_result{response:Response, events:Events})
    ;   Outcome = error(provider_error{provider:State.provider,
                                       kind:invalid_stream,
                                       http_status:State.http_status,
                                       message:"stream completed without assistant content, reasoning, or tool calls",
                                       response_received:true})
    ).

tool_states_calls(States, Calls) :-
    maplist(tool_state_pair, States, Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Calls).

tool_state_pair(Tool, Index-Call) :-
    Index = Tool.index,
    Function = tool_function{name:Tool.name, arguments:Tool.arguments},
    Call = tool_call{index:Tool.index,
                     id:Tool.id,
                     type:Tool.type,
                     function:Function}.

stream_text(Value, Value) :- string(Value), !.
stream_text(Value, Text) :- atom(Value), !, atom_string(Value, Text).
stream_text(Value, _) :- throw(openai_stream_fault(invalid_text_delta(Value))).

stream_parser_exception(_, _, error(rlm_cancelled(Token), Context), _) :-
    !,
    throw(error(rlm_cancelled(Token), Context)).
stream_parser_exception(_, _, time_limit_exceeded, _) :-
    !,
    throw(time_limit_exceeded).
stream_parser_exception(_, _, time_limit_exceeded(Context), _) :-
    !,
    throw(time_limit_exceeded(Context)).
stream_parser_exception(Provider, Status, openai_stream_fault(Detail),
                        error(Error)) :-
    !,
    Error = provider_error{provider:Provider,
                           kind:invalid_stream,
                           http_status:Status,
                           detail:Detail,
                           message:"provider stream could not be normalized",
                           response_received:true}.
stream_parser_exception(Provider, Status, Exception, error(Error)) :-
    safe_exception_text(Exception, none, Safe),
    Error = provider_error{provider:Provider,
                           kind:invalid_stream,
                           http_status:Status,
                           exception:Safe,
                           message:"provider stream parser raised an exception",
                           response_received:true}.

/* -------------------------------------------------------------------------
 * Provider configuration and control exceptions
 * ---------------------------------------------------------------------- */

provider_config(Provider, Config, Outcome) :-
    (   is_list(Config)
    ->  config_value(endpoint, Config, none, Endpoint),
        config_value(model, Config, none, Model),
        config_value(credential, Config, none, Credential),
        config_value(timeout, Config, 30, Timeout),
        config_value(address_family, Config, auto, AddressFamily),
        config_value(app_title, Config, none, AppTitle),
        config_value(app_referer, Config, none, AppReferer),
        validate_provider_config(Provider, Endpoint, Model, Credential,
                                 Timeout, AddressFamily, AppTitle,
                                 AppReferer, Outcome)
    ;   Outcome = error(provider_error{provider:Provider,
                                       kind:configuration_error,
                                       field:config,
                                       message:"provider config must be a list",
                                       response_received:false})
    ).

validate_provider_config(Provider, none, _, _, _, _, error(Error)) :-
    !,
    Error = provider_error{provider:Provider,
                           kind:configuration_error,
                           field:endpoint,
                           message:"provider endpoint is not configured",
                           response_received:false}.
validate_provider_config(Provider, _, none, _, _, _, error(Error)) :-
    !,
    Error = provider_error{provider:Provider,
                           kind:configuration_error,
                           field:model,
                           message:"provider model is not configured",
                           response_received:false}.
validate_provider_config(Provider, _, _, Credential, _, _, error(Error)) :-
    \+ valid_credential_spec(Credential),
    !,
    Error = provider_error{provider:Provider,
                           kind:configuration_error,
                           field:credential,
                           message:"credentials must use env(Name) or none",
                           response_received:false}.
validate_provider_config(Provider, _, _, _, Timeout, _, error(Error)) :-
    (   \+ number(Timeout)
    ;   Timeout =< 0
    ),
    !,
    Error = provider_error{provider:Provider,
                           kind:configuration_error,
                           field:timeout,
                           message:"timeout must be a positive number",
                           response_received:false}.
validate_provider_config(Provider, _, _, _, _, AddressFamily, _, _, error(Error)) :-
    \+ memberchk(AddressFamily, [auto, inet, inet6]),
    !,
    Error = provider_error{provider:Provider,
                           kind:configuration_error,
                           field:address_family,
                           message:"address_family must be auto, inet, or inet6",
                           response_received:false}.
validate_provider_config(Provider, _, _, _, _, _, AppTitle, _, error(Error)) :-
    \+ valid_attribution_spec(AppTitle),
    !,
    Error = provider_error{provider:Provider,
                           kind:configuration_error,
                           field:app_title,
                           message:"app_title must be a nonempty atom or string",
                           response_received:false}.
validate_provider_config(Provider, _, _, _, _, _, _, AppReferer, error(Error)) :-
    \+ valid_attribution_spec(AppReferer),
    !,
    Error = provider_error{provider:Provider,
                           kind:configuration_error,
                           field:app_referer,
                           message:"app_referer must be a nonempty atom or string",
                           response_received:false}.
validate_provider_config(_, Endpoint, Model, Credential, Timeout,
                         AddressFamily, AppTitle, AppReferer,
                         ok(Endpoint, Credential, Model, Timeout,
                            AddressFamily, Attribution)) :-
    attribution_http_options(app_title, AppTitle, TitleOptions),
    attribution_http_options(app_referer, AppReferer, RefererOptions),
    append(TitleOptions, RefererOptions, Attribution).

% OpenRouter app attribution: optional descriptive identity headers. They
% never grant authority; the provider validates credentials and payloads
% exactly as before. `none` sends no header, so custom OpenAI-compatible
% endpoints are unchanged unless a host opts in.
valid_attribution_spec(none).
valid_attribution_spec(Value) :-
    nonempty_header_text(Value).

nonempty_header_text(Value) :-
    atom(Value),
    !,
    Value \== ''.
nonempty_header_text(Value) :-
    string(Value),
    Value \== "".

attribution_http_options(_, none, []) :-
    !.
attribution_http_options(app_title, Value,
                         [request_header('X-OpenRouter-Title'=Value)]).
attribution_http_options(app_referer, Value,
                         [request_header('HTTP-Referer'=Value)]).

valid_credential_spec(none).
valid_credential_spec(env(Name)) :-
    (   atom(Name)
    ;   string(Name)
    ).

resolve_credential(_, none, ok(none)) :-
    !.
resolve_credential(Provider, env(Name), Outcome) :-
    !,
    (   getenv(Name, Key),
        Key \== '',
        Key \== ""
    ->  Outcome = ok(Key)
    ;   format(string(Message),
               "credential environment variable ~w is not configured",
               [Name]),
        Outcome = error(provider_error{provider:Provider,
                                       kind:missing_credential,
                                       credential:env(Name),
                                       message:Message,
                                       response_received:false})
    ).

transport_exception_handler(error(rlm_cancelled(Token), Context)) :-
    !,
    throw(error(rlm_cancelled(Token), Context)).
transport_exception_handler(time_limit_exceeded) :-
    !,
    throw(time_limit_exceeded).
transport_exception_handler(time_limit_exceeded(Context)) :-
    !,
    throw(time_limit_exceeded(Context)).
transport_exception_handler(_).

/* -------------------------------------------------------------------------
 * Completed-response normalization
 * ---------------------------------------------------------------------- */

normalize_openai_chat_response(Provider, RequestedModel, HttpInfo, Raw,
                               Outcome) :-
    http_status(HttpInfo, Status),
    (   integer(Status), Status >= 200, Status < 300
    ->  normalize_success_response(Provider, RequestedModel, Status, Raw,
                                   Outcome)
    ;   normalize_http_error(Provider, Status, Raw, Outcome)
    ).

http_status(Status, Status) :-
    integer(Status),
    !.
http_status(Options, Status) :-
    is_list(Options),
    memberchk(status_code(Status), Options),
    !.
http_status(_, unknown).

normalize_success_response(Provider, RequestedModel, Status, Raw, Outcome) :-
    (   \+ is_dict(Raw)
    ->  Outcome = error(provider_error{provider:Provider,
                                       kind:invalid_response,
                                       http_status:Status,
                                       message:"provider response is not a JSON object",
                                       response_received:true})
    ;   wire_error(Raw, WireError)
    ->  provider_error_from_wire(Provider, Status, WireError, Outcome)
    ;   first_assistant_choice(Raw, Choice, Message)
    ->  normalize_choice(Provider, RequestedModel, Status, Raw, Choice,
                         Message, Outcome)
    ;   Outcome = error(provider_error{provider:Provider,
                                       kind:invalid_response,
                                       http_status:Status,
                                       message:"provider response has no assistant choice",
                                       response_received:true})
    ).

wire_error(Dict, Error) :-
    get_dict(error, Dict, Error),
    Error \== null.

first_assistant_choice(Raw, Choice, Message) :-
    get_dict(choices, Raw, Choices),
    Choices = [Choice|_],
    is_dict(Choice),
    get_dict(message, Choice, Message),
    is_dict(Message).

normalize_choice(Provider, RequestedModel, Status, Raw, Choice, Message,
                 Outcome) :-
    (   wire_error(Choice, ChoiceError)
    ->  provider_error_from_wire(Provider, Status, ChoiceError, Outcome)
    ;   dict_default(content, Message, null, Content0),
        normalize_content(Content0, Text),
        dict_default(tool_calls, Message, [], ToolCalls0),
        normalize_list(ToolCalls0, ToolCalls),
        dict_default(reasoning, Message, null, Reasoning0),
        normalize_content(Reasoning0, Reasoning),
        dict_default(reasoning_details, Message, [], ReasoningDetails0),
        normalize_list(ReasoningDetails0, ReasoningDetails),
        normalize_assistant_result(Provider, RequestedModel, Status, Raw,
                                   Choice, Message, Text, ToolCalls,
                                   Reasoning, ReasoningDetails, Outcome)
    ).

normalize_assistant_result(Provider, _, Status, _, _, _, Text, ToolCalls,
                           Reasoning, ReasoningDetails, error(Error)) :-
    \+ assistant_payload_present(Text, ToolCalls, Reasoning,
                                 ReasoningDetails),
    !,
    Error = provider_error{provider:Provider,
                           kind:invalid_response,
                           http_status:Status,
                           message:"assistant choice contains no content, tool calls, or reasoning output",
                           response_received:true}.
normalize_assistant_result(Provider, RequestedModel, Status, Raw, Choice,
                           Message, Text, ToolCalls, Reasoning,
                           ReasoningDetails, ok(Response)) :-
    dict_default(role, Message, assistant, Role),
    dict_default(finish_reason, Choice, null, FinishReason),
    dict_default(model, Raw, RequestedModel, SelectedModel),
    dict_default(id, Raw, null, ResponseId),
    normalize_usage(Raw, Usage),
    Assistant = message{role:Role,
                        content:Text,
                        tool_calls:ToolCalls,
                        reasoning:Reasoning,
                        reasoning_details:ReasoningDetails},
    Metadata = provider_metadata{provider:Provider,
                                 http_status:Status,
                                 response_received:true},
    Response = model_response{provider:Provider,
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
                              metadata:Metadata}.

assistant_payload_present(Text, _, _, _) :-
    Text \== "",
    !.
assistant_payload_present(_, ToolCalls, _, _) :-
    ToolCalls \== [],
    !.
assistant_payload_present(_, _, Reasoning, _) :-
    Reasoning \== "",
    !.
assistant_payload_present(_, _, _, ReasoningDetails) :-
    ReasoningDetails \== [].

normalize_http_error(Provider, Status, Raw, Outcome) :-
    (   is_dict(Raw), wire_error(Raw, WireError)
    ->  provider_error_from_wire(Provider, Status, WireError, Outcome)
    ;   Outcome = error(provider_error{provider:Provider,
                                       kind:http_error,
                                       http_status:Status,
                                       message:"provider returned a non-success HTTP response",
                                       response_received:true})
    ).

provider_error_from_wire(Provider, Status, WireError, error(Error)) :-
    wire_error_fields(WireError, Code, Message, ErrorType),
    Error = provider_error{provider:Provider,
                           kind:provider_error,
                           http_status:Status,
                           code:Code,
                           error_type:ErrorType,
                           message:Message,
                           response_received:true}.

wire_error_fields(WireError, Code, Message, ErrorType) :-
    (   is_dict(WireError)
    ->  dict_default(code, WireError, null, Code),
        dict_default(message, WireError, "provider returned an error",
                     Message0),
        normalize_content(Message0, Message),
        wire_error_type(WireError, ErrorType)
    ;   Code = null,
        normalize_content(WireError, Message),
        ErrorType = null
    ).

wire_error_type(WireError, ErrorType) :-
    (   get_dict(metadata, WireError, Metadata),
        is_dict(Metadata),
        get_dict(error_type, Metadata, Found)
    ->  ErrorType = Found
    ;   ErrorType = null
    ).

normalize_usage(Raw, Usage) :-
    (   get_dict(usage, Raw, RawUsage), is_dict(RawUsage)
    ->  dict_default(prompt_tokens, RawUsage, null, PromptTokens),
        dict_default(completion_tokens, RawUsage, null, CompletionTokens),
        dict_default(total_tokens, RawUsage, null, TotalTokens),
        dict_default(cost, RawUsage, null, Cost),
        Usage = usage{present:true,
                      prompt_tokens:PromptTokens,
                      completion_tokens:CompletionTokens,
                      total_tokens:TotalTokens,
                      cost:Cost}
    ;   Usage = usage{present:false,
                      prompt_tokens:null,
                      completion_tokens:null,
                      total_tokens:null,
                      cost:null}
    ).

normalize_list(Value, Value) :-
    is_list(Value),
    !.
normalize_list(_, []).

normalize_content(null, "") :-
    !.
normalize_content(Content, Content) :-
    string(Content),
    !.
normalize_content(Content, String) :-
    atom(Content),
    !,
    atom_string(Content, String).
normalize_content(Content, String) :-
    term_string(Content, String, [quoted(true), numbervars(true)]).

/* -------------------------------------------------------------------------
 * Request normalization
 * ---------------------------------------------------------------------- */

request_payload(Request, RequestedModel, Outcome) :-
    validate_request(Request, Validation),
    (   Validation = error(Error)
    ->  Outcome = error(Error)
    ;   get_dict(messages, Request, Messages0),
        maplist(message_payload, Messages0, Messages),
        request_options(Request, RequestOptions),
        allowed_generation_options(RequestOptions, GenerationOptions),
        put_dict(request_payload{model:RequestedModel, messages:Messages},
                 GenerationOptions, Payload),
        Outcome = ok(Payload)
    ).

validate_request(Request, error(Error)) :-
    \+ is_dict(Request, model_request),
    !,
    Error = provider_error{provider:client,
                           kind:validation_error,
                           field:request,
                           message:"model request must be a model_request dict",
                           response_received:false}.
validate_request(Request, error(Error)) :-
    \+ valid_messages_list(Request, _),
    !,
    Error = provider_error{provider:client,
                           kind:validation_error,
                           field:messages,
                           message:"model request requires a non-empty messages list",
                           response_received:false}.
validate_request(Request, error(Error)) :-
    valid_messages_list(Request, Messages),
    \+ maplist(valid_message, Messages),
    !,
    Error = provider_error{provider:client,
                           kind:validation_error,
                           field:messages,
                           message:"every message requires a supported role and content",
                           response_received:false}.
validate_request(_, ok).

valid_messages_list(Request, Messages) :-
    get_dict(messages, Request, Messages),
    is_list(Messages),
    Messages \== [].

valid_message(Message) :-
    is_dict(Message),
    get_dict(role, Message, Role),
    memberchk(Role, [system, user, assistant, tool]),
    get_dict(content, Message, Content),
    valid_message_content(Content).

valid_message_content(Content) :-
    string(Content),
    !.
valid_message_content(Content) :-
    atom(Content),
    !.
valid_message_content(Content) :-
    is_list(Content).

message_payload(Message, Payload) :-
    get_dict(role, Message, Role),
    get_dict(content, Message, Content),
    Base = message_payload{role:Role, content:Content},
    copy_optional_message_fields([name,
                                  tool_call_id,
                                  tool_calls,
                                  reasoning,
                                  reasoning_details],
                                 Message, Base, Payload).

copy_optional_message_fields([], _, Payload, Payload).
copy_optional_message_fields([Key|Keys], Message, Payload0, Payload) :-
    (   get_dict(Key, Message, Value)
    ->  put_dict(Key, Payload0, Value, Payload1)
    ;   Payload1 = Payload0
    ),
    copy_optional_message_fields(Keys, Message, Payload1, Payload).

request_options(Request, Options) :-
    (   get_dict(options, Request, Candidate), is_dict(Candidate)
    ->  Options = Candidate
    ;   Options = generation_options{}
    ).

allowed_generation_options(Options, Allowed) :-
    Keys = [max_tokens,
            max_completion_tokens,
            temperature,
            top_p,
            seed,
            stop,
            tools,
            tool_choice,
            response_format,
            reasoning],
    include_present_keys(Keys, Options, generation_options{}, Allowed).

include_present_keys([], _, Allowed, Allowed).
include_present_keys([Key|Keys], Source, Allowed0, Allowed) :-
    (   get_dict(Key, Source, Value)
    ->  put_dict(Key, Allowed0, Value, Allowed1)
    ;   Allowed1 = Allowed0
    ),
    include_present_keys(Keys, Source, Allowed1, Allowed).

/* -------------------------------------------------------------------------
 * Generic helpers, exception classification and redaction
 * ---------------------------------------------------------------------- */

config_value(Key, Config, Default, Value) :-
    (   member(Entry, Config), Entry =.. [Key, Found]
    ->  Value = Found
    ;   Value = Default
    ).

dict_default(Key, Dict, Default, Value) :-
    (   get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

classify_provider_exception(Exception, timeout) :-
    term_string(Exception, Text),
    string_lower(Text, Lower),
    (   sub_string(Lower, _, _, _, "timeout")
    ;   sub_string(Lower, _, _, _, "timed out")
    ),
    !.
classify_provider_exception(_, transport_error).

safe_exception_text(Exception, Secret, SafeText) :-
    redact_secret(Exception, Secret, SafeException),
    term_string(SafeException, SafeText, [quoted(true), numbervars(true)]).

redact_secret(Term, Secret, Safe) :-
    (   var(Term)
    ->  Safe = Term
    ;   is_dict(Term)
    ->  dict_pairs(Term, Tag, Pairs0),
        maplist(redact_pair(Secret), Pairs0, Pairs),
        dict_pairs(Safe, Tag, Pairs)
    ;   string(Term)
    ->  redact_string(Term, Secret, Safe)
    ;   atom(Term)
    ->  atom_string(Term, Text),
        redact_string(Text, Secret, SafeText),
        atom_string(Safe, SafeText)
    ;   atomic(Term)
    ->  Safe = Term
    ;   Term =.. [Functor|Args0],
        maplist(redact_arg(Secret), Args0, Args),
        Safe =.. [Functor|Args]
    ).

redact_pair(Secret, Key-Value0, Key-Value) :-
    redact_secret(Value0, Secret, Value).

redact_arg(Secret, Value0, Value) :-
    redact_secret(Value0, Secret, Value).

redact_string(Text, none, Text) :-
    !.
redact_string(Text, Secret0, Safe) :-
    secret_string(Secret0, Secret),
    (   Secret == ""
    ->  Safe = Text
    ;   replace_all(Text, Secret, "<redacted>", Safe)
    ).

secret_string(Secret, Secret) :-
    string(Secret),
    !.
secret_string(Secret, Text) :-
    atom(Secret),
    !,
    atom_string(Secret, Text).
secret_string(Secret, Text) :-
    term_string(Secret, Text).

replace_all(Text, Needle, Replacement, Safe) :-
    (   sub_string(Text, Before, Length, After, Needle)
    ->  sub_string(Text, 0, Before, _, Prefix),
        Start is Before+Length,
        sub_string(Text, Start, After, 0, Suffix),
        string_concat(Prefix, Replacement, Left),
        replace_all(Suffix, Needle, Replacement, Right),
        string_concat(Left, Right, Safe)
    ;   Safe = Text
    ).
