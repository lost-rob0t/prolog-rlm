:- begin_tests(rlm_completion_stream).

:- use_module('../prolog/rlm_completion').
:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/prolog_agent_ui_v1').
:- use_module('../prolog/prolog_agent_ui_facade').
:- use_module('support/completion_test_support').
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_header)).
:- use_module(library(http/http_server)).
:- use_module(library(http/json)).

:- dynamic stream_seen/1.
:- dynamic sse_body/1.

reset_stream :-
    retractall(stream_seen(_)).

collect_stream(Message) :-
    assertz(stream_seen(Message)).

delivered(Messages) :-
    findall(Message, stream_seen(Message), Messages).

stream_provider(Port, provider(openai_compatible, Config)) :-
    format(atom(Endpoint), 'http://127.0.0.1:~d/sse', [Port]),
    Config = [endpoint(Endpoint),
              credential(none),
              model('test/model')].

:- http_handler(root(sse), sse_handler, [method(post)]).

sse_handler(_Request) :-
    sse_body(Body),
    format('Content-type: text/event-stream\n\n'),
    format('~s', [Body]).

with_sse_server(Body, Goal) :-
    setup_call_cleanup(
        assertz(sse_body(Body)),
        setup_call_cleanup(http_server(http_dispatch, [port(Port)]),
                           call(Goal, Port),
                           http_stop_server(Port, [])),
        retractall(sse_body(_))).

chunk_line(Delta, Finish, Line) :-
    Chunk = _{id:"chat-1",
              model:"test/model",
              choices:[_{index:0,
                        delta:Delta,
                        finish_reason:Finish}]},
    compact_json(Chunk, Json),
    atom_concat('data: ', Json, Line).

compact_json(Term, Json) :-
    with_output_to(string(Json),
                   json_write_dict(current_output,
                                   Term,
                                   [width(0), tab_distance(0)])).

raw_usage_line(Line) :-
    Usage = _{id:"chat-1",
              model:"test/model",
              choices:[],
              usage:_{prompt_tokens:2, completion_tokens:3, total_tokens:5}},
    compact_json(Usage, Json),
    atom_concat('data: ', Json, Line).

raw_done_line("data: [DONE]").

join_lines(Lines, Body) :-
    atomic_list_concat(Lines, '\n', LinesText),
    string_concat(LinesText, '\n', Body).

streaming_text_body(Body) :-
    chunk_line(_{role:assistant, content:"He"}, null, Line1),
    chunk_line(_{role:assistant, content:"llo"}, null, Line2),
    chunk_line(_{}, stop, Line3),
    raw_usage_line(Line4),
    raw_done_line(Line5),
    join_lines([Line1, Line2, Line3, Line4, Line5], Body).

direct_envelope_body(Body) :-
    chunk_line(_{role:assistant,
                 content:"{\"mode\":\"direct\","}, null, Line1),
    chunk_line(_{role:assistant,
                 content:"\"answer\":\"Hello there\"}"}, null, Line2),
    chunk_line(_{}, stop, Line3),
    raw_usage_line(Line4),
    raw_done_line(Line5),
    join_lines([Line1, Line2, Line3, Line4, Line5], Body).

reasoning_only_body(Body) :-
    chunk_line(_{reasoning:"thinking"}, null, Line1),
    chunk_line(_{}, stop, Line2),
    raw_usage_line(Line3),
    raw_done_line(Line4),
    join_lines([Line1, Line2, Line3, Line4], Body).

missing_done_body(Body) :-
    chunk_line(_{role:assistant, content:"Hi"}, null, Line1),
    chunk_line(_{}, stop, Line2),
    raw_usage_line(Line3),
    join_lines([Line1, Line2, Line3], Body).

cancelled_on_first_delta(Message) :-
    assertz(stream_seen(Message)),
    (   Message.phase == delta
    ->  rlm_cancel('stream-test-token'),
        throw(error(rlm_cancelled('stream-test-token'),
                    context(rlm_completion_stream_test,
                            'mid-stream cancellation')))
    ;   true
    ).

