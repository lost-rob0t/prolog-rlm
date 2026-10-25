:- begin_tests(rlm_chain).

:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/rlm_openai_compatible',
               [ redact_secret/3,
                 classify_provider_exception/2
               ]).
:- use_module('../prolog/rlm_zai_protocols', []).

test(openrouter_provider_keeps_credential_unresolved) :-
    openrouter_provider('openrouter/free', Provider),
    Provider = provider(openrouter, Config),
    assertion(memberchk(credential(env('OPENROUTER_API_KEY')), Config)),
    assertion(memberchk(address_family(inet), Config)),
    term_string(Provider, Text),
    assertion(\+ sub_string(Text, _, _, _, "Bearer ")).

test(zai_coding_provider_selects_protocol_endpoints_without_resolving_key) :-
    zai_coding_provider(chat_completions, 'glm-5.3', Chat),
    zai_coding_provider(responses, 'glm-5.3', Responses),
    zai_coding_provider(anthropic_messages, 'glm-5.3', Anthropic),
    assertion(Chat == provider(zai_coding,
                               [ endpoint('https://api.z.ai/api/coding/paas/v4/chat/completions'),
                                 credential(env('ZAI_API_KEY')),
                                 model('glm-5.3'),
                                 timeout(30),
                                 address_family(inet)
                               ])),
    assertion(Responses == provider(zai_codex,
                                    [ endpoint('https://api.z.ai/api/v1/responses'),
                                      credential(env('ZAI_API_KEY')),
                                      model('glm-5.3'),
                                      timeout(30),
                                      address_family(inet)
                                    ])),
    assertion(Anthropic == provider(zai_claude,
                                    [ endpoint('https://api.z.ai/api/anthropic/v1/messages'),
                                      credential(env('ZAI_API_KEY')),
                                      model('glm-5.3'),
                                      timeout(30),
                                      address_family(inet),
                                      default_max_tokens(4096)
                                    ])),
    term_string([Chat, Responses, Anthropic], Text),
    assertion(\+ sub_string(Text, _, _, _, "Bearer ")).

test(zai_named_constructors_select_codex_and_claude_protocols) :-
    zai_codex_provider('glm-5.3', Codex),
    zai_claude_provider('glm-5.3-flash', Claude),
    assertion(Codex = provider(zai_codex, _)),
    assertion(Claude = provider(zai_claude, _)).

test(zai_chat_maps_reasoning_controls_and_continuation_content) :-
    Request = model_request{
                  messages:[message{role:assistant, content:"",
                                    reasoning:"prior thought"}],
                  options:generation_options{reasoning:_{effort:max}}
              },
    rlm_openai_compatible:request_payload(zai_coding, Request, 'glm-5.3',
                                          ok(Payload)),
    assertion(Payload.thinking == zai_thinking{type:"enabled"}),
    assertion(Payload.reasoning_effort == max),
    Payload.messages = [Assistant],
    assertion(Assistant.reasoning_content == "prior thought"),
    assertion(\+ get_dict(reasoning, Assistant, _)).

test(zai_chat_normalizes_reasoning_content) :-
    Raw = _{model:"glm-5.3",
            choices:[_{message:_{role:assistant, content:null,
                                  reasoning_content:"thought"},
                       finish_reason:"stop"}]},
    normalize_openai_chat_response(zai_coding, 'glm-5.3', 200, Raw,
                                   ok(Response)),
    assertion(Response.reasoning == "thought"),
    assertion(Response.assistant.reasoning == "thought").

test(zai_chat_rejects_unknown_and_malformed_reasoning_options) :-
    BaseMessages = [message{role:user, content:"hi"}],
    Unknown = model_request{messages:BaseMessages,
                            options:generation_options{bogus:true}},
    rlm_openai_compatible:request_payload(zai_coding, Unknown, 'glm-5.3',
                                          error(UnknownError)),
    assertion(UnknownError.field == bogus),
    Malformed = model_request{messages:BaseMessages,
                              options:generation_options{reasoning:_{}}},
    rlm_openai_compatible:request_payload(zai_coding, Malformed, 'glm-5.3',
                                          error(ReasoningError)),
    assertion(ReasoningError.field == reasoning).

