:- begin_tests(rlm_chain_runtime).

:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/rlm_chain_runtime',
              [ chain_invoke_with_transport/5
              ]).
:- use_module('../prolog/rlm_openai_compatible',
              [ openai_compatible_parse_sse_lines/5
              ]).

:- dynamic attempt_counter/1.
:- dynamic sleep_seen/1.
:- dynamic middleware_seen/1.
:- dynamic request_seen/1.
:- dynamic stream_event_seen/1.

reset_test_state :-
    retractall(attempt_counter(_)),
    retractall(sleep_seen(_)),
    retractall(middleware_seen(_)),
    retractall(request_seen(_)),
    retractall(stream_event_seen(_)),
    assertz(attempt_counter(0)).

next_attempt(Attempt) :-
    retract(attempt_counter(Current)),
    Attempt is Current+1,
    assertz(attempt_counter(Attempt)).

base_request(model_request{
                 messages:[message{role:user, content:"hello"}],
                 options:_{}
             }).

test(message_role_content_normalization) :-
    message_normalize(message("user", hello), ok(Message)),
    assertion(Message.role == user),
    assertion(Message.content == "hello").

test(multimodal_content_metadata_normalization) :-
    Input = _{role:user,
              content:[text("inspect"),
                       image_url("https://example.invalid/a.png", high)]},
    message_normalize(Input, ok(Message)),
    Message.content = [TextPart, ImagePart],
    assertion(TextPart.type == text),
    assertion(TextPart.text == "inspect"),
    assertion(ImagePart.type == image_url),
    assertion(ImagePart.image_url.url == "https://example.invalid/a.png"),
    assertion(ImagePart.image_url.detail == high).

test(prompt_slot_binding) :-
    prompt_compile(prompt([text("hello "), slot(name), text(" #"), slot(id)]),
                   ok(Prompt)),
    prompt_bind(Prompt, _{name:"Ada", id:7}, ok(Text)),
    assertion(Text == "hello Ada #7").

test(prompt_missing_slot_is_structured_error) :-
    prompt_compile(prompt([slot(required)]), ok(Prompt)),
    prompt_bind(Prompt, _{}, error(Error)),
    assertion(Error.phase == prompt),
    assertion(Error.kind == validation_error),
    assertion(Error.detail == missing_prompt_binding(required)).

test(structured_schema_success_and_failure) :-
    Spec = object([field(answer, string, required),
                   field(score, number, required)]),
    structured_schema_compile(Spec, ok(Schema)),
    structured_validate(Schema,
                        json{answer:"yes", score:0.9},
                        ok(_)),
    structured_validate(Schema,
                        json{answer:"yes", score:"bad"},
                        error(Error)),
    assertion(Error.phase == structured_output),
    assertion(Error.kind == validation_error).

test(provider_route_selects_declared_candidate,
     [setup(reset_test_state)]) :-
    base_request(Request),
    P1 = provider(one, []),
    P2 = provider(two, []),
    chain_invoke_with_transport(route([P1,P2]),
                                Request,
                                [router(plunit_rlm_chain_runtime:choose_second)],
                                plunit_rlm_chain_runtime:route_transport,
                                ok(Result)),
    assertion(Result.provider == P2),
    assertion(Result.response.text == "routed").

test(provider_route_rejects_undeclared_selection,
     [setup(reset_test_state)]) :-
    base_request(Request),
    P1 = provider(one, []),
    chain_invoke_with_transport(route([P1]),
                                Request,
                                [router(plunit_rlm_chain_runtime:choose_outside)],
                                plunit_rlm_chain_runtime:route_transport,
                                error(Error)),
    assertion(Error.kind == invalid_route_selection),
    assertion(Error.phase == route).

test(provider_retry_is_bounded_and_observable,
     [setup(reset_test_state)]) :-
    base_request(Request),
    Policy = _{max_attempts:2,
               base_delay:0.25,
               max_delay:1.0,
               retry_kinds:[provider_error]},
    chain_invoke_with_transport(provider(test, []),
                                Request,
                                [retry_policy(Policy),
                                 sleep_handler(plunit_rlm_chain_runtime:record_sleep)],
                                plunit_rlm_chain_runtime:retry_once_transport,
                                ok(Result)),
    assertion(Result.attempts == 2),
    assertion(sleep_seen(0.25)),
    assertion(Result.usage.total_tokens =:= 5),
    trace_types(Result.trace, Types),
    assertion(memberchk(provider_error, Types)),
    assertion(memberchk(retry_scheduled, Types)),
    assertion(trace_sequences_contiguous(Result.trace)).

