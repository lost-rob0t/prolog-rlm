:- begin_tests(rlm_chain).

:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/rlm_openai_compatible').

test(openrouter_provider_keeps_credential_unresolved) :-
    openrouter_provider('openrouter/free', Provider),
    assertion(Provider = provider(openrouter, Config)),
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
    assertion(Response.provider == openrouter),
    assertion(Response.requested_model == 'openrouter/free'),
    assertion(Response.selected_model == "test/selected-model"),
    assertion(Response.text == "PROLOG_RLM_OPENROUTER_OK"),
    assertion(Response.finish_reason == "stop"),
    assertion(Response.metadata.http_status =:= 200),
    assertion(Response.metadata.response_received == true),
    assertion(Response.usage.present == true),
    assertion(Response.usage.prompt_tokens =:= 5),
    assertion(Response.usage.completion_tokens =:= 7),
    assertion(Response.usage.total_tokens =:= 12).

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
    assertion(Response.text == ""),
    assertion(Response.tool_calls == Calls),
    assertion(Response.usage.present == false).

test(rejects_empty_success_response) :-
    Raw = _{model:"test/model",
            choices:[_{message:_{role:assistant, content:null},
                       finish_reason:"stop"}]},
    normalize_openai_chat_response(openrouter,
                                   'openrouter/free',
                                   200,
                                   Raw,
                                   error(Error)),
    assertion(Error.kind == invalid_response),
    assertion(Error.response_received == true).

test(normalizes_http_provider_error) :-
    Raw = _{error:_{code:401,
                    message:"invalid credentials",
                    metadata:_{error_type:"authentication"}}},
    normalize_openai_chat_response(openrouter,
                                   'openrouter/free',
                                   401,
                                   Raw,
                                   error(Error)),
    assertion(Error.kind == provider_error),
    assertion(Error.http_status =:= 401),
    assertion(Error.code =:= 401),
    assertion(Error.error_type == "authentication"),
    assertion(Error.response_received == true).

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
    assertion(Error.kind == missing_credential),
    assertion(Error.credential == env(Missing)),
    assertion(Error.response_received == false).

test(malformed_request_fails_before_network) :-
    Provider = provider(openai_compatible,
                        [ endpoint('https://invalid.invalid/chat/completions'),
                          credential(none),
                          model(test),
                          timeout(1)
                        ]),
    Request = model_request{messages:[]},
    model_complete(Provider, Request, error(Error)),
    assertion(Error.kind == validation_error),
    assertion(Error.field == messages).

test(unknown_provider_is_capability_denied) :-
    Provider = provider(unknown_provider, []),
    model_complete(Provider, model_request{messages:[]}, error(Error)),
    assertion(Error.kind == capability_denied),
    assertion(Error.capability == chat_completions).

test(timeout_exception_is_structured) :-
    classify_provider_exception(error(timeout_error(read, stream), context(test, timeout)),
                                Kind),
    assertion(Kind == timeout).

test(non_timeout_exception_is_transport_error) :-
    classify_provider_exception(error(socket_error(econnreset), context(test, reset)),
                                Kind),
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
