:- initialization(main, main).

:- use_module('../prolog/rlm_effect').
:- use_module(effect_restart_support).

main(Args) :-
    (   Args = [Ledger, Remote]
    ->  ( crash_window_indeterminate(Ledger, Remote)
        -> halt(0)
        ;  halt(1) )
    ;   format(user_error,
               'usage: effect_restart_phase2_indeterminate.pl LEDGER REMOTE~n', []),
        halt(2)
    ).

crash_window_indeterminate(Ledger, Remote) :-
    rlm_effect_store_open(Ledger),
    crash_request(Request),
    rlm_effect_prepare(model, Request,
                       _{logical_key:restart_fixture},
                       Decision),
    Decision = reconciliation_required(Attempt),
    Attempt.status == dispatching,
    assert_remote_count(Remote, 1),
    rlm_effect_mark_indeterminate(Attempt.attempt_id,
                                  provider_has_no_reconciliation_api,
                                  indeterminate(Unknown)),
    Unknown.status == indeterminate,
    rlm_effect_prepare(model, Request,
                       _{logical_key:restart_fixture},
                       StillUnknown),
    StillUnknown = reconciliation_required(UnknownAgain),
    UnknownAgain.status == indeterminate,
    rlm_effect_prepare(model, Request,
                       _{logical_key:restart_fixture,
                         mode:retry,
                         parent_attempt:Attempt.attempt_id},
                       Retry),
    Retry = error(RetryError),
    RetryError.kind == indeterminate_requires_resolution,
    assert_remote_count(Remote, 1),
    rlm_effect_store_close.