test(provider_retry_exhaustion,
     [setup(reset_test_state)]) :-
    base_request(Request),
    Policy = _{max_attempts:3,
               base_delay:0.0,
               max_delay:0.0,
               retry_kinds:[provider_error]},
    chain_invoke_with_transport(provider(test, []),
                                Request,
                                [retry_policy(Policy)],
                                plunit_rlm_chain_runtime:always_error_transport,
                                error(Error)),
    assertion(Error.kind == provider_error),
    assertion(Error.attempt == 3),
    assertion(attempt_counter(3)),
    trace_types(Error.trace, Types),
    include(=(retry_scheduled), Types, Retries),
    assertion(Retries == [retry_scheduled,retry_scheduled]).

test(structured_validation_retry_aggregates_usage,
     [setup(reset_test_state)]) :-
    base_request(Request),
    Policy = _{max_attempts:2,
               base_delay:0.0,
               max_delay:0.0,
               retry_kinds:[structured_validation]},
    Schema = object([field(answer, string, required)]),
    chain_invoke_with_transport(provider(test, []),
                                Request,
                                [retry_policy(Policy),
                                 structured_schema(Schema)],
                                plunit_rlm_chain_runtime:structured_retry_transport,
                                ok(Result)),
    assertion(Result.attempts == 2),
    assertion(Result.structured.answer == "ok"),
    assertion(Result.usage.prompt_tokens =:= 3),
    assertion(Result.usage.completion_tokens =:= 4),
    assertion(Result.usage.total_tokens =:= 7),
    trace_types(Result.trace, Types),
    assertion(memberchk(structured_validation_failed, Types)),
    assertion(memberchk(structured_validation_succeeded, Types)).

test(middleware_runs_in_declared_order_and_transforms,
     [setup(reset_test_state)]) :-
    base_request(Request),
    Middleware = [middleware(request,
                             plunit_rlm_chain_runtime:request_middleware_one),
                  middleware(request,
                             plunit_rlm_chain_runtime:request_middleware_two),
                  middleware(model_response,
                             plunit_rlm_chain_runtime:response_middleware)],
    chain_invoke_with_transport(provider(test, []),
                                Request,
                                [middleware(Middleware)],
                                plunit_rlm_chain_runtime:middleware_transport,
                                ok(Result)),
    findall(Stage, middleware_seen(Stage), Seen),
    assertion(Seen == [request_one,request_two,response]),
    assertion(Result.response.text == "after-response"),
    request_seen(ProviderRequest),
    assertion(ProviderRequest.options.first == true),
    assertion(ProviderRequest.options.second == true).

test(middleware_failure_short_circuits_provider,
     [setup(reset_test_state)]) :-
    base_request(Request),
    Middleware = [middleware(request,
                             plunit_rlm_chain_runtime:failing_middleware)],
    chain_invoke_with_transport(provider(test, []),
                                Request,
                                [middleware(Middleware)],
                                plunit_rlm_chain_runtime:must_not_run_transport,
                                error(Error)),
    assertion(Error.kind == middleware_failed),
    assertion(Error.phase == middleware),
    assertion(attempt_counter(0)).

test(tool_call_middleware_transforms_call,
     [setup(reset_test_state)]) :-
    base_request(Request),
    Middleware = [middleware(tool_call,
                             plunit_rlm_chain_runtime:tool_call_middleware)],
    chain_invoke_with_transport(provider(test, []),
                                Request,
                                [middleware(Middleware)],
                                plunit_rlm_chain_runtime:tool_transport,
                                ok(Result)),
    Result.response.tool_calls = [Call],
    assertion(Call.reviewed == true),
    assertion(middleware_seen(tool_call)).

