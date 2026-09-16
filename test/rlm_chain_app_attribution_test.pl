:- begin_tests(rlm_chain_app_attribution).

:- use_module('../prolog/rlm_chain').
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(http/thread_httpd)).

:- dynamic captured_attribution/1.
:- dynamic captured_zai_request/2.

:- http_handler(root(attribution), attribution_handler, [method(post)]).
:- http_handler(root(zai_responses), zai_responses_handler, [method(post)]).
:- http_handler(root(zai_anthropic), zai_anthropic_handler, [method(post)]).

test(openrouter_provider_defaults_identify_the_app) :-
    rlm_chain:openrouter_provider('test/model', Provider),
    Provider = provider(openrouter, Config),
    memberchk(app_title('prolog-rlm'), Config),
    memberchk(app_referer('https://github.com/lost-rob0t/prolog-rlm'),
              Config).

test(downstream_provider_terms_override_attribution_headers) :-
    with_attribution_server(
        run_completion(_Port,
                       [ app_title('agentProlog'),
                         app_referer('https://example.com/app')
                       ]),
        Headers),
    memberchk('X-OpenRouter-Title'('agentProlog'), Headers),
    memberchk('HTTP-Referer'('https://example.com/app'), Headers).

test(downstream_provider_terms_override_user_agent) :-
    with_attribution_server(
        run_completion(_Port, [user_agent('agentProlog/1.0')]),
        Headers),
    memberchk('User-Agent'('agentProlog/1.0'), Headers).

test(default_user_agent_is_preserved) :-
    with_attribution_server(run_completion(_Port, []), Headers),
    memberchk('User-Agent'('prolog-rlm/0.1'), Headers).

test(openrouter_request_carries_default_attribution_headers) :-
    with_attribution_server(
        run_completion(_Port,
                       [ app_title('prolog-rlm'),
                         app_referer('https://github.com/lost-rob0t/prolog-rlm')
                       ]),
        Headers),
    memberchk('X-OpenRouter-Title'('prolog-rlm'), Headers),
    memberchk('HTTP-Referer'('https://github.com/lost-rob0t/prolog-rlm'),
              Headers).

test(unattributed_custom_endpoint_sends_no_attribution_headers) :-
    with_attribution_server(run_completion(_Port, []), Headers),
    (   memberchk('X-OpenRouter-Title'(_), Headers)
    ;   memberchk('HTTP-Referer'(_), Headers)
    ),
    !,
    assertion(fail)
    ;   true.

test(invalid_app_title_fails_configuration) :-
    Provider = provider(openai_compatible,
                        [ endpoint('https://example.invalid/v1/chat/completions'),
                          credential(none),
                          model('test/model'),
                          app_title(42)
                        ]),
    rlm_chain:model_complete_execute(
        Provider,
        model_request{messages:[message{role:user, content:"hi"}],
                      options:_{}},
        error(Error)),
    assertion(Error.kind == configuration_error),
    assertion(Error.field == app_title).

test(invalid_user_agent_fails_configuration) :-
    Provider = provider(openai_compatible,
                        [ endpoint('https://example.invalid/v1/chat/completions'),
                          credential(none),
                          model('test/model'),
                          user_agent("")
                        ]),
    rlm_chain:model_complete_execute(
        Provider,
        model_request{messages:[message{role:user, content:"hi"}],
                      options:_{}},
        error(Error)),
    assertion(Error.kind == configuration_error),
    assertion(Error.field == user_agent).

test(zai_rejects_unsafe_user_agent_before_network_io) :-
    Provider = provider(zai_codex,
                        [ endpoint('https://example.invalid/v1/responses'),
                          credential(none),
                          model('glm-5.3'),
                          user_agent("agent\r\nX-Injected: true")
                        ]),
    rlm_chain:model_complete_execute(
        Provider,
        model_request{messages:[message{role:user, content:"hi"}],
                      options:generation_options{}},
        error(Error)),
    assertion(Error.kind == configuration_error),
    assertion(Error.field == user_agent).

