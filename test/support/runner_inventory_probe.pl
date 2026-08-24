:- set_prolog_flag(on_error, status).
:- initialization(main, main).

:- use_module('../deterministic_corpus.pl').

main(_) :-
    (   catch(deterministic_corpus:validate_candidate_file(
                  'new_unregistered_test.pl'),
              _,
              fail)
    ->  halt(1)
    ;   halt(0)
    ).
