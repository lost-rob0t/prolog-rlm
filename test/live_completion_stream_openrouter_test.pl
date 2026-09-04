:- begin_tests(live_completion_stream_openrouter).

:- use_module('../prolog/rlm_completion').
:- use_module('../prolog/rlm_chain',
              [ default_openrouter_model/1,
                openrouter_provider/2
              ]).

:- dynamic live_stream_message/1.

test(real_openrouter_streaming_through_the_completion_boundary,
     [setup(retractall(live_stream_message(_)))]) :-
    require_stream_credential,
    default_openrouter_model(RequestedModel),
    openrouter_provider(RequestedModel, Provider),
    llm_query("Reply with exactly STREAM_OK and nothing else.",
              [ provider(Provider),
                text_delta_handler(plunit_live_completion_stream_openrouter:record_stream_message),
                budget(_{max_total_tokens:4096}),
                planner_max_tokens(1024),
                temperature(0),
                reasoning_effort(minimal)
              ],
              Outcome),
    require_completion_success(Outcome, Result),
    validate_completion_stream_result(RequestedModel, Result),
    log_completion_stream_evidence(RequestedModel, Result).

record_stream_message(Message) :-
    assertion(ground(Message)),
    assertion(memberchk(Message.phase, [started,delta,completed])),
    (   Message.phase == delta
    ->  assertion(string(Message.text))
    ;   true
    ),
    assertz(live_stream_message(Message)).

require_stream_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '', Key \== ""
    ->  true
    ;   throw(error(missing_live_credential('OPENROUTER_API_KEY'),
                    context(live_completion_stream_openrouter_test,
                            'OPENROUTER_API_KEY is not configured for live integration CI')))
    ).

require_completion_success(ok(Result), Result) :- !.
require_completion_success(error(Error), _) :-
    throw(error(live_openrouter_completion_stream_failure(Error),
                context(live_completion_stream_openrouter_test,
                        'real OpenRouter streaming completion failed'))).

validate_completion_stream_result(RequestedModel, Result) :-
    Response = Result.response,
    assertion(Response.provider == openrouter),
    assertion(Response.requested_model == RequestedModel),
    assertion(nonempty_textlike(Response.selected_model)),
    assertion(Response.metadata.provider == openrouter),
    assertion(Response.metadata.http_status =:= 200),
    assertion(Response.metadata.streaming == true),
    assertion(Response.text \== ""),
    findall(Message, live_stream_message(Message), Delivered),
    Delivered = [Started|Rest],
    Started = stream_message{call:CallRef, phase:started, role:"assistant"},
    assertion(CallRef.operation == model),
    assertion(CallRef.depth == 0),
    assertion(ground(CallRef.seq)),
    last(Rest, Completed),
    Completed = stream_message{call:CallRef, phase:completed},
    findall(Delta,
            (member(Message, Rest), Message.phase == delta, Delta = Message.text),
            Deltas),
    assertion(Deltas \== []),
    atomics_to_string(Deltas, AggregateText),
    assertion(AggregateText == Response.text),
    assertion(Result.usage.model_calls =:= 1),
    assertion(Result.usage.tokens_known == true).

log_completion_stream_evidence(RequestedModel, Result) :-
    Response = Result.response,
    findall(Message, live_stream_message(Message), Delivered),
    include(is_delta_message, Delivered, Deltas),
    length(Deltas, DeltaCount),
    format('completion_stream_provider: openrouter~n', []),
    format('completion_stream_requested_model: ~w~n', [RequestedModel]),
    format('completion_stream_selected_model: ~w~n', [Response.selected_model]),
    format('completion_stream_delta_count: ~d~n', [DeltaCount]),
    format('completion_stream_aggregate_matches_final: true~n', []),
    format('completion_stream_usage_total_tokens: ~w~n',
           [Result.usage.total_tokens]).

is_delta_message(Message) :-
    Message.phase == delta.

nonempty_textlike(Value) :-
    string(Value),
    !,
    Value \== "".
nonempty_textlike(Value) :-
    atom(Value),
    Value \== ''.

:- end_tests(live_completion_stream_openrouter).
