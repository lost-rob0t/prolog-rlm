:- initialization(main, main).

:- use_module('../prolog/rlm_effect').
:- use_module(library(readutil)).

main([Ledger]) :-
    rlm_effect:rlm_effect_store_open(Ledger),
    writeln(owner_ready),
    flush_output,
    read_line_to_string(user_input, _),
    rlm_effect:rlm_effect_store_close,
    halt(0).
main(_) :-
    halt(2).
