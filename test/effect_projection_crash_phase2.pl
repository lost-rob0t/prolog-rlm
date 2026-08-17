:- initialization(main, main).

:- use_module('../prolog/rlm_effect').
:- use_module('../prolog/rlm_effect_executor').

:- multifile rlm_effect_executor:effect_adapter_reconcile/4.

rlm_effect_executor:effect_adapter_reconcile(projection_adapter, _, _, _) :-
    throw(projection_reconcile_callback_must_not_run).

main([Ledger, StateFile, RemoteFile]) :-
    read_term_file(StateFile, State),
    read_term_file(RemoteFile, Remote),
    Remote.submit_count =:= 1,
    rlm_effect_store_open(Ledger),
    AttemptId = State.attempt_id,
    effect_reconcile(projection_adapter, AttemptId, First),
    First.state == observed,
    First.source == local_observation,
    First.observation == State.observation,
    rlm_effect_status(AttemptId, Attempt),
    Attempt.status == observed,
    rlm_effect_history(State.call_id, Events1),
    rlm_effect_history(State.call_id, Events2),
    effect_reconcile(projection_adapter, AttemptId, Second),
    Second.state == observed,
    Second.source == local_observation,
    exactly_one_observation_event(Events1),
    exactly_one_observation_event(Events2),
    read_term_file(RemoteFile, RemoteAfter),
    RemoteAfter.submit_count =:= 1,
    rlm_effect_store_close,
    halt(0).
main(_) :-
    halt(2).

exactly_one_observation_event(Events) :-
    findall(Event,
            ( member(Event, Events), Event.type == observation_recorded ),
            [_]).

read_term_file(File, Term) :-
    setup_call_cleanup(
        open(File, read, Stream, [encoding(utf8)]),
        read_term(Stream, Term, []),
        close(Stream)).
