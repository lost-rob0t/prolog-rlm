:- set_prolog_flag(on_error, status).
:- initialization(main, main).

:- use_module(library(plunit)).
:- consult('support/runner_integrity_test.pl').

main(_) :-
    run_tests([runner_integrity], [summary(Summary)]),
    get_dict(failed, Summary, Failed),
    get_dict(timeout, Summary, Timeout),
    get_dict(blocked, Summary, Blocked),
    get_dict(fixme, Summary, Fixme),
    (   Failed =:= 0,
        Timeout =:= 0,
        Blocked =:= 0,
        Fixme =:= 0
    ->  halt(0)
    ;   halt(1)
    ).
