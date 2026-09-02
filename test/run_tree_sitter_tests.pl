:- initialization(main, main).

:- use_module(library(plunit)).
:- consult(rlm_tree_sitter_test).
:- consult(rlm_project_source_native_test).
:- consult(rlm_project_syntax_test).
:- consult(rlm_tree_sitter_query_test).
:- consult(rlm_project_query_test).
:- consult(rlm_project_query_restart_test).
:- consult(rlm_tree_sitter_cancellation_test).

main(_) :-
    (   run_tests([rlm_tree_sitter,
                   rlm_project_source_native,
                   rlm_project_syntax,
                   rlm_tree_sitter_query,
                   rlm_project_query,
                   rlm_project_query_restart,
                   rlm_tree_sitter_cancellation])
    ->  halt(0)
    ;   halt(1)
    ).
