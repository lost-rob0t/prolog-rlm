:- begin_tests(rlm_effect_hardening).

:- use_module('../prolog/rlm_effect').
:- use_module('../prolog/rlm_effect_executor').
:- use_module(library(filesex)).
:- use_module(library(process)).
:- use_module(library(readutil)).

:- dynamic hardening_seen_request/2.

:- multifile rlm_effect_executor:effect_adapter_submit/4.
:- multifile rlm_effect_executor:effect_adapter_reconcile/4.

rlm_effect_executor:effect_adapter_submit(hardening_capture, _, Request,
                                          indeterminate(force_reconcile)) :-
    plunit_rlm_effect_hardening:record_seen_request(submit, Request).

rlm_effect_executor:effect_adapter_reconcile(hardening_capture, _, Request,
                                             observed(Observation)) :-
    plunit_rlm_effect_hardening:record_seen_request(reconcile, Request),
    Observation = observation{status:succeeded,
                              value:result{request:Request},
                              usage:usage{units:1},
                              provenance:hardening_capture}.

record_seen_request(Phase, Request) :-
    assertz(hardening_seen_request(Phase, Request)).

authority_ref(authority_ref{source:hardening_test,tier:dangerous}).

setup_store(Ledger) :-
    tmp_file(rlm_effect_hardening, Ledger),
    rlm_effect_store_open(Ledger),
    retractall(hardening_seen_request(_, _)).

cleanup_store(Ledger) :-
    catch(rlm_effect_store_close, _, true),
    retractall(hardening_seen_request(_, _)),
    cleanup_store_files(Ledger).

with_store(Goal) :-
    setup_call_cleanup(setup_store(Ledger), Goal, cleanup_store(Ledger)).

cleanup_store_files(Ledger) :-
    atom_concat(Ledger, '.lock', LockFile),
    catch(delete_file(Ledger), _, true),
    catch(delete_file(LockFile), _, true).

error_kind(error(Error), Kind) :-
    is_dict(Error),
    Error.kind == Kind.

assert_ticket_identity_rejected(Ticket) :-
    authority_ref(Authority),
    rlm_effect_admit(Ticket, Authority, Outcome),
    assertion(error_kind(Outcome, invalid_ticket_identity)).

test(raw_ticket_forged_fingerprint_rejected) :-
    with_store(
        ( rlm_effect_prepare(tool, request{target:alpha}, _{}, execute(Ticket)),
          Forged = Ticket.put(fingerprint, 'sha256:forged'),
          assert_ticket_identity_rejected(Forged)
        )).

test(raw_ticket_forged_attempt_id_rejected) :-
    with_store(
        ( rlm_effect_prepare(tool, request{target:alpha}, _{}, execute(Ticket)),
          Forged = Ticket.put(attempt_id, 'effect-attempt:forged'),
          assert_ticket_identity_rejected(Forged)
        )).

test(raw_ticket_forged_sequence_rejected) :-
    with_store(
        ( rlm_effect_prepare(tool, request{target:alpha}, _{}, execute(Ticket)),
          Forged = Ticket.put(sequence, 2),
          assert_ticket_identity_rejected(Forged)
        )).

test(raw_ticket_forged_parent_rejected) :-
    with_store(
        ( rlm_effect_prepare(tool, request{target:alpha}, _{}, execute(Ticket)),
          Forged = Ticket.put(parent_attempt, 'effect-attempt:forged-parent'),
          assert_ticket_identity_rejected(Forged)
        )).

test(raw_ticket_forged_idempotency_key_rejected) :-
    with_store(
        ( rlm_effect_prepare(tool, request{target:alpha}, _{}, execute(Ticket)),
          Forged = Ticket.put(idempotency_key, 'rlm-effect:forged'),
          assert_ticket_identity_rejected(Forged)
        )).

test(raw_ticket_changed_request_with_stale_identity_rejected) :-
    with_store(
        ( rlm_effect_prepare(tool, request{target:alpha}, _{}, execute(Ticket)),
          Forged = Ticket.put(request, request{target:beta}),
          assert_ticket_identity_rejected(Forged)
        )).

test(raw_ticket_constructor_produced_ticket_is_admitted) :-
    with_store(
        ( rlm_effect_prepare(tool, request{target:alpha}, _{}, execute(Ticket)),
          authority_ref(Authority),
          rlm_effect_admit(Ticket, Authority, execute(Attempt)),
          assertion(Attempt.attempt_id == Ticket.attempt_id),
          assertion(Attempt.fingerprint == Ticket.fingerprint)
        )).