test(deterministic_sse_parser_normalizes_incremental_events_and_usage,
     [setup(reset_test_state)]) :-
    Lines = [
      "data: {\"id\":\"chat-test\",\"model\":\"test/model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hel\"},\"finish_reason\":null}]}",
      "",
      "data: {\"id\":\"chat-test\",\"model\":\"test/model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo\",\"reasoning\":\"think\"},\"finish_reason\":null}]}",
      "data: {\"id\":\"chat-test\",\"model\":\"test/model\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]},\"finish_reason\":null}]}",
      "data: {\"id\":\"chat-test\",\"model\":\"test/model\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
      "data: {\"id\":\"chat-test\",\"model\":\"test/model\",\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":3,\"total_tokens\":7,\"cost\":0.01}}",
      "data: [DONE]"
    ],
    openai_compatible_parse_sse_lines(openrouter,
                                      'openrouter/free',
                                      Lines,
                                      plunit_rlm_chain_runtime:record_stream_event,
                                      ok(StreamResult)),
    Response = StreamResult.response,
    assertion(Response.text == "hello"),
    assertion(Response.reasoning == "think"),
    assertion(Response.finish_reason == "tool_calls"),
    assertion(Response.usage.present == true),
    assertion(Response.usage.total_tokens =:= 7),
    Response.tool_calls = [ToolCall],
    assertion(ToolCall.id == "call-1"),
    assertion(ToolCall.function.name == "lookup"),
    assertion(ToolCall.function.arguments == "{}"),
    findall(Event, stream_event_seen(Event), SeenEvents),
    maplist(event_type, SeenEvents, EventTypes),
    assertion(EventTypes == [text,text,reasoning,tool_call,finish,usage,done]),
    assertion(StreamResult.events == SeenEvents).

test(sse_parser_requires_done_sentinel,
     [setup(reset_test_state)]) :-
    Lines = ["data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}"],
    openai_compatible_parse_sse_lines(openrouter,
                                      'openrouter/free',
                                      Lines,
                                      plunit_rlm_chain_runtime:record_stream_event,
                                      error(Error)),
    assertion(Error.kind == invalid_stream),
    assertion(Error.detail == missing_done).

choose_second(_, [_,Second], Second).
choose_outside(_, _, provider(outside, [])).

route_transport(Provider, _, ok(Response)) :-
    assertion(Provider == provider(two, [])),
    response("routed", [], 1, 1, 2, Response).

retry_once_transport(_, _, Outcome) :-
    next_attempt(Attempt),
    (   Attempt =:= 1
    ->  Outcome = error(provider_error{kind:temporary, message:"retry me"})
    ;   response("success", [], 2, 3, 5, Response),
        Outcome = ok(Response)
    ).

always_error_transport(_, _, error(provider_error{kind:temporary,
                                                   message:"still failing"})) :-
    next_attempt(_).

structured_retry_transport(_, _, ok(Response)) :-
    next_attempt(Attempt),
    (   Attempt =:= 1
    ->  response("not-json", [], 1, 1, 2, Response)
    ;   response("{\"answer\":\"ok\"}", [], 2, 3, 5, Response)
    ).

record_sleep(Delay) :- assertz(sleep_seen(Delay)).

request_middleware_one(_, Request0, Request) :-
    assertz(middleware_seen(request_one)),
    put_dict(first, Request0.options, true, Options),
    put_dict(options, Request0, Options, Request).

request_middleware_two(_, Request0, Request) :-
    assertz(middleware_seen(request_two)),
    put_dict(second, Request0.options, true, Options),
    put_dict(options, Request0, Options, Request).

response_middleware(_, Response0, Response) :-
    assertz(middleware_seen(response)),
    put_dict(text, Response0, "after-response", Response).

middleware_transport(_, Request, ok(Response)) :-
    assertz(request_seen(Request)),
    response("before-response", [], 1, 1, 2, Response).

failing_middleware(_, _, _) :-
    assertz(middleware_seen(failed)),
    fail.

must_not_run_transport(_, _, _) :-
    next_attempt(_),
    throw(error(unexpected_transport_call, _)).

tool_transport(_, _, ok(Response)) :-
    Calls = [tool_call{id:"call-1",
                       type:function,
                       function:_{name:"lookup", arguments:"{}"}}],
    response("", Calls, 1, 1, 2, Response).

tool_call_middleware(_, Call0, Call) :-
    assertz(middleware_seen(tool_call)),
    put_dict(reviewed, Call0, true, Call).

response(Text, ToolCalls, Prompt, Completion, Total,
         model_response{text:Text,
                        tool_calls:ToolCalls,
                        usage:usage{present:true,
                                    prompt_tokens:Prompt,
                                    completion_tokens:Completion,
                                    total_tokens:Total,
                                    cost:0.0}}).

record_stream_event(Event) :- assertz(stream_event_seen(Event)).

event_type(Event, Type) :- Type = Event.type.

trace_types(Events, Types) :- maplist(event_type, Events, Types).

trace_sequences_contiguous(Events) :-
    findall(Sequence,
            (member(Event, Events), Sequence = Event.sequence),
            Sequences),
    length(Sequences, Count),
    numlist(1, Count, Sequences).

:- end_tests(rlm_chain_runtime).
