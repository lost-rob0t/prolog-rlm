:- initialization(main, main).

:- use_module('../prolog/rlm_effect').

main([Ledger, blocked]) :-
    !,
    catch(rlm_effect:rlm_effect_store_open(Ledger),
          Error,
          blocked_outcome(Error)),
    (   rlm_effect:rlm_effect_store_attached(_)
    ->  rlm_effect:rlm_effect_store_close,
        halt(1)
    ;   halt(0)
    ).
main([Ledger, open]) :-
    !,
    catch(rlm_effect:rlm_effect_store_open(Ledger), _, halt(1)),
    rlm_effect:rlm_effect_store_close,
    halt(0).
main(_) :-
    halt(2).

blocked_outcome(error(permission_error(lock, effect_store, _), _)) :- !.
blocked_outcome(_) :- halt(1).
