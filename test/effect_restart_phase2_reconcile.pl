:- initialization(main, main).

:- use_module('../prolog/rlm_effect').
:- use_module(effect_restart_support).

main(Args) :-
    (   Args = [Ledger, Remote]
    ->  ( crash_window_reconcile(Ledger, Remote)
        -> halt(0)
        ;  halt(1) )
    ;   format(user_error,
               'usage: effect_restart_phase2_reconcile.pl LEDGER REMOTE~n', []),
        halt(2)
    ).

crash_window_reconcile(Ledger, Remote) :-
    rlm_effect_store_open(Ledger),
    crash_request(Request),
    rlm_effect_prepare(model, Request,
                       _{logical_key:restart_fixture},
                       Decision),
    Decision = reconciliation_required(Attempt),
    Attempt.status == dispatching,
    assert_remote_count(Remote, 1),
    remote_read(Remote, RemoteState),
    RemoteState.idempotency_key == Attempt.idempotency_key,
    Observation = observation{status:succeeded,
                              value:RemoteState.result,
                              usage:usage{units:1},
                              provenance:fake_remote_reconciliation},
    rlm_effect_reconcile(Attempt.attempt_id, Observation,
                         reconciled(Recovered)),
    Recovered.value == RemoteState.result,
    rlm_effect_prepare(model, Request,
                       _{logical_key:restart_fixture},
                       replay(Replay)),
    Replay == Recovered,
    assert_remote_count(Remote, 1),
    rlm_effect_store_close.
