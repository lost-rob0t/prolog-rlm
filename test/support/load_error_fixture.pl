:- module(load_error_fixture,
          [ load_error_fixture_ready/0
          ]).

load_error_fixture_fail :-
    throw(error(load_error_fixture,
                context(load_error_fixture,
                        'intentional compile/load error fixture'))).

:- initialization(load_error_fixture_fail, now).

load_error_fixture_ready.
