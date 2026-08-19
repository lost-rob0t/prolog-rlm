:- initialization(main, main).

:- use_module(library(plunit)).
:- consult(rlm_tree_sitter_test).
:- consult(rlm_project_source_native_test).

main(_) :-
    (   run_tests([rlm_tree_sitter, rlm_project_source_native])
    ->  halt(0)
    ;   halt(1)
    ).
