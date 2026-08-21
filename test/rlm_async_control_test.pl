:- begin_tests(rlm_async_control).

:- use_module('../prolog/rlm_async').

throw_time_limit(_) :-
    throw(time_limit_exceeded).

throw_rlm_cancelled(_) :-
    throw(rlm_cancelled(async_control_token)).

throw_ordinary(_) :-
    throw(error(async_control_boom,
                context(rlm_async_control_test, ordinary))).

test(time_limit_survives_future_boundary,
     [throws(time_limit_exceeded)]) :-
    setup_call_cleanup(
        rlm_async_submit(plunit_rlm_async_control:throw_time_limit, Future),
        rlm_future_await(Future, _),
        rlm_future_destroy(Future)).

test(rlm_cancellation_survives_future_boundary,
     [throws(rlm_cancelled(async_control_token))]) :-
    setup_call_cleanup(
        rlm_async_submit(plunit_rlm_async_control:throw_rlm_cancelled, Future),
        rlm_future_await(Future, _),
        rlm_future_destroy(Future)).

test(ordinary_exception_remains_structured) :-
    setup_call_cleanup(
        rlm_async_submit(plunit_rlm_async_control:throw_ordinary, Future),
        ( rlm_future_await(Future, Outcome),
          Outcome = error(Error),
          assertion(Error.kind == exception),
          assertion(string(Error.exception)),
          assertion(\+ get_dict(exception_term, Error, _))
        ),
        rlm_future_destroy(Future)).

:- end_tests(rlm_async_control).
