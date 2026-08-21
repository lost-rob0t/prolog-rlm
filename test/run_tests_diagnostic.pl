:- use_module(library(plunit)).
:- use_module(library(time)).

:- consult(run_tests).

:- initialization(diagnostic_main, main).

diagnostic_main(_) :-
    findall(Unit, plunit:current_test_unit(Unit, _), Units0),
    sort(Units0, Units),
    length(Units, UnitCount),
    format(user_error, 'diagnostic_unit_count=~d~n', [UnitCount]),
    flush_output(user_error),
    (   forall(member(Unit, Units), run_unit_bounded(Unit))
    ->  halt(0)
    ;   halt(1)
    ).

run_unit_bounded(Unit) :-
    format(user_error, 'diagnostic_unit_start=~w~n', [Unit]),
    flush_output(user_error),
    (   catch(call_with_time_limit(20, run_tests(Unit)),
              Exception,
              diagnostic_exception(Unit, Exception))
    ->  format(user_error, 'diagnostic_unit_done=~w~n', [Unit]),
        flush_output(user_error)
    ;   format(user_error, 'diagnostic_unit_failed=~w~n', [Unit]),
        flush_output(user_error),
        fail
    ).

diagnostic_exception(Unit, time_limit_exceeded) :-
    format(user_error, 'diagnostic_unit_timeout=~w~n', [Unit]),
    flush_output(user_error),
    fail.
diagnostic_exception(Unit, Exception) :-
    format(user_error,
           'diagnostic_unit_exception=~w exception=~q~n',
           [Unit, Exception]),
    flush_output(user_error),
    fail.