test(responses_payload_maps_tools_and_continuation_items) :-
    Tools = [tool_schema{type:function,
                         function:tool_function{name:"lookup",
                                                description:"Lookup",
                                                parameters:json_schema{type:object}}}],
    Calls = [tool_call{id:"call-1", type:"function",
                       function:tool_function{name:"lookup",
                                              arguments:"{\"q\":\"x\"}"}}],
    Messages = [ message{role:system, content:"Be exact"},
                 message{role:user, content:"Find x"},
                 message{role:assistant, content:"", tool_calls:Calls,
                         reasoning_details:[provider_native{type:"reasoning",
                                                            id:"rs-1"}]},
                 message{role:tool, name:"lookup", tool_call_id:"call-1",
                         content:"{\"value\":1}"}
               ],
    Request = model_request{messages:Messages,
                            options:generation_options{max_tokens:64,
                                                       tools:Tools,
                                                       tool_choice:required}},
    rlm_zai_protocols:responses_request_payload(Request, 'glm-5.3', ok(Payload)),
    assertion(Payload.max_output_tokens == 64),
    assertion(Payload.tool_choice == required),
    assertion(Payload.tools ==
              [responses_tool{type:function, name:"lookup",
                              description:"Lookup",
                              parameters:json_schema{type:object}}]),
    assertion(Payload.input ==
              [ responses_message{role:system, content:"Be exact"},
                responses_message{role:user, content:"Find x"},
                provider_native{type:"reasoning", id:"rs-1"},
                responses_call{type:"function_call", call_id:"call-1",
                               name:"lookup", arguments:"{\"q\":\"x\"}"},
                responses_output{type:"function_call_output", call_id:"call-1",
                                 output:"{\"value\":1}"}
              ]).

test(anthropic_payload_maps_system_tools_and_continuation_blocks) :-
    Tools = [tool_schema{type:function,
                         function:tool_function{name:"lookup",
                                                description:"Lookup",
                                                parameters:json_schema{type:object}}}],
    Calls = [tool_call{id:"call-1", type:"function",
                       function:tool_function{name:"lookup",
                                              arguments:"{\"q\":\"x\"}"}}],
    Messages = [ message{role:system, content:"Be exact"},
                 message{role:user, content:"Find x"},
                 message{role:assistant, content:"Checking", tool_calls:Calls,
                         reasoning_details:[provider_native{type:"thinking",
                                                            thinking:"...",
                                                            signature:"sig"}]},
                 message{role:tool, tool_call_id:"call-1",
                         content:"{\"value\":1}"}
               ],
    Request = model_request{messages:Messages,
                            options:generation_options{max_completion_tokens:64,
                                                       tools:Tools,
                                                       tool_choice:required}},
    rlm_zai_protocols:anthropic_request_payload(Request, 'glm-5.3', 4096,
                                                ok(Payload)),
    assertion(Payload.system == [anthropic_block{type:"text", text:"Be exact"}]),
    assertion(Payload.max_tokens == 64),
    assertion(Payload.tool_choice == anthropic_tool_choice{type:"any"}),
    assertion(Payload.tools ==
              [anthropic_tool{name:"lookup", description:"Lookup",
                              input_schema:json_schema{type:object}}]),
    assertion(Payload.messages ==
              [ anthropic_message{role:user, content:"Find x"},
                anthropic_message{role:assistant,
                                  content:[ provider_native{type:"thinking", thinking:"...",
                                                            signature:"sig"},
                                            anthropic_block{type:"text", text:"Checking"},
                                            anthropic_block{type:"tool_use", id:"call-1",
                                                            name:"lookup",
                                                            input:provider_json{q:"x"}}
                                          ]},
                anthropic_message{role:user,
                                  content:[anthropic_block{type:"tool_result",
                                                           tool_use_id:"call-1",
                                                           content:"{\"value\":1}"}]}
              ]).

