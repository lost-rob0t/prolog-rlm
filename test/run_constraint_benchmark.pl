:- set_prolog_flag(on_error, status).
:- initialization(main, main).

:- consult('support/rlm_constraint_benchmark_test.pl').

main(_) :-
    (   run_tests([rlm_constraint_benchmark])
    ->  halt(0)
    ;   halt(1)
    ).
