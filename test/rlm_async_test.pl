:- begin_tests(rlm_async).

:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_completion').
:- use_module('../prolog/rlm_completion_async', []).
:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_tool_async').
:- use_module('../prolog/rlm', []).
:- use_module('support/completion_test_support').

async_value(Value, Value).

async_sleep(Seconds, Value, Value) :-
    sleep(Seconds).

async_boom(_) :-
    throw(error(test_async_boom,
                context(rlm_async_test, boom))).

async_echo(Args, Value) :-
    Value = Args.value.

async_echo_schema(
    tool_schema{
        name:async_echo,
        description:"Echo one integer through the async tool facade",
        capability:tool(async_echo),
        arguments:_{
            type:object,
            required:[value],
            additional_properties:false,
            properties:_{value:_{type:integer}}
        },
        result:_{type:integer},
        limits:tool_limits{
            time_limit:1.0,
            max_output_bytes:1024
        }
    }).

test(submit_await_preserves_plain_result_shape) :-
    setup_call_cleanup(
        rlm_async_submit(async_value(answer(42)), Future),
        ( rlm_future_await(Future, Outcome),
          assertion(Outcome == answer(42)),
          rlm_future_status(Future, Status),
          assertion(Status.state == completed),
          assertion(Status.outcome == answer(42))
        ),
        rlm_future_destroy(Future)).

test(timeout_does_not_cancel_future) :-
    setup_call_cleanup(
        rlm_async_submit(async_sleep(0.05, done), Future),
        ( rlm_future_await(Future, 0.001, TimeoutOutcome),
          TimeoutOutcome = error(Error),
          assertion(Error.kind == timeout),
          rlm_future_await(Future, 1.0, Outcome),
          assertion(Outcome == done)
        ),
        rlm_future_destroy(Future)).

test(cancel_interrupts_pending_future) :-
    setup_call_cleanup(
        rlm_async_submit(async_sleep(1.0, never), Future),
        ( rlm_future_cancel(Future, CancelOutcome),
          assertion(CancelOutcome == ok(cancelled)),
          rlm_future_await(Future, Outcome),
          Outcome = error(Error),
          assertion(Error.kind == cancelled),
          rlm_future_status(Future, Status),
          assertion(Status.state == cancelled)
        ),
        rlm_future_destroy(Future)).

test(exception_is_structured) :-
    setup_call_cleanup(
        rlm_async_submit(async_boom, Future),
        ( rlm_future_await(Future, Outcome),
          Outcome = error(Error),
          assertion(Error.kind == exception),
          assertion(string(Error.exception))
        ),
        rlm_future_destroy(Future)).

test(future_all_composes_already_running_work) :-
    setup_call_cleanup(
        ( rlm_async_submit(async_sleep(0.02, first), First),
          rlm_async_submit(async_sleep(0.01, second), Second)
        ),
        ( rlm_future_all([First, Second], Outcomes),
          assertion(Outcomes == [first, second])
        ),
        ( rlm_future_destroy(First),
          rlm_future_destroy(Second)
        )).

test(llm_query_async_preserves_sync_outcome_shape,
     [setup(completion_test_support:reset_calls)]) :-
    Options = [model_handler(completion_test_support:fake_model)],
    llm_query_async("hello", Options, Future),
    setup_call_cleanup(
        true,
        ( rlm_future_await(Future, 2.0, AsyncOutcome),
          AsyncOutcome = ok(Result),
          assertion(Result.response.text == "FAKE_MODEL_OK"),
          assertion(Result.usage.model_calls =:= 1),
          assertion(\+ (AsyncOutcome = ok(ok(_))))
        ),
        rlm_future_destroy(Future)).

test(completion_async_runs_existing_completion_logic,
     [setup(completion_test_support:reset_calls)]) :-
    Options = [ planner_handler(completion_test_support:direct_planner),
                capabilities([rlm, model(openrouter)]),
                child_capabilities([rlm, model(openrouter)])
              ],
    rlm_completion_async("return directly",
                         text("opaque context body"),
                         Options,
                         Future),
    setup_call_cleanup(
        true,
        ( rlm_future_await(Future, 2.0, Outcome),
          Outcome = ok(Result),
          assertion(Result.value == "direct-ok"),
          assertion(Result.recursion.recursive_calls =:= 0)
        ),
        rlm_future_destroy(Future)).

test(public_completion_async_preserves_sync_recursion_gate,
     [setup(completion_test_support:reset_calls)]) :-
    Options = [ planner_handler(completion_test_support:depth_two_planner),
                capabilities([rlm, model(openrouter)]),
                child_capabilities([rlm, model(openrouter)]),
                budget(_{max_recursion_depth:2})
              ],
    rlm:rlm_completion_async("too deep for public facade",
                             text("ctx"),
                             Options,
                             Future),
    setup_call_cleanup(
        true,
        ( rlm_future_await(Future, 2.0, Outcome),
          Outcome = error(Error),
          assertion(Error.kind == experimental_deep_recursion_required),
          completion_test_support:planner_calls(Calls),
          assertion(Calls =:= 0)
        ),
        rlm_future_destroy(Future)).

test(tool_invoke_async_preserves_outcome_and_trace) :-
    tool_registry_create(Registry),
    setup_call_cleanup(
        ( async_echo_schema(Schema),
          tool_register(Registry,
                        Schema,
                        plunit_rlm_async:async_echo,
                        ok(_))
        ),
        ( tool_invoke_async(Registry,
                            [tool(async_echo)],
                            async_echo,
                            json{value:17},
                            [],
                            Future),
          setup_call_cleanup(
              true,
              ( rlm_future_await(Future, 2.0, Result),
                Result.outcome = ok(Execution),
                assertion(Execution.value =:= 17),
                assertion(Result.trace.authorization == allowed),
                assertion(Result.trace.status == ok)
              ),
              rlm_future_destroy(Future))
        ),
        tool_registry_destroy(Registry)).

:- end_tests(rlm_async).