test(responses_response_normalizes_text_calls_usage_and_reasoning_items) :-
    Raw = _{id:"resp-1", model:"glm-5.3", status:"completed",
            output:[ _{type:"reasoning", id:"rs-1", summary:[]},
                     _{type:"message", role:"assistant",
                       content:[_{type:"output_text", text:"Found"}]},
                     _{type:"function_call", call_id:"call-1",
                       name:"lookup", arguments:"{\"q\":\"x\"}"}
                   ],
            usage:_{input_tokens:10, output_tokens:5, total_tokens:15}},
    normalize_openai_responses_response(zai_codex, 'glm-5.3', 200, Raw,
                                        ok(Response)),
    assertion(Response.text == "Found"),
    assertion(Response.reasoning_details ==
              [provider_native_sequence{
                   type:provider_native_sequence,
                   protocol:responses,
                   items:[ provider_native{type:"reasoning", id:"rs-1", summary:[]},
                           provider_native{type:"message", role:"assistant",
                                           content:[provider_native{type:"output_text",
                                                                    text:"Found"}]},
                           provider_native{type:"function_call", call_id:"call-1",
                                           name:"lookup",
                                           arguments:"{\"q\":\"x\"}"}
                         ]}]),
    assertion(Response.tool_calls ==
              [tool_call{id:"call-1", type:"function",
                         function:tool_function{name:"lookup",
                                                arguments:"{\"q\":\"x\"}"}}]),
    assertion(Response.finish_reason == "completed"),
    assertion(Response.usage.prompt_tokens == 10),
    assertion(Response.usage.completion_tokens == 5).

test(anthropic_response_normalizes_text_calls_usage_and_thinking_blocks) :-
    Raw = _{id:"msg-1", model:"glm-5.3", role:"assistant",
            content:[ _{type:"thinking", thinking:"...", signature:"sig"},
                      _{type:"text", text:"Found"},
                      _{type:"tool_use", id:"call-1", name:"lookup",
                        input:_{q:"x"}}
                    ],
            stop_reason:"tool_use",
            usage:_{input_tokens:10, output_tokens:5}},
    normalize_anthropic_messages_response(zai_claude, 'glm-5.3', 200, Raw,
                                          ok(Response)),
    assertion(Response.text == "Found"),
    assertion(Response.reasoning_details ==
              [provider_native_sequence{
                   type:provider_native_sequence,
                   protocol:anthropic_messages,
                   items:[ provider_native{type:"thinking", thinking:"...",
                                           signature:"sig"},
                           provider_native{type:"text", text:"Found"},
                           provider_native{type:"tool_use", id:"call-1",
                                           name:"lookup",
                                           input:provider_native{q:"x"}}
                         ]}]),
    Response.tool_calls = [Call],
    assertion(Call.id == "call-1"),
    assertion(Call.function.name == "lookup"),
    atom_string(Arguments, Call.function.arguments),
    atom_json_dict(Arguments, Input, []),
    assertion(get_dict(q, Input, "x")),
    assertion(Response.finish_reason == "tool_use"),
    assertion(Response.usage.total_tokens == 15).

test(anthropic_native_sequence_replays_in_original_order) :-
    Native = [ _{type:"thinking", thinking:"first", signature:"a"},
               _{type:"tool_use", id:"call-1", name:"lookup", input:_{q:1}},
               _{type:"redacted_thinking", data:"opaque"}
             ],
    Raw = _{id:"msg-1", model:"glm-5.3", role:"assistant",
            content:Native, stop_reason:"tool_use",
            usage:_{input_tokens:1, output_tokens:1}},
    normalize_anthropic_messages_response(zai_claude, 'glm-5.3', 200, Raw,
                                          ok(Response)),
    Messages = [ message{role:user, content:"lookup"},
                 Response.assistant,
                 message{role:tool, tool_call_id:"call-1", content:"done"}
               ],
    messages_normalize(Messages, ok(NormalizedMessages)),
    rlm_zai_protocols:anthropic_request_payload(
        model_request{messages:NormalizedMessages}, 'glm-5.3', 4096,
        ok(Payload)),
    Payload.messages = [_, Replayed, _],
    assertion(Replayed.content ==
              [ provider_native{type:"thinking", thinking:"first", signature:"a"},
                provider_native{type:"tool_use", id:"call-1", name:"lookup",
                                input:provider_native{q:1}},
                provider_native{type:"redacted_thinking", data:"opaque"}
              ]).

