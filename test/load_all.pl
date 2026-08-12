:- initialization(main, main).

:- use_module('../prolog/rlm').

main(_) :-
    (   rlm:rlm_ready
    ->  halt(0)
    ;   halt(1)
    ).
