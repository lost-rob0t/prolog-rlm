:- set_prolog_flag(on_error, status).
:- initialization(main, main).

:- use_module(library(plunit)).
:- consult('support/runner_integrity_test.pl').

main(_) :-
    (   run_tests([runner_integrity])
    ->  halt(0)
    ;   halt(1)
    ).
