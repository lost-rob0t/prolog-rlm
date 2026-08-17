:- initialization(main, main).

:- use_module('../prolog/rlm_effect').
:- use_module(effect_restart_support).

main(Args) :-
    (   Args = [Ledger, Remote]
    ->  ( completed_phase_two(Ledger, Remote) -> halt(0) ; halt(1) )
    ;   halt(2)
    ).

completed_phase_two(Ledger, Remote) :-
    rlm_effect_store_open(Ledger),
    crash_request(Request),
    assert_remote_count(Remote, 1),
    rlm_effect_prepare(model, Request,
                       _{logical_key:completed_restart_fixture},
                       replay(Observation)),
    Observation.status == succeeded,
    Observation.provenance == fake_remote_completed,
    assert_remote_count(Remote, 1),
    rlm_effect_store_close.