test(protocol_adapters_reject_unknown_options_and_orphan_results) :-
    Unknown = model_request{messages:[message{role:user, content:"hi"}],
                            options:generation_options{bogus:true}},
    rlm_zai_protocols:responses_request_payload(Unknown, 'glm-5.3',
                                                error(UnknownError)),
    assertion(UnknownError.kind == validation_error),
    assertion(UnknownError.field == bogus),
    Orphan = model_request{messages:[message{role:tool,
                                             tool_call_id:"missing",
                                             content:"result"}]},
    rlm_zai_protocols:anthropic_request_payload(Orphan, 'glm-5.3', 4096,
                                                error(OrphanError)),
    assertion(OrphanError.kind == validation_error),
    assertion(OrphanError.field == messages).

test(protocol_adapters_reject_non_ground_requests) :-
    Request = model_request{messages:[message{role:user, content:_Content}]},
    rlm_zai_protocols:responses_request_payload(Request, 'glm-5.3',
                                                error(Error)),
    assertion(Error.kind == validation_error),
    assertion(Error.field == request).

test(malformed_provider_tool_calls_fail_closed) :-
    ResponsesRaw = _{id:"resp-1", model:"glm-5.3", status:"completed",
                     output:[_{type:"message", role:"assistant",
                               content:[_{type:"output_text", text:"text"}]},
                              _{type:"function_call", name:"lookup",
                                arguments:"{}"}]},
    normalize_openai_responses_response(zai_codex, 'glm-5.3', 200,
                                        ResponsesRaw, error(ResponsesError)),
    assertion(ResponsesError.kind == invalid_response),
    AnthropicRaw = _{id:"msg-1", model:"glm-5.3", role:"assistant",
                     content:[_{type:"text", text:"text"},
                              _{type:"tool_use", id:"call-1",
                                name:"lookup", input:"not-an-object"}],
                     stop_reason:"tool_use"},
    normalize_anthropic_messages_response(zai_claude, 'glm-5.3', 200,
                                          AnthropicRaw,
                                          error(AnthropicError)),
    assertion(AnthropicError.kind == invalid_response).

test(empty_protocol_successes_fail_closed) :-
    normalize_openai_responses_response(
        zai_codex, 'glm-5.3', 200,
        _{id:"resp-1", status:"completed", output:[]},
        error(ResponsesError)),
    assertion(ResponsesError.kind == invalid_response),
    normalize_anthropic_messages_response(
        zai_claude, 'glm-5.3', 200,
        _{id:"msg-1", role:"assistant", content:[], stop_reason:"end_turn"},
        error(AnthropicError)),
    assertion(AnthropicError.kind == invalid_response).

test(tool_history_rejects_intervening_turn_and_native_mismatch) :-
    Calls = [tool_call{id:"call-1", type:"function",
                       function:tool_function{name:"lookup", arguments:"{}"}}],
    Intervening = model_request{
                      messages:[ message{role:user, content:"lookup"},
                                 message{role:assistant, content:"", tool_calls:Calls},
                                 message{role:user, content:"not a result"},
                                 message{role:tool, tool_call_id:"call-1",
                                         content:"done"}
                               ]
                  },
    rlm_zai_protocols:responses_request_payload(
        Intervening, 'glm-5.3', error(InterveningError)),
    assertion(InterveningError.kind == validation_error),
    MismatchedSequence = provider_native_sequence{
                             type:provider_native_sequence,
                             protocol:responses,
                             items:[provider_native{type:"function_call",
                                                    call_id:"evil",
                                                    name:"lookup",
                                                    arguments:"{}"}]},
    Mismatch = model_request{
                   messages:[ message{role:user, content:"lookup"},
                              message{role:assistant, content:"", tool_calls:Calls,
                                      reasoning_details:[MismatchedSequence]},
                              message{role:tool, tool_call_id:"call-1",
                                      content:"done"}
                            ]
               },
    rlm_zai_protocols:responses_request_payload(
        Mismatch, 'glm-5.3', error(MismatchError)),
    assertion(MismatchError.kind == validation_error),
    assertion(MismatchError.field == reasoning_details).

