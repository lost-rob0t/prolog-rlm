:- set_prolog_flag(on_error, status).
:- initialization(main, main).

:- use_module('../deterministic_corpus.pl').

main(_) :-
    deterministic_corpus:load_corpus_files([
        'support/runner_hostile_main.pl'
    ]),
    (   deterministic_corpus:aggregate_load_succeeded
    ->  halt(1)
    ;   halt(0)
    ).
