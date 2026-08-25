:- begin_tests(rlm_chain_control).

:- use_module('../prolog/rlm_chain_runtime',
              [ chain_invoke_with_transport/5,
                chain_stream_with_transport/6
              ]).

base_request(model_request{
                 messages:[message{role:user, content:"hello"}],
                 options:_{temperature:0}
             }).

test(internal_runtime_canonicalizes_untagged_generation_options) :-
    base_request(Request),
    chain_invoke_with_transport(provider(test, []),
                                Request,
                                [],
                                plunit_rlm_chain_control:ok_transport,
                                ok(Result)),
    assertion(Result.request.options.temperature =:= 0),
    assertion(ground(Result.request.options)).

test(request_trace_reports_actual_message_count) :-
    base_request(Request),
    chain_invoke_with_transport(provider(test, []),
                                Request,
                                [],
                                plunit_rlm_chain_control:ok_transport,
                                ok(Result)),
    Result.trace = [First|_],
    assertion(First.type == request_normalized),
    assertion(First.fields.message_count =:= 1).

test(stream_time_limit_exception_is_not_wrapped) :-
    base_request(Request),
    catch(chain_stream_with_transport(provider(test, []),
                                      Request,
                                      [],
                                      plunit_rlm_chain_control:time_limit_stream,
                                      plunit_rlm_chain_control:accept_event,
                                      _),
          Exception,
          true),
    assertion(Exception == time_limit_exceeded).

test(stream_cancellation_exception_is_not_wrapped,
     [throws(error(rlm_cancelled(test_token), test_context))]) :-
    base_request(Request),
    chain_stream_with_transport(provider(test, []),
                                Request,
                                [],
                                plunit_rlm_chain_control:cancelled_stream,
                                plunit_rlm_chain_control:accept_event,
                                _).

ok_transport(_, _, ok(Response)) :-
    Response = model_response{
                   text:"ok",
                   tool_calls:[],
                   usage:usage{present:true,
                               prompt_tokens:1,
                               completion_tokens:1,
                               total_tokens:2,
                               cost:0.0}
               }.

time_limit_stream(_, _, _, _) :-
    throw(time_limit_exceeded).

cancelled_stream(_, _, _, _) :-
    throw(error(rlm_cancelled(test_token), test_context)).

accept_event(_).

:- end_tests(rlm_chain_control).
