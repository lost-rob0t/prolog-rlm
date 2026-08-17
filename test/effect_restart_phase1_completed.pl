:- initialization(main, main).

:- use_module('../prolog/rlm_effect').
:- use_module(effect_restart_support).

main(Args) :-
    (   Args = [Ledger, Remote]
    ->  ( completed_phase_one(Ledger, Remote) -> halt(0) ; halt(1) )
    ;   halt(2)
    ).

completed_phase_one(Ledger, Remote) :-
    rlm_effect_store_open(Ledger),
    crash_request(Request),
    rlm_effect_prepare(model, Request,
                       _{logical_key:completed_restart_fixture},
                       execute(Ticket)),
    rlm_effect_admit(Ticket,
                     authority_ref{source:fixture,tier:dangerous},
                     execute(Attempt)),
    rlm_effect_dispatch(Attempt.attempt_id, dispatch(Dispatch)),
    remote_submit(Remote, Dispatch.idempotency_key, RemoteResult),
    Observation = observation{status:succeeded,
                              value:RemoteResult,
                              usage:usage{units:1},
                              provenance:fake_remote_completed},
    rlm_effect_observe(Attempt.attempt_id, Observation, observed(Observation)),
    rlm_effect_store_close.