/* Pump transition units ------------------------------------------------- */

test(pump_first_text_event_delivers_started_then_delta) :-
    CallRef = stream_call{operation:model, depth:0, seq:1},
    State0 = stream_pump_state{call:CallRef,
                               handler:collect_stream,
                               started:false,
                               text:"",
                               reasoning:"",
                               usage:none},
    Event = stream_event{type:text, choice_index:0, delta:"He"},
    rlm_completion:stream_pump_step(State0, Event, State1, Deliveries),
    Deliveries = [Started, Delta],
    Started == stream_message{call:CallRef, phase:started, role:"assistant"},
    Delta == stream_message{call:CallRef, phase:delta, text:"He"},
    assertion(State1.started == true),
    assertion(State1.text == "He"),
    \+ stream_seen(_).

test(pump_second_text_event_delivers_only_delta) :-
    CallRef = stream_call{operation:model, depth:0, seq:1},
    State0 = stream_pump_state{call:CallRef,
                               handler:collect_stream,
                               started:true,
                               text:"He",
                               reasoning:"",
                               usage:none},
    Event = stream_event{type:text, choice_index:0, delta:"llo"},
    rlm_completion:stream_pump_step(State0, Event, State1, Deliveries),
    Deliveries = [Delta],
    Delta == stream_message{call:CallRef, phase:delta, text:"llo"},
    assertion(State1.text == "Hello").

test(pump_reasoning_and_usage_observed_without_delivery) :-
    CallRef = stream_call{operation:model, depth:0, seq:1},
    State0 = stream_pump_state{call:CallRef,
                               handler:collect_stream,
                               started:false,
                               text:"",
                               reasoning:"",
                               usage:none},
    Reasoning = stream_event{type:reasoning, choice_index:0, delta:"think"},
    rlm_completion:stream_pump_step(State0, Reasoning, State1, []),
    assertion(State1.reasoning == "think"),
    assertion(State1.started == false),
    Usage = stream_event{type:usage,
                         usage:_{prompt_tokens:2,
                                 completion_tokens:3,
                                 total_tokens:5}},
    rlm_completion:stream_pump_step(State1, Usage, State2, []),
    assertion(State2.usage = _{prompt_tokens:2,
                               completion_tokens:3,
                               total_tokens:5}),
    Done = stream_event{type:done},
    rlm_completion:stream_pump_step(State2, Done, State3, []),
    assertion(State3 == State2).

test(pump_aggregate_mismatch_is_hard_divergence_error) :-
    CallRef = stream_call{operation:model, depth:0, seq:1},
    State = stream_pump_state{call:CallRef,
                              handler:collect_stream,
                              started:true,
                              text:"wrong",
                              reasoning:"",
                              usage:none},
    Response = model_response{provider:openai_compatible,
                              requested_model:'test/model',
                              selected_model:'test/model',
                              response_id:"chat-1",
                              assistant:message{role:assistant,
                                                content:"Hello",
                                                tool_calls:[],
                                                reasoning:"",
                                                reasoning_details:[]},
                              text:"Hello",
                              tool_calls:[],
                              reasoning:"",
                              reasoning_details:[],
                              finish_reason:"stop",
                              usage:none,
                              metadata:provider_metadata{provider:openai_compatible,
                                                         http_status:200,
                                                         response_received:true,
                                                         streaming:true}},
    (   catch((rlm_completion:stream_pump_finalize(State, Response),
               fail),
              stream_fault(delta_final_divergence(Usage)),
              assertion(is_dict(Usage) ; Usage == none))
    ->  true
    ;   throw(error(unexpected_completion_outcome(no_divergence_thrown),
                    context(rlm_completion_stream_test,
                            expected_divergence_error)))
    ),
    \+ stream_seen(_).

/* Option conflict rules ------------------------------------------------- */

test(text_delta_handler_conflicts_with_model_handler) :-
    llm_query("hello",
              [ text_delta_handler(plunit_rlm_completion_stream:collect_stream),
                model_handler(completion_test_support:fake_model)
              ],
              Outcome),
    expect_error(Outcome, Error),
    assertion(Error.kind == conflicting_stream_option),
    assertion(Error.with == model_handler).

