:- begin_tests(rlm_stream_canonical).

:- use_module('../prolog/rlm_openai_compatible',
              [ openai_compatible_parse_sse_lines/5
              ]).

:- dynamic canonical_event_seen/1.

reset_events :- retractall(canonical_event_seen(_)).

record_event(Event) :-
    assertion(ground(Event)),
    assertz(canonical_event_seen(Event)).

test(stream_json_is_ground_and_duplicate_finish_is_suppressed,
     [setup(reset_events)]) :-
    Lines = [
      "data: {\"id\":\"chat-ground\",\"model\":\"test/model\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"think\",\"reasoning_details\":[{\"type\":\"reasoning.text\",\"text\":\"think\"}]},\"finish_reason\":null}]}",
      "data: {\"id\":\"chat-ground\",\"model\":\"test/model\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"q\\\":\\\"x\\\"}\"}}]},\"finish_reason\":null}]}",
      "data: {\"id\":\"chat-ground\",\"model\":\"test/model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}]}",
      "data: {\"id\":\"chat-ground\",\"model\":\"test/model\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}",
      "data: {\"id\":\"chat-ground\",\"model\":\"test/model\",\"choices\":[],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3,\"total_tokens\":5}}",
      "data: [DONE]"
    ],
    openai_compatible_parse_sse_lines(openrouter,
                                      'openrouter/free',
                                      Lines,
                                      plunit_rlm_stream_canonical:record_event,
                                      ok(StreamResult)),
    assertion(ground(StreamResult)),
    findall(Event, canonical_event_seen(Event), Delivered),
    assertion(Delivered == StreamResult.events),
    findall(Finish,
            (member(Finish, Delivered), Finish.type == finish),
            Finishes),
    Finishes = [OnlyFinish],
    assertion(OnlyFinish.finish_reason == "stop"),
    Response = StreamResult.response,
    assertion(Response.text == "done"),
    assertion(Response.finish_reason == "stop"),
    Response.tool_calls = [ToolCall],
    assertion(ground(ToolCall)),
    assertion(ToolCall.function.name == "lookup"),
    assertion(Response.usage.total_tokens =:= 5).

:- end_tests(rlm_stream_canonical).
