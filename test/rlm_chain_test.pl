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
    term_string(Provider, Text),
    assertion(\+ sub_string(Text, _, _, _, "Bearer ")).

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

:- end_tests(rlm_chain).
