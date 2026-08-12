:- initialization(main, main).

:- use_module(library(plunit)).
:- consult(bootstrap_test).
:- consult(rlm_chain_test).

main(_) :-
    (   run_tests
    ->  halt(0)
    ;   halt(1)
    ).
