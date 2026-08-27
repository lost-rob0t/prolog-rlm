:- begin_tests(rlm_chain_app_attribution).

:- use_module('../prolog/rlm_chain').
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(http/thread_httpd)).

:- dynamic captured_attribution/1.

:- http_handler(root(attribution), attribution_handler, [method(post)]).

test(openrouter_provider_defaults_identify_the_app) :-
    rlm_chain:openrouter_provider('test/model', Provider),
    Provider = provider(openrouter, Config),
    memberchk(app_title('prolog-rlm'), Config),
    memberchk(app_referer('https://github.com/lost-rob0t/prolog-rlm'),
              Config).

test(downstream_provider_terms_override_attribution_headers) :-
    with_attribution_server(
        run_completion(Port,
                       [ app_title('agentProlog'),
                         app_referer('https://example.com/app')
                       ]),
        Headers),
    memberchk('X-OpenRouter-Title'('agentProlog'), Headers),
    memberchk('HTTP-Referer'('https://example.com/app'), Headers).

test(openrouter_request_carries_default_attribution_headers) :-
    with_attribution_server(
        run_completion(Port,
                       [ app_title('prolog-rlm'),
                         app_referer('https://github.com/lost-rob0t/prolog-rlm')
                       ]),
        Headers),
    memberchk('X-OpenRouter-Title'('prolog-rlm'), Headers),
    memberchk('HTTP-Referer'('https://github.com/lost-rob0t/prolog-rlm'),
              Headers).

test(unattributed_custom_endpoint_sends_no_attribution_headers) :-
    with_attribution_server(run_completion(Port, []), Headers),
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

:- end_tests(rlm_chain_app_attribution).
