:- initialization(main, main).

:- use_module(library(plunit)).
:- consult(runner_load_error_suite).
:- consult(runner_load_error_after).

main(_) :-
    (   run_tests([runner_load_error_suite])
    ->  halt(0)
    ;   halt(1)
    ).
