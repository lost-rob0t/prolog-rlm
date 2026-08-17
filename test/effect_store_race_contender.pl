:- initialization(main, main).

:- use_module('../prolog/rlm_effect').
:- use_module(library(readutil)).

main([Ledger]) :-
    writeln(ready),
    flush_output,
    read_line_to_string(user_input, "go"),
    !,
    race_open(Ledger).
main(_) :-
    halt(2).

race_open(Ledger) :-
    catch(rlm_effect:rlm_effect_store_open(Ledger),
          Error,
          race_open_error(Error)),
    writeln(acquired),
    flush_output,
    read_line_to_string(user_input, _),
    rlm_effect:rlm_effect_store_close,
    halt(0).

race_open_error(error(permission_error(lock, effect_store, _), _)) :-
    !,
    writeln(blocked),
    flush_output,
    halt(0).
race_open_error(_) :-
    halt(1).