test(malformed_messages_and_wire_identifiers_return_structured_errors) :-
    forall(member(Message, [_{content:"missing role"}, not_a_dict]),
           ( Request = model_request{messages:[Message]},
             rlm_zai_protocols:responses_request_payload(
                 Request, 'glm-5.3', error(Error)),
             assertion(ground(Error)),
             assertion(Error.kind == validation_error),
             assertion(Error.field == messages)
           )),
    BadCall = tool_call{id:7, type:"function",
                        function:tool_function{name:"lookup", arguments:"{}"}},
    Request = model_request{
                  messages:[ message{role:user, content:"lookup"},
                             message{role:assistant, content:"",
                                     tool_calls:[BadCall]},
                             message{role:tool, tool_call_id:"7",
                                     content:"done"}
                           ]
              },
    rlm_zai_protocols:anthropic_request_payload(
        Request, 'glm-5.3', 4096, error(CallError)),
    assertion(CallError.kind == validation_error),
    assertion(CallError.field == tool_calls).

test(zai_codex_and_claude_streaming_fail_explicitly) :-
    Request = model_request{messages:[message{role:user, content:"ping"}]},
    forall(member(Name, [zai_codex, zai_claude]),
           ( model_stream_execute(provider(Name, []), Request,
                                  ignore_stream_event, error(Error)),
             assertion(Error.kind == capability_denied),
             assertion(Error.capability == streaming)
           )).

test(address_family_is_applied_to_completion_and_stream_connections) :-
    rlm_openai_compatible:http_options(none,
                                       30,
                                       inet,
                                       'prolog-rlm/0.1',
                                       _,
                                       [],
                                       CompletionOptions),
    assertion(memberchk(domain(inet), CompletionOptions)),
    rlm_openai_compatible:stream_http_options(none,
                                              30,
                                              inet6,
                                              'prolog-rlm/0.1',
                                              _,
                                              _{},
                                              [],
                                              StreamOptions),
    assertion(memberchk(domain(inet6), StreamOptions)).

test(automatic_address_family_leaves_socket_selection_unconstrained) :-
    rlm_openai_compatible:http_options(none,
                                       30,
                                       auto,
                                       'prolog-rlm/0.1',
                                       _,
                                       [],
                                       Options),
    assertion(\+ memberchk(domain(_), Options)).

test(invalid_address_family_fails_before_network) :-
    Provider = provider(openai_compatible,
                        [ endpoint('https://invalid.invalid/chat/completions'),
                          credential(none),
                          model(test),
                          timeout(1),
                          address_family(ipx)
                        ]),
    Request = model_request{
                  messages:[message{role:user, content:"ping"}]
              },
    model_complete(Provider, Request, error(Error)),
    assertion(get_dict(kind, Error, configuration_error)),
    assertion(get_dict(field, Error, address_family)),
    assertion(get_dict(response_received, Error, false)).

test(auto_only_provider_normalizes_required_tool_choice_before_payload) :-
    Tools = [tool_schema{type:function,
                         function:tool_function{name:"lookup",
                                                parameters:json_schema{type:object}}}],
    Request0 = model_request{
                   messages:[message{role:user, content:"lookup"}],
                   options:generation_options{tools:Tools,
                                              tool_choice:required}
               },
    Config = [tool_choice_modes([auto])],
    rlm_chain:normalize_provider_request(openrouter,
                                         Config,
                                         Request0,
                                         ok(Request)),
    rlm_openai_compatible:request_payload(Request,
                                          'vendor/model',
                                          ok(Payload)),
    get_dict(tool_choice, Payload, Effective),
    get_dict(tools, Payload, OutboundTools),
    assertion(Effective == auto),
    assertion(OutboundTools == Tools).

