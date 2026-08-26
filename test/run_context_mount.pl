:- set_prolog_flag(on_error, status).
:- initialization(main, main).

:- consult('support/rlm_context_mount_test.pl').

main(_) :-
    (   run_tests([rlm_context_mount])
    ->  halt(0)
    ;   halt(1)
    ).