test(text_delta_handler_conflicts_with_planner_handler) :-
    Options = [text_delta_handler(plunit_rlm_completion_stream:collect_stream),
               planner_handler(planner),
               provider(provider(openai_compatible,
                                 [endpoint('http://127.0.0.1:1/sse'),
                                  credential(none),
                                  model('test/model')]))],
    provider_options(Options, _ProviderName, Provider),
    Request = model_request{messages:[message{role:user, content:"hi"}],
                            options:_{}},
    catch(rlm_completion:call_planner(Options, Provider, Request, _),
          completion_fault(conflicting_stream_option(planner_handler)),
          true).

/* End-to-end streaming over the local fixture server -------------------- */

test(llm_query_streams_deltas_with_lifecycle_and_usage_once,
     [setup(reset_stream)]) :-
    streaming_text_body(Body),
    with_sse_server(Body, stream_llm_hello(Outcome)),
    expect_ok(Outcome, Result),
    assertion(Result.response.text == "Hello"),
    assertion(Result.usage.model_calls =:= 1),
    assertion(Result.usage.total_tokens =:= 5),
    delivered(Messages),
    length(Messages, 4),
    Messages = [Started, Delta1, Delta2, Completed],
    Started = stream_message{call:stream_call{operation:model,
                                              depth:0,
                                              seq:_},
                             phase:started,
                             role:"assistant"},
    Delta1 = stream_message{call:CallRef, phase:delta, text:"He"},
    Delta2 = stream_message{call:CallRef, phase:delta, text:"llo"},
    assertion(Delta1.call == Delta2.call),
    Completed = stream_message{call:CallRef, phase:completed}.

stream_llm_hello(Outcome, Port) :-
    stream_provider(Port, Provider),
    llm_query("hello",
              [ provider(Provider),
                text_delta_handler(plunit_rlm_completion_stream:collect_stream)
              ],
              Outcome).

test(recursive_rlm_query_streaming_is_attributed_to_depth,
     [setup(reset_stream)]) :-
    streaming_text_body(Body),
    with_sse_server(Body, stream_rlm_query_depth2(Outcome)),
    expect_ok(Outcome, Result),
    assertion(Result.depth =:= 2),
    assertion(Result.response.text == "Hello"),
    delivered(Messages),
    Messages = [Started|_],
    Started.call == stream_call{operation:model, depth:2, seq:1},
    last(Messages, Completed),
    Completed.phase == completed.

stream_rlm_query_depth2(Outcome, Port) :-
    stream_provider(Port, Provider),
    rlm_query("child",
              text("ctx"),
              [ provider(Provider),
                text_delta_handler(plunit_rlm_completion_stream:collect_stream),
                depth(2),
                budget(_{max_recursion_depth:4})
              ],
              Outcome).

test(root_completion_streams_direct_answer_through_planner,
     [setup(reset_stream)]) :-
    direct_envelope_body(Body),
    with_sse_server(Body, stream_root_direct(Outcome)),
    expect_ok(Outcome, Result),
    assertion(Result.value == "Hello there"),
    assertion(Result.usage.model_calls =:= 1),
    delivered(Messages),
    Messages = [Started, Delta1, Delta2, Completed],
    Started.call.operation == planner,
    Started.call.depth == 0,
    Started.phase == started,
    Started.role == "assistant",
    Delta1 = stream_message{call:_, phase:delta, text:"{\"mode\":\"direct\","},
    Delta2 = stream_message{call:_, phase:delta, text:"\"answer\":\"Hello there\"}"},
    Completed.phase == completed.

stream_root_direct(Outcome, Port) :-
    stream_provider(Port, Provider),
    rlm_completion("answer directly",
                   text("ctx"),
                   [ provider(Provider),
                     text_delta_handler(plunit_rlm_completion_stream:collect_stream)
                   ],
                   Outcome).