test(provider_profile_supporting_required_preserves_required) :-
    Request0 = model_request{
                   messages:[message{role:user, content:"lookup"}],
                   options:generation_options{tool_choice:required}
               },
    Config = [tool_choice_modes([auto, required])],
    rlm_chain:normalize_provider_request(openrouter,
                                         Config,
                                         Request0,
                                         ok(Request)),
    get_dict(options, Request, Options),
    get_dict(tool_choice, Options, Effective),
    assertion(Effective == required).

test(provider_without_tool_choice_profile_preserves_current_behavior) :-
    Request = model_request{
                  messages:[message{role:user, content:"lookup"}],
                  options:generation_options{tool_choice:required}
              },
    rlm_chain:normalize_provider_request(openrouter,
                                         [],
                                         Request,
                                         ok(Normalized)),
    assertion(Normalized == Request).

test(malformed_tool_choice_profile_fails_before_dispatch) :-
    Request = model_request{
                  messages:[message{role:user, content:"lookup"}],
                  options:generation_options{tool_choice:required}
              },
    Config = [credential(env('MUST_NOT_BE_RESOLVED')),
              tool_choice_modes([auto, banana])],
    rlm_chain:normalize_provider_request(openrouter,
                                         Config,
                                         Request,
                                         error(Error)),
    assertion(get_dict(kind, Error, configuration_error)),
    assertion(get_dict(field, Error, tool_choice_modes)),
    assertion(get_dict(response_received, Error, false)),
    term_string(Error, ErrorText),
    assertion(\+ sub_string(ErrorText, _, _, _, "MUST_NOT_BE_RESOLVED")).

test(bare_tool_choice_profile_atom_is_rejected) :-
    Request = model_request{
                  messages:[message{role:user, content:"lookup"}],
                  options:generation_options{tool_choice:required}
              },
    rlm_chain:normalize_provider_request(openrouter,
                                         [tool_choice_modes],
                                         Request,
                                         error(Error)),
    assertion(get_dict(kind, Error, configuration_error)),
    assertion(get_dict(field, Error, tool_choice_modes)),
    assertion(get_dict(response_received, Error, false)).

test(stream_dispatch_uses_same_compatibility_normalization) :-
    Provider = provider(openrouter,
                        [ tool_choice_modes([auto, banana]),
                          credential(env('MUST_NOT_BE_RESOLVED'))
                        ]),
    Request = model_request{
                  messages:[message{role:user, content:"lookup"}],
                  options:generation_options{tool_choice:required}
              },
    rlm_chain:model_stream_execute(Provider,
                                   Request,
                                   ignore_stream_event,
                                   error(Error)),
    assertion(get_dict(kind, Error, configuration_error)),
    assertion(get_dict(field, Error, tool_choice_modes)),
    assertion(get_dict(response_received, Error, false)).

test(auto_only_profile_does_not_silently_weaken_specific_tool_choice) :-
    Specific = tool_choice{type:function,
                           function:tool_function{name:"lookup"}},
    Request = model_request{
                  messages:[message{role:user, content:"lookup"}],
                  options:generation_options{tool_choice:Specific}
              },
    rlm_chain:normalize_provider_request(openrouter,
                                         [tool_choice_modes([auto])],
                                         Request,
                                         error(Error)),
    assertion(get_dict(kind, Error, capability_denied)),
    assertion(get_dict(capability, Error, tool_choice)),
    assertion(get_dict(response_received, Error, false)).

test(provider_capabilities_are_explicit) :-
    assertion(provider_capability(openrouter, chat_completions)),
    assertion(provider_capability(openrouter, usage_metadata)),
    assertion(provider_capability(openrouter, tool_calls)),
    assertion(provider_capability(zai_coding, chat_completions)),
    assertion(provider_capability(zai_codex, responses)),
    assertion(provider_capability(zai_codex, tool_calls)),
    assertion(provider_capability(zai_claude, messages)),
    assertion(provider_capability(zai_claude, tool_calls)),
    assertion(\+ provider_capability(zai_codex, streaming)),
    assertion(\+ provider_capability(zai_claude, streaming)).