test(adapter_submit_and_reconcile_share_canonical_request) :-
    with_store(
        ( dict_create(Payload, payload, [z-3,a-1,nested-nested{b:2,a:1}]),
          dict_create(Request, request,
                      [payload-Payload,operation-normalized_contract]),
          effect_prepare(hardening_capture, tool, Request, _{},
                         execute(Ticket)),
          Expected = Ticket.request,
          authority_ref(Authority),
          effect_execute(hardening_capture, tool, Request, _{}, Authority, First),
          assertion(First.state == indeterminate),
          effect_execute(hardening_capture, tool, Request, _{}, Authority, Second),
          assertion(Second.state == observed),
          hardening_seen_request(submit, SubmitRequest),
          hardening_seen_request(reconcile, ReconcileRequest),
          assertion(SubmitRequest == Expected),
          assertion(ReconcileRequest == Expected),
          assertion(SubmitRequest == ReconcileRequest)
        )).

test(normalization_preserves_semantics_bearing_values) :-
    with_store(
        ( Request = request{operation:preserve,
                            payload:payload{number:42,
                                            ratio:0.75,
                                            text:"alpha",
                                            atom:beta,
                                            list:[1,two,"three"],
                                            compound:choice(left,right)}},
          Options = _{semantics:semantics{temperature:0.25,
                                          seed:7,
                                          stop:["END"]}},
          rlm_effect_prepare(model, Request, Options, execute(Ticket)),
          assertion(Ticket.request.payload.number =:= 42),
          assertion(Ticket.request.payload.ratio =:= 0.75),
          assertion(Ticket.request.payload.text == "alpha"),
          assertion(Ticket.request.payload.atom == beta),
          assertion(Ticket.request.payload.list == [1,two,"three"]),
          assertion(Ticket.request.payload.compound == choice(left,right)),
          rlm_effect_prepare(model, Request,
                             _{semantics:semantics{stop:["END"],seed:7,
                                                    temperature:0.25}},
                             execute(Equivalent)),
          assertion(Equivalent.fingerprint == Ticket.fingerprint),
          assertion(Equivalent.attempt_id == Ticket.attempt_id)
        )).

test(store_normal_close_releases_writer_lock) :-
    fresh_store_path(normal_close, Ledger),
    setup_call_cleanup(
        true,
        ( rlm_effect_store_open(Ledger),
          rlm_effect_store_close,
          run_contender(Ledger, open, Status),
          assertion(Status == exit(0)) ),
        cleanup_store_files(Ledger)).

test(store_repeated_open_same_process_is_idempotent) :-
    fresh_store_path(repeated_open, Ledger),
    setup_call_cleanup(
        true,
        ( rlm_effect_store_open(Ledger),
          absolute_file_name(Ledger, Absolute, [access(none)]),
          rlm_effect_store_open(Absolute),
          rlm_effect_store_attached(_),
          rlm_effect_store_close,
          run_contender(Ledger, open, Status),
          assertion(Status == exit(0)) ),
        ( catch(rlm_effect_store_close, _, true),
          cleanup_store_files(Ledger) )).

test(store_switch_releases_old_and_owns_new) :-
    fresh_store_path(switch_a, LedgerA),
    fresh_store_path(switch_b, LedgerB),
    setup_call_cleanup(
        true,
        ( rlm_effect_store_open(LedgerA),
          rlm_effect_store_open(LedgerB),
          run_contender(LedgerA, open, OldStatus),
          assertion(OldStatus == exit(0)),
          run_contender(LedgerB, blocked, NewStatus),
          assertion(NewStatus == exit(0)),
          rlm_effect_store_close,
          run_contender(LedgerB, open, ReopenStatus),
          assertion(ReopenStatus == exit(0)) ),
        ( catch(rlm_effect_store_close, _, true),
          cleanup_store_files(LedgerA),
          cleanup_store_files(LedgerB) )).

test(store_db_attach_failure_releases_sidecar_lock) :-
    fresh_store_path(attach_failure, Base),
    atom_concat(Base, '-directory', Directory),
    atom_concat(Directory, '.lock', LockFile),
    setup_call_cleanup(
        make_directory(Directory),
        ( catch(rlm_effect_store_open(Directory), Error, true),
          assertion(nonvar(Error)),
          assertion(\+ rlm_effect_store_attached(_)),
          setup_call_cleanup(
              open(LockFile, append, Stream,
                   [encoding(utf8),lock(exclusive),wait(false)]),
              true,
              close(Stream)) ),
        ( catch(rlm_effect_store_close, _, true),
          catch(delete_file(LockFile), _, true),
          catch(delete_directory(Directory), _, true),
          cleanup_store_files(Base) )).

test(store_lock_failure_does_not_poison_future_open) :-
    fresh_store_path(lock_failure, Ledger),
    setup_call_cleanup(
        start_owner(Ledger, Owner),
        ( catch(rlm_effect_store_open(Ledger), Error, true),
          assertion(Error = error(permission_error(lock, effect_store, _), _)),
          assertion(\+ rlm_effect_store_attached(_)),
          kill_owner(Owner),
          rlm_effect_store_open(Ledger),
          rlm_effect_store_close ),
        ( cleanup_owner(Owner),
          catch(rlm_effect_store_close, _, true),
          cleanup_store_files(Ledger) )).

