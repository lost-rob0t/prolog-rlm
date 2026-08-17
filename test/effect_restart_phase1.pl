:- initialization(main, main).

:- use_module('../prolog/rlm_effect').
:- use_module(effect_restart_support).

main(Args) :-
    (   Args = [Ledger, Remote]
    ->  crash_window_phase_one(Ledger, Remote)
    ;   format(user_error,
               'usage: effect_restart_phase1.pl LEDGER REMOTE~n', []),
        halt(2)
    ).

crash_window_phase_one(Ledger, Remote) :-
    rlm_effect_store_open(Ledger),
    crash_request(Request),
    rlm_effect_prepare(model, Request,
                       _{logical_key:restart_fixture},
                       execute(Ticket)),
    rlm_effect_admit(Ticket,
                     authority_ref{source:fixture,tier:dangerous},
                     execute(Attempt)),
    rlm_effect_dispatch(Attempt.attempt_id, dispatch(Dispatch)),
    remote_submit(Remote, Dispatch.idempotency_key, _RemoteResult),
    % Deliberately do not call rlm_effect_observe/3 and do not close the store.
    % The external state exists while the local attempt has only the durable
    % pre-dispatch/dispatch facts.  Exit with a sentinel code so CI proves this
    % was the intended crash injection rather than a test failure.
    halt(86).
