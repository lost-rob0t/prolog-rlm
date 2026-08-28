:- begin_tests(rlm_chain).

:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/rlm_openai_compatible',
              [ redact_secret/3,
                classify_provider_exception/2
              ]).

test(openrouter_provider_keeps_credential_unresolved) :-
    openrouter_provider('openrouter/free', Provider),
    Provider = provider(openrouter, Config),
    assertion(memberchk(credential(env('OPENROUTER_API_KEY')), Config)),
    assertion(memberchk(address_family(inet), Config)),
    term_string(Provider, Text),
    assertion(\+ sub_string(Text, _, _, _, "Bearer ")).

test(address_family_is_applied_to_completion_and_stream_connections) :-
    rlm_openai_compatible:http_options(none,
                                       30,
                                       inet,
                                       _,
                                       [],
                                       CompletionOptions),
    assertion(memberchk(domain(inet), CompletionOptions)),
    rlm_openai_compatible:stream_http_options(none,
                                              30,
                                              inet6,
                                              _,
                                              _{},
                                              [],
                                              StreamOptions),
    assertion(memberchk(domain(inet6), StreamOptions)).

test(automatic_address_family_leaves_socket_selection_unconstrained) :-
    rlm_openai_compatible:http_options(none,
                                       30,
                                       auto,
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
    assertion(provider_capability(openrouter, tool_calls)).

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