test(zai_responses_dispatches_and_normalizes_over_http) :-
    with_zai_server(run_zai_completion(zai_codex, zai_responses, _Port),
                    zai_responses, Request-Payload),
    assertion(memberchk(path('/zai_responses'), Request)),
    assertion(Payload.model == "glm-5.3"),
    Payload.input = [Input],
    assertion(Input.role == "user"),
    assertion(Input.content == "Reply").

test(zai_responses_uses_configured_user_agent) :-
    with_zai_server(
        run_zai_completion(zai_codex, zai_responses,
                           [user_agent('agentProlog/1.0')], _Port),
        zai_responses, Request-_),
    assertion(request_header_value(Request, user_agent, 'agentProlog/1.0')).

test(zai_anthropic_dispatches_required_version_header_over_http) :-
    with_zai_server(run_zai_completion(zai_claude, zai_anthropic, _Port),
                    zai_anthropic, Request-Payload),
    assertion(memberchk(path('/zai_anthropic'), Request)),
    assertion(request_header_value(Request, anthropic_version,
                                   '2023-06-01')),
    assertion(Payload.model == "glm-5.3"),
    assertion(Payload.max_tokens == 4096),
    Payload.messages = [Message],
    assertion(Message.role == "user"),
    assertion(Message.content == "Reply").

test(claude_api_uses_x_api_key_and_preserves_provider_identity) :-
    with_zai_server(run_claude_api_completion,
                    zai_anthropic, Request-Payload),
    assertion(request_header_value(Request, x_api_key,
                                   'fixture-claude-api-key')),
    assertion(\+ request_header_value(Request, authorization, _)),
    assertion(request_header_value(Request, anthropic_version,
                                   '2023-06-01')),
    assertion(Payload.model == "claude-test"),
    assertion(Payload.max_tokens == 4096).

test(zai_anthropic_retains_bearer_auth) :-
    with_zai_server(run_zai_bearer_completion,
                    zai_anthropic, Request-_),
    request_header_value(Request, authorization, Authorization),
    assertion(memberchk(Authorization,
                        [bearer('fixture-zai-key'),
                         'Bearer fixture-zai-key'])),
    assertion(\+ request_header_value(Request, x_api_key, _)).

run_zai_bearer_completion(Port) :-
    format(atom(Endpoint), 'http://127.0.0.1:~d/zai_anthropic', [Port]),
    Provider = provider(zai_claude,
                        [ endpoint(Endpoint),
                          credential(env('ZAI_TEST_API_KEY')),
                          model('glm-5.3'),
                          default_max_tokens(4096)
                        ]),
    setup_call_cleanup(
        ( getenv('ZAI_TEST_API_KEY', Old) -> HadKey = true ; HadKey = false ),
        ( setenv('ZAI_TEST_API_KEY', 'fixture-zai-key'),
          rlm_chain:model_complete_execute(
              Provider,
              model_request{messages:[message{role:user, content:"Reply"}],
                            options:generation_options{}},
              ok(_))
        ),
        ( HadKey == true -> setenv('ZAI_TEST_API_KEY', Old)
        ; unsetenv('ZAI_TEST_API_KEY') )).

run_claude_api_completion(Port) :-
    format(atom(Endpoint), 'http://127.0.0.1:~d/zai_anthropic', [Port]),
    Provider = provider(claude_api,
                        [ endpoint(Endpoint),
                          credential(env('CLAUDE_TEST_API_KEY')),
                          model('claude-test'),
                          default_max_tokens(4096)
                        ]),
    setup_call_cleanup(
        ( getenv('CLAUDE_TEST_API_KEY', Old) -> HadKey = true ; HadKey = false ),
        ( setenv('CLAUDE_TEST_API_KEY', 'fixture-claude-api-key'),
          rlm_chain:model_complete_execute(
              Provider,
              model_request{messages:[message{role:user, content:"Reply"}],
                            options:generation_options{}},
              ok(Response)),
          assertion(Response.provider == claude_api),
          assertion(Response.text == "ok"),
          term_string(Response, Text),
          assertion(\+ sub_string(Text, _, _, _, "fixture-claude-api-key"))
        ),
        ( HadKey == true -> setenv('CLAUDE_TEST_API_KEY', Old)
        ; unsetenv('CLAUDE_TEST_API_KEY') )).

