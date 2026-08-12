:- initialization(main, main).

:- use_module(library(plunit)).
:- consult(bootstrap_test).

main(_) :-
    (   run_tests
    ->  halt(0)
    ;   halt(1)
    ).
