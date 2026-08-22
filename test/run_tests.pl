:- set_prolog_flag(on_error, status).
:- initialization(main, main).

:- use_module('deterministic_corpus.pl',
              [ aggregate_load_succeeded/0,
                aggregate_suites/1,
                load_aggregate_files/0,
                validate_inventory/0
              ]).
:- use_module('deterministic_runner.pl', [run/1]).

:- load_aggregate_files.

main(_) :-
    (   aggregate_load_succeeded,
        validate_inventory,
        aggregate_suites(Suites),
        deterministic_runner:run(Suites)
    ->  halt(0)
    ;   halt(1)
    ).