test(normalizes_successful_text_response_and_usage) :-
    Raw = _{id:"gen-test",
            model:"test/selected-model",
            choices:[_{message:_{role:assistant,
                                 content:"PROLOG_RLM_OPENROUTER_OK"},
                       finish_reason:"stop"}],
            usage:_{prompt_tokens:5,
                    completion_tokens:7,
                    total_tokens:12,
                    cost:0.0}},
    normalize_openai_chat_response(openrouter,
                                   'openrouter/free',
                                   200,
                                   Raw,
                                   ok(Response)),
    assertion(get_dict(provider, Response, openrouter)),
    assertion(get_dict(requested_model, Response, 'openrouter/free')),
    assertion(get_dict(selected_model, Response, "test/selected-model")),
    assertion(get_dict(text, Response, "PROLOG_RLM_OPENROUTER_OK")),
    assertion(get_dict(reasoning, Response, "")),
    assertion(get_dict(reasoning_details, Response, [])),
    assertion(get_dict(finish_reason, Response, "stop")),
    get_dict(metadata, Response, Metadata),
    assertion(get_dict(http_status, Metadata, 200)),
    assertion(get_dict(response_received, Metadata, true)),
    get_dict(usage, Response, Usage),
    assertion(get_dict(present, Usage, true)),
    assertion(get_dict(prompt_tokens, Usage, 5)),
    assertion(get_dict(completion_tokens, Usage, 7)),
    assertion(get_dict(total_tokens, Usage, 12)).

test(normalizes_tool_call_without_text) :-
    Calls = [_{id:"call-1",
               type:"function",
               function:_{name:"lookup", arguments:"{}"}}],
    Raw = _{model:"test/tool-model",
            choices:[_{message:_{role:assistant,
                                 content:null,
                                 tool_calls:Calls},
                       finish_reason:"tool_calls"}]},
    normalize_openai_chat_response(openrouter,
                                   'openrouter/free',
                                   200,
                                   Raw,
                                   ok(Response)),
    assertion(get_dict(text, Response, "")),
    assertion(get_dict(tool_calls, Response, Calls)),
    assertion(get_dict(reasoning, Response, "")),
    get_dict(usage, Response, Usage),
    assertion(get_dict(present, Usage, false)).

test(normalizes_reasoning_only_success_response) :-
    Raw = _{model:"test/reasoning-model",
            choices:[_{message:_{role:assistant,
                                 content:null,
                                 reasoning:"short internal result",
                                 reasoning_details:[]},
                       finish_reason:"length"}]},
    normalize_openai_chat_response(openrouter,
                                   'openrouter/free',
                                   200,
                                   Raw,
                                   ok(Response)),
    assertion(get_dict(text, Response, "")),
    assertion(get_dict(tool_calls, Response, [])),
    assertion(get_dict(reasoning, Response, "short internal result")),
    assertion(get_dict(reasoning_details, Response, [])),
    assertion(get_dict(finish_reason, Response, "length")),
    get_dict(assistant, Response, Assistant),
    assertion(get_dict(reasoning, Assistant, "short internal result")).

test(normalizes_reasoning_details_only_success_response) :-
    Details = [_{type:"reasoning.text", text:"reasoning fragment"}],
    Raw = _{model:"test/reasoning-model",
            choices:[_{message:_{role:assistant,
                                 content:null,
                                 reasoning:null,
                                 reasoning_details:Details},
                       finish_reason:"length"}]},
    normalize_openai_chat_response(openrouter,
                                   'openrouter/free',
                                   200,
                                   Raw,
                                   ok(Response)),
    assertion(get_dict(text, Response, "")),
    assertion(get_dict(reasoning, Response, "")),
    assertion(get_dict(reasoning_details, Response, Details)).

