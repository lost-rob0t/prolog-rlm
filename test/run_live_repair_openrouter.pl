:- initialization(main, main).

:- use_module(library(plunit)).
:- consult(live_repair_openrouter_test).

main(_) :-
    (   run_tests([live_repair_openrouter])
    ->  halt(0)
    ;   halt(1)
    ).
