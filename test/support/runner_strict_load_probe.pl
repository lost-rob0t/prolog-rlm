:- set_prolog_flag(on_error, status).
:- initialization(main, main).

:- use_module(library(plunit)).
:- use_module('../deterministic_corpus.pl').

main(_) :-
    deterministic_corpus:load_corpus_files([
        'support/runner_load_error_suite.pl',
        'support/runner_load_error_after.pl'
    ]),
    (   deterministic_corpus:aggregate_load_succeeded
    ->  halt(0)
    ;   halt(1)
    ).