with_attribution_server(Goal, Headers) :-
    retractall(captured_attribution(_)),
    setup_call_cleanup(
        http_server(http_dispatch, [port(Port)]),
        call(Goal, Port),
        http_stop_server(Port, [])),
    captured_attribution(Headers).

run_completion(Port, ExtraConfig, Port) :-
    format(atom(Endpoint), 'http://127.0.0.1:~d/attribution', [Port]),
    append([ endpoint(Endpoint),
             credential(none),
             model('test/model')
           ],
           ExtraConfig,
           Config),
    Provider = provider(openai_compatible, Config),
    rlm_chain:model_complete_execute(
        Provider,
        model_request{messages:[message{role:user, content:"hi"}],
                      options:_{}},
        ok(_)).

attribution_handler(Request) :-
    capture_attribution_headers(Request),
    reply_json(_{id:"gen-test",
                 model:"test/model",
                 choices:[_{message:_{role:assistant, content:"ok"},
                           finish_reason:stop}],
                 usage:_{prompt_tokens:1,
                         completion_tokens:1,
                         total_tokens:2}}).

capture_attribution_headers(Request) :-
    findall(Header,
            ( member(H, Request),
              attribution_header(H, Header)
            ),
            Headers),
    retractall(captured_attribution(_)),
    assertz(captured_attribution(Headers)).

attribution_header('X-OpenRouter-Title'(Value), 'X-OpenRouter-Title'(Value)).
attribution_header('HTTP-Referer'(Value), 'HTTP-Referer'(Value)).
attribution_header(x_openrouter_title(Value), 'X-OpenRouter-Title'(Value)).
attribution_header(http_referer(Value), 'HTTP-Referer'(Value)).
attribution_header(user_agent(Value), 'User-Agent'(Value)).

with_zai_server(Goal, Kind, Captured) :-
    retractall(captured_zai_request(_, _)),
    setup_call_cleanup(
        http_server(http_dispatch, [port(Port)]),
        call(Goal, Port),
        http_stop_server(Port, [])),
    captured_zai_request(Kind, Captured).

run_zai_completion(ProviderName, Path, Port, Port) :-
    run_zai_completion(ProviderName, Path, [], Port, Port).

run_zai_completion(ProviderName, Path, ExtraConfig, Port, Port) :-
    format(atom(Endpoint), 'http://127.0.0.1:~d/~w', [Port, Path]),
    Config0 = [ endpoint(Endpoint),
                credential(none),
                model('glm-5.3'),
                timeout(5),
                address_family(inet)
              ],
    (   ProviderName == zai_claude
    ->  append(Config0, [default_max_tokens(4096)|ExtraConfig], Config)
    ;   append(Config0, ExtraConfig, Config)
    ),
    rlm_chain:model_complete_execute(
        provider(ProviderName, Config),
        model_request{messages:[message{role:user, content:"Reply"}],
                      options:generation_options{}},
        ok(Response)),
    assertion(Response.text == "ok").

zai_responses_handler(Request) :-
    http_read_json_dict(Request, Payload),
    retractall(captured_zai_request(zai_responses, _)),
    assertz(captured_zai_request(zai_responses, Request-Payload)),
    reply_json(_{id:"resp-test", model:"glm-5.3", status:"completed",
                 output:[_{type:"message", role:"assistant",
                           content:[_{type:"output_text", text:"ok"}]}],
                 usage:_{input_tokens:1, output_tokens:1, total_tokens:2}}).

zai_anthropic_handler(Request) :-
    http_read_json_dict(Request, Payload),
    retractall(captured_zai_request(zai_anthropic, _)),
    assertz(captured_zai_request(zai_anthropic, Request-Payload)),
    reply_json(_{id:"msg-test", model:"glm-5.3", role:"assistant",
                 content:[_{type:"text", text:"ok"}],
                 stop_reason:"end_turn",
                 usage:_{input_tokens:1, output_tokens:1}}).

request_header_value(Request, Name, Value) :-
    member(Header, Request),
    Header =.. [Name, Value].

:- end_tests(rlm_chain_app_attribution).
