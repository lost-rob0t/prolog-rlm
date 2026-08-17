:- initialization(main, main).

:- use_module('../prolog/rlm_effect').
:- use_module('../prolog/rlm_effect_executor').
:- use_module('../prolog/rlm_effect_persist').

main([CaseAtom, Ledger, StateFile, RemoteFile]) :-
    Case = CaseAtom,
    rlm_effect_store_open(Ledger),
    Request = request{operation:projection_crash,case:Case},
    effect_prepare(projection_adapter, tool, Request, _{}, execute(Ticket)),
    Authority = authority_ref{source:projection_fixture,tier:dangerous},
    rlm_effect_admit(Ticket, Authority, execute(Attempt)),
    get_dict(attempt_id, Attempt, AttemptId),
    rlm_effect_dispatch(AttemptId, dispatch(Dispatching)),
    write_term_file(RemoteFile, remote_state{submit_count:1}),
    Observation = observation{status:succeeded,
                              value:projection_result,
                              usage:usage{units:1},
                              provenance:projection_adapter},
    rlm_effect_persist:effect_persist_put_observation(AttemptId, Observation),
    finish_case(Case, Dispatching),
    get_dict(call_id, Ticket, CallId),
    write_term_file(StateFile,
                    projection_state{attempt_id:AttemptId,call_id:CallId,
                                     observation:Observation}),
    format('projection_boundary_durable~n', []),
    flush_output,
    read_line_to_string(user_input, _),
    halt(3).
main(_) :-
    halt(2).

finish_case(observation_only, _).
finish_case(attempt_observed, Dispatching) :-
    get_dict(revision, Dispatching, Revision0),
    Revision is Revision0+1,
    get_time(Now),
    Updated = Dispatching.put(_{revision:Revision,status:observed,
                                updated_at:Now}),
    rlm_effect_persist:effect_persist_put_attempt(Updated).

write_term_file(File, Term) :-
    setup_call_cleanup(
        open(File, write, Stream, [encoding(utf8)]),
        ( write_term(Stream, Term, [quoted(true),fullstop(true),nl(true)]),
          flush_output(Stream) ),
        close(Stream)).
