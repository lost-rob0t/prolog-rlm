:- initialization(main, main).

:- use_module(library(plunit)).
:- consult(rlm_tree_sitter_test).

main(_) :-
    (   run_tests(rlm_tree_sitter)
    ->  halt(0)
    ;   halt(1)
    ).