test(store_relative_and_absolute_alias_share_one_owner) :-
    fresh_store_path(path_alias, Ledger),
    file_directory_name(Ledger, Directory),
    file_base_name(Ledger, BaseName),
    setup_call_cleanup(
        working_directory(OldDirectory, Directory),
        ( atom_concat('./', BaseName, Relative),
          rlm_effect_store_open(Relative),
          rlm_effect_store_open(Ledger),
          run_contender(Ledger, blocked, BlockedStatus),
          assertion(BlockedStatus == exit(0)),
          rlm_effect_store_close,
          run_contender(Ledger, open, OpenStatus),
          assertion(OpenStatus == exit(0)) ),
        ( catch(rlm_effect_store_close, _, true),
          working_directory(_, OldDirectory),
          cleanup_store_files(Ledger) )).

test(store_simultaneous_process_start_has_exactly_one_writer) :-
    fresh_store_path(simultaneous, Ledger),
    setup_call_cleanup(
        start_racers(Ledger, RacerA, RacerB),
        ( release_racer_start(RacerA),
          release_racer_start(RacerB),
          racer_result(RacerA, ResultA),
          racer_result(RacerB, ResultB),
          msort([ResultA,ResultB], Results),
          assertion(Results == [acquired,blocked]),
          release_acquired(RacerA, ResultA),
          release_acquired(RacerB, ResultB),
          wait_racer(RacerA, StatusA),
          wait_racer(RacerB, StatusB),
          assertion(StatusA == exit(0)),
          assertion(StatusB == exit(0)),
          run_contender(Ledger, open, ReopenStatus),
          assertion(ReopenStatus == exit(0)) ),
        ( cleanup_racer(RacerA),
          cleanup_racer(RacerB),
          cleanup_store_files(Ledger) )).

fresh_store_path(Tag, Ledger) :-
    tmp_file(rlm_effect_hardening, Base),
    atomic_list_concat([Base,'-',Tag,'.db'], Ledger).

run_contender(Ledger, Mode, Status) :-
    absolute_file_name('test/effect_store_contender.pl', Script, [access(read)]),
    append(['-q','-s',Script,'--'], [Ledger,Mode], Arguments),
    process_create(path(swipl), Arguments, [process(Pid)]),
    process_wait(Pid, Status).

start_owner(Ledger, owner(Pid, In, Out)) :-
    absolute_file_name('test/effect_store_owner_phase1.pl', Script,
                       [access(read)]),
    append(['-q','-s',Script,'--'], [Ledger], Arguments),
    process_create(path(swipl), Arguments,
                   [process(Pid),stdin(pipe(In)),stdout(pipe(Out))]),
    read_line_to_string(Out, Marker),
    assertion(Marker == "owner_ready").

kill_owner(owner(Pid, In, Out)) :-
    catch(process_kill(Pid, kill), _, true),
    catch(process_wait(Pid, _), _, true),
    catch(close(In), _, true),
    catch(close(Out), _, true).

cleanup_owner(owner(Pid, In, Out)) :-
    catch(close(In), _, true),
    catch(close(Out), _, true),
    catch(process_kill(Pid, kill), _, true),
    catch(process_wait(Pid, _), _, true).

start_racers(Ledger, RacerA, RacerB) :-
    start_racer(Ledger, RacerA),
    catch(start_racer(Ledger, RacerB),
          Error,
          ( cleanup_racer(RacerA), throw(Error) )).

start_racer(Ledger, racer(Pid, In, Out)) :-
    absolute_file_name('test/effect_store_race_contender.pl', Script,
                       [access(read)]),
    append(['-q','-s',Script,'--'], [Ledger], Arguments),
    process_create(path(swipl), Arguments,
                   [process(Pid),stdin(pipe(In)),stdout(pipe(Out))]),
    read_line_to_string(Out, Marker),
    assertion(Marker == "ready").

release_racer_start(racer(_, In, _)) :-
    format(In, 'go~n', []),
    flush_output(In).

racer_result(racer(_, _, Out), Result) :-
    read_line_to_string(Out, Line),
    atom_string(Result, Line).

release_acquired(racer(_, In, _), acquired) :-
    !,
    format(In, 'release~n', []),
    flush_output(In).
release_acquired(_, blocked).

wait_racer(racer(Pid, _, _), Status) :-
    process_wait(Pid, Status).

cleanup_racer(racer(Pid, In, Out)) :-
    catch(close(In), _, true),
    catch(close(Out), _, true),
    catch(process_kill(Pid, kill), _, true),
    catch(process_wait(Pid, _), _, true).

:- end_tests(rlm_effect_hardening).
