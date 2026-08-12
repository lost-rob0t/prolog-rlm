:- begin_tests(live_chain_stream_openrouter).

:- use_module('../prolog/rlm_chain').

:- dynamic live_stream_event/1.

test(real_openrouter_streaming_request,
     [setup(retractall(live_stream_event(_)))]) :-
    require_stream_credential,
    default_openrouter_model(RequestedModel),
    openrouter_provider(RequestedModel, Provider),
    Request = model_request{
                  messages:[message{
                                role:user,
                                content:"Reply with exactly STREAM_OK and nothing else."
                            }],
                  options:_{max_tokens:32,
                            temperature:0}
              },
    chain_stream(Provider,
                 Request,
                 [],
                 plunit_live_chain_stream_openrouter:record_live_stream_event,
                 Outcome),
    require_stream_success(Outcome, Result),
    validate_stream_result(RequestedModel, Result),
    log_stream_evidence(RequestedModel, Result).

record_live_stream_event(Event) :-
    assertz(live_stream_event(Event)).

require_stream_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '', Key \== ""
    ->  true
    ;   throw(error(missing_live_credential('OPENROUTER_API_KEY'),
                    context(live_chain_stream_openrouter_test,
                            'OPENROUTER_API_KEY is not configured for live integration CI')))
    ).

require_stream_success(ok(Result), Result) :- !.
require_stream_success(error(Error), _) :-
    throw(error(live_openrouter_stream_failure(Error),
                context(live_chain_stream_openrouter_test,
                        'real OpenRouter streaming request failed'))).

validate_stream_result(RequestedModel, Result) :-
    Response = Result.response,
    assertion(Response.provider == openrouter),
    assertion(Response.requested_model == RequestedModel),
    assertion(nonempty_textlike(Response.selected_model)),
    assertion(Response.metadata.provider == openrouter),
    assertion(Response.metadata.http_status =:= 200),
    assertion(Response.metadata.response_received == true),
    assertion(Response.metadata.streaming == true),
    assertion(string(Response.text)),
    assertion(Response.text \== ""),
    assertion(is_list(Result.stream_events)),
    assertion(Result.stream_events \== []),
    findall(Event, live_stream_event(Event), Delivered),
    assertion(Delivered == Result.stream_events),
    assertion(member(Event, Delivered)),
    assertion(Event.type == text),
    assertion(last(Delivered, DoneEvent)),
    assertion(DoneEvent.type == done),
    validate_stream_usage(Response.usage).

validate_stream_usage(Usage) :-
    assertion(memberchk(Usage.present, [true,false])),
    (   Usage.present == true
    ->  validate_optional_number(Usage.prompt_tokens),
        validate_optional_number(Usage.completion_tokens),
        validate_optional_number(Usage.total_tokens),
        validate_optional_number(Usage.cost)
    ;   true
    ).

validate_optional_number(null) :- !.
validate_optional_number(Value) :- number(Value).

nonempty_textlike(Value) :-
    string(Value),
    !,
    Value \== "".
nonempty_textlike(Value) :-
    atom(Value),
    Value \== ''.

count_incremental_events(Events, Count) :-
    include(incremental_event, Events, Incremental),
    length(Incremental, Count).

incremental_event(Event) :-
    memberchk(Event.type, [text,reasoning,tool_call]).

log_stream_evidence(RequestedModel, Result) :-
    Response = Result.response,
    count_incremental_events(Result.stream_events, IncrementalCount),
    (   Response.text \== "" -> TextPresent = true ; TextPresent = false ),
    (   last(Result.stream_events, Done), Done.type == done
    ->  DonePresent = true
    ;   DonePresent = false
    ),
    format('stream_provider: openrouter~n', []),
    format('stream_requested_model: ~w~n', [RequestedModel]),
    format('stream_selected_model: ~w~n', [Response.selected_model]),
    format('stream_http_status: ~d~n', [Response.metadata.http_status]),
    format('stream_response_received: true~n', []),
    format('stream_incremental_event_count: ~d~n', [IncrementalCount]),
    format('stream_done: ~w~n', [DonePresent]),
    format('stream_usage_present: ~w~n', [Response.usage.present]),
    format('stream_final_text_present: ~w~n', [TextPresent]).

:- end_tests(live_chain_stream_openrouter).
