:- initialization(main, main).

main(_) :-
    current_prolog_flag(version_data, swi(Major, Minor, Patch, _)),
    format('SWI-Prolog runtime: ~d.~d.~d~n', [Major, Minor, Patch]),
    (   supported_version(Major, Minor)
    ->  halt(0)
    ;   format(user_error,
               'ERROR: prolog-rlm requires SWI-Prolog 9.0 or newer~n',
               []),
        halt(1)
    ).

supported_version(Major, _) :-
    Major > 9,
    !.
supported_version(9, Minor) :-
    Minor >= 0.
