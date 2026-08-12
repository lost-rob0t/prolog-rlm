:- begin_tests(live_openrouter).

:- use_module('../prolog/rlm_chain').

test(real_openrouter_inference) :-
    require_live_credential,
    default_openrouter_model(RequestedModel),
    openrouter_provider(RequestedModel, Provider),
    Request = model_request{
                  messages:[message{
                                role:user,
                                content:"Reply with the token PROLOG_RLM_OPENROUTER_OK."
                            }],
                  options:_{max_tokens:32}
              },
    model_complete(Provider, Request, Outcome),
    require_live_success(Outcome, Response),
    validate_live_response(RequestedModel, Response),
    log_safe_evidence(RequestedModel, Response).

require_live_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '', Key \== ""
    ->  true
    ;   throw(error(missing_live_credential('OPENROUTER_API_KEY'),
                    context(live_openrouter_test,
                            'OPENROUTER_API_KEY is not configured for live integration CI')))
    ).

require_live_success(ok(Response), Response) :-
    !.
require_live_success(error(Error), _) :-
    throw(error(live_openrouter_provider_failure(Error),
                context(live_openrouter_test,
                        'real OpenRouter request failed'))).

validate_live_response(RequestedModel, Response) :-
    assertion(Response.provider == openrouter),
    assertion(Response.requested_model == RequestedModel),
    SelectedModel = Response.selected_model,
    assertion(nonempty_textlike(SelectedModel)),
    assertion(assistant_output_present(Response)),
    assertion(Response.metadata.provider == openrouter),
    assertion(Response.metadata.http_status =:= 200),
    assertion(Response.metadata.response_received == true),
    validate_usage(Response.usage).

assistant_output_present(Response) :-
    get_dict(text, Response, Text),
    string(Text),
    Text \== "",
    !.
assistant_output_present(Response) :-
    get_dict(tool_calls, Response, ToolCalls),
    is_list(ToolCalls),
    ToolCalls \== [],
    !.
assistant_output_present(Response) :-
    get_dict(reasoning, Response, Reasoning),
    string(Reasoning),
    Reasoning \== "",
    !.
assistant_output_present(Response) :-
    get_dict(reasoning_details, Response, Details),
    is_list(Details),
    Details \== [].

validate_usage(Usage) :-
    assertion(memberchk(Usage.present, [true, false])),
    (   Usage.present == true
    ->  validate_optional_number(Usage.prompt_tokens),
        validate_optional_number(Usage.completion_tokens),
        validate_optional_number(Usage.total_tokens),
        validate_optional_number(Usage.cost)
    ;   true
    ).

validate_optional_number(null) :-
    !.
validate_optional_number(Value) :-
    number(Value).

nonempty_textlike(Value) :-
    string(Value),
    !,
    Value \== "".
nonempty_textlike(Value) :-
    atom(Value),
    Value \== ''.

expected_token_present(Text, Present) :-
    (   string(Text),
        sub_string(Text, _, _, _, "PROLOG_RLM_OPENROUTER_OK")
    ->  Present = true
    ;   Present = false
    ).

text_present(Response, Present) :-
    (   get_dict(text, Response, Text),
        string(Text),
        Text \== ""
    ->  Present = true
    ;   Present = false
    ).

reasoning_present(Response, Present) :-
    (   get_dict(reasoning, Response, Reasoning),
        string(Reasoning),
        Reasoning \== ""
    ->  Present = true
    ;   get_dict(reasoning_details, Response, Details),
        is_list(Details),
        Details \== []
    ->  Present = true
    ;   Present = false
    ).

log_safe_evidence(RequestedModel, Response) :-
    expected_token_present(Response.text, TokenPresent),
    text_present(Response, TextPresent),
    reasoning_present(Response, ReasoningPresent),
    format('provider: openrouter~n', []),
    format('requested_model: ~w~n', [RequestedModel]),
    format('selected_model: ~w~n', [Response.selected_model]),
    format('http_status: ~d~n', [Response.metadata.http_status]),
    format('response_received: true~n', []),
    format('usage_present: ~w~n', [Response.usage.present]),
    format('text_present: ~w~n', [TextPresent]),
    format('reasoning_present: ~w~n', [ReasoningPresent]),
    format('expected_token_present: ~w~n', [TokenPresent]).

:- end_tests(live_openrouter).
