:- use_module(library(plunit)).
:- use_module(library(time)).

:- consult(run_tests).

:- dynamic diagnostic_failure/2.

:- initialization(diagnostic_main, main).

diagnostic_main :-
    retractall(diagnostic_failure(_, _)),
    findall(Unit, plunit:current_test_unit(Unit, _), Units),
    length(Units, UnitCount),
    format(user_error, 'diagnostic_unit_count=~d~n', [UnitCount]),
    flush_output(user_error),
    (   forall(member(Unit, Units), run_unit_bounded(Unit))
    ->  findall(Unit-Result, diagnostic_failure(Unit, Result), Failures),
        format(user_error, 'diagnostic_failures=~q~n', [Failures]),
        flush_output(user_error),
        ( Failures == [] -> halt(0) ; halt(1) )
    ;   halt(1)
    ).

run_unit_bounded(Unit) :-
    format(user_error, 'diagnostic_unit_start=~w~n', [Unit]),
    flush_output(user_error),
    unit_result(Unit, Result),
    report_unit_result(Unit, Result),
    Result \== timeout.

unit_result(Unit, Result) :-
    catch(( call_with_time_limit(20, run_tests(Unit))
          -> Result = pass
          ;  Result = failed
          ),
          Exception,
          diagnostic_exception_result(Exception, Result)).

diagnostic_exception_result(time_limit_exceeded, timeout) :- !.
diagnostic_exception_result(Exception, exception(Exception)).

report_unit_result(Unit, pass) :-
    !,
    format(user_error, 'diagnostic_unit_done=~w~n', [Unit]),
    flush_output(user_error).
report_unit_result(Unit, timeout) :-
    !,
    assertz(diagnostic_failure(Unit, timeout)),
    format(user_error, 'diagnostic_unit_timeout=~w~n', [Unit]),
    flush_output(user_error).
report_unit_result(Unit, Result) :-
    assertz(diagnostic_failure(Unit, Result)),
    format(user_error,
           'diagnostic_unit_failed=~w result=~q~n',
           [Unit, Result]),
    flush_output(user_error).