test(mid_stream_cancellation_yields_conservative_cancelled_envelope,
     [setup(reset_stream)]) :-
    streaming_text_body(Body),
    with_sse_server(Body, stream_llm_cancel(Outcome)),
    expect_error(Outcome, Error),
    assertion(Error.kind == cancelled),
    delivered(Messages),
    Messages = [Started, Delta],
    Started.phase == started,
    Delta.phase == delta,
    forall(member(Message, Messages), Message.phase \== completed).

stream_llm_cancel(Outcome, Port) :-
    stream_provider(Port, Provider),
    llm_query("hello",
              [ provider(Provider),
                text_delta_handler(plunit_rlm_completion_stream:cancelled_on_first_delta),
                cancel_token('stream-test-token')
              ],
              Outcome).

test(missing_done_sentinel_preserves_observed_stream_usage,
     [setup(reset_stream)]) :-
    missing_done_body(Body),
    with_sse_server(Body, stream_llm_missing_done(Outcome)),
    expect_error(Outcome, Error),
    assertion(Error.kind == invalid_stream),
    assertion(Error.stream_usage.total_tokens =:= 5),
    delivered(Messages),
    Messages = [Started, Delta],
    Started.phase == started,
    Delta.text == "Hi",
    forall(member(Message, Messages), Message.phase \== completed).

stream_llm_missing_done(Outcome, Port) :-
    stream_provider(Port, Provider),
    llm_query("hello",
              [ provider(Provider),
                text_delta_handler(plunit_rlm_completion_stream:collect_stream)
              ],
              Outcome).

test(reasoning_only_stream_starts_no_message,
     [setup(reset_stream)]) :-
    reasoning_only_body(Body),
    with_sse_server(Body, stream_llm_reasoning_only(Outcome)),
    expect_ok(Outcome, Result),
    assertion(Result.response.text == ""),
    assertion(Result.response.reasoning == "thinking"),
    delivered(Messages),
    assertion(Messages == []).

stream_llm_reasoning_only(Outcome, Port) :-
    stream_provider(Port, Provider),
    llm_query("hello",
              [ provider(Provider),
                text_delta_handler(plunit_rlm_completion_stream:collect_stream)
              ],
              Outcome).

/* Host adapter projection to canonical UI v1 events --------------------- */

test(adapter_projects_stream_messages_to_ui_v1_frames,
     [setup(reset_stream)]) :-
    streaming_text_body(Body),
    with_sse_server(Body, stream_llm_adapter(Outcome)),
    expect_ok(Outcome, _),
    findall(Canonical, stream_seen(Canonical), CanonicalEvents),
    assertion(length(CanonicalEvents, 4)),
    ui_v1_initial_view("session-1", View0),
    foldl(apply_ui_event("session-1"), CanonicalEvents, View0, FinalView),
    assertion(FinalView.at_seq >= 4),
    member(Message, FinalView.messages),
    assertion(Message.id == "conv-1:model:0:1"),
    assertion(Message.text == "Hello"),
    assertion(Message.status == "complete").

stream_llm_adapter(Outcome, Port) :-
    stream_provider(Port, Provider),
    llm_query("hello",
              [ provider(Provider),
                text_delta_handler(
                    plunit_rlm_completion_stream:
                    ui_stream_handler('conv-1',
                                      plunit_rlm_completion_stream:collect_stream))
              ],
              Outcome).

apply_ui_event(SessionId, CanonicalEvent, View0, View) :-
    Seq is View0.at_seq + 1,
    ui_facade_event(SessionId, Seq, CanonicalEvent, Frame),
    ui_v1_apply_event(View0, Frame, ok(View)).

expect_ok(ok(Result), Result) :- !.
expect_ok(Outcome, _) :-
    throw(error(unexpected_completion_outcome(Outcome),
                context(rlm_completion_stream_test, expected_ok))).

expect_error(error(Error), Error) :- !.
expect_error(Outcome, _) :-
    throw(error(unexpected_completion_outcome(Outcome),
                context(rlm_completion_stream_test, expected_error))).

:- end_tests(rlm_completion_stream).