test(rejects_truly_empty_success_response) :-
    Raw = _{model:"test/model",
            choices:[_{message:_{role:assistant,
                                 content:null,
                                 reasoning:null,
                                 reasoning_details:[],
                                 tool_calls:[]},
                       finish_reason:"stop"}]},
    normalize_openai_chat_response(openrouter,
                                   'openrouter/free',
                                   200,
                                   Raw,
                                   error(Error)),
    assertion(get_dict(kind, Error, invalid_response)),
    assertion(get_dict(response_received, Error, true)).

test(normalizes_http_provider_error) :-
    Raw = _{error:_{code:401,
                    message:"invalid credentials",
                    metadata:_{error_type:"authentication"}}},
    normalize_openai_chat_response(openrouter,
                                   'openrouter/free',
                                   401,
                                   Raw,
                                   error(Error)),
    assertion(get_dict(kind, Error, provider_error)),
    assertion(get_dict(http_status, Error, 401)),
    assertion(get_dict(code, Error, 401)),
    assertion(get_dict(error_type, Error, "authentication")),
    assertion(get_dict(response_received, Error, true)).

test(missing_env_credential_fails_before_network) :-
    Missing = '__PROLOG_RLM_TEST_KEY_THAT_MUST_NOT_EXIST__',
    Provider = provider(openrouter,
                        [ endpoint('https://invalid.invalid/chat/completions'),
                          credential(env(Missing)),
                          model('openrouter/free'),
                          timeout(1)
                        ]),
    Request = model_request{messages:[message{role:user, content:"ping"}]},
    model_complete(Provider, Request, error(Error)),
    assertion(get_dict(kind, Error, missing_credential)),
    assertion(get_dict(credential, Error, env(Missing))),
    assertion(get_dict(response_received, Error, false)).

test(malformed_request_fails_before_network) :-
    Provider = provider(openai_compatible,
                        [ endpoint('https://invalid.invalid/chat/completions'),
                          credential(none),
                          model(test),
                          timeout(1)
                        ]),
    Request = model_request{messages:[]},
    model_complete(Provider, Request, error(Error)),
    assertion(get_dict(kind, Error, validation_error)),
    assertion(get_dict(field, Error, messages)).

test(unknown_provider_is_capability_denied) :-
    Provider = provider(unknown_provider, []),
    model_complete(Provider, model_request{messages:[]}, error(Error)),
    assertion(get_dict(kind, Error, capability_denied)),
    assertion(get_dict(capability, Error, chat_completions)).

test(timeout_exception_is_structured) :-
    Exception = error(timeout_error(read, stream), context(test, timeout)),
    classify_provider_exception(Exception, Kind),
    assertion(Kind == timeout).

test(non_timeout_exception_is_transport_error) :-
    Exception = error(socket_error(econnreset), context(test, reset)),
    classify_provider_exception(Exception, Kind),
    assertion(Kind == transport_error).

test(secret_redaction_removes_all_occurrences) :-
    Secret = 'unit-secret-do-not-log',
    Unsafe = error(socket_error("unit-secret-do-not-log"),
                   context("Bearer unit-secret-do-not-log", test)),
    redact_secret(Unsafe, Secret, Safe),
    term_string(Safe, SafeText),
    assertion(\+ sub_string(SafeText, _, _, _, "unit-secret-do-not-log")),
    assertion(sub_string(SafeText, _, _, _, "<redacted>")).

test(provider_context_prepends_host_messages_once) :-
    Prefix = [message{role:system, content:"RLM_OPERATE_BODY"}],
    Request0 = model_request{
                   messages:[message{role:user, content:"leaf prompt"}],
                   options:_{max_tokens:32}
               },
    rlm_chain:provider_context_request(Prefix, Request0, Request),
    assertion(Request.messages ==
              [ message{role:system, content:"RLM_OPERATE_BODY"},
                message{role:user, content:"leaf prompt"}
              ]),
    assertion(Request.options == Request0.options).

test(provider_context_empty_prefix_preserves_request) :-
    Request = model_request{
                  messages:[message{role:user, content:"raw leaf"}],
                  options:_{}
              },
    rlm_chain:provider_context_request([], Request, Projected),
    assertion(Projected == Request).

ignore_stream_event(_).

:- end_tests(rlm_chain).
