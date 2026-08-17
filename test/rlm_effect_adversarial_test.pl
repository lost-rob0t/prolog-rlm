:- begin_tests(rlm_effect_adversarial).

:- use_module('../prolog/rlm_effect').
:- use_module('../prolog/rlm_effect_executor').
:- use_module('../prolog/rlm_async').

:- dynamic adversarial_count/2.
:- dynamic adversarial_gate/2.

:- multifile rlm_effect_executor:effect_adapter_submit/4.
:- multifile rlm_effect_executor:effect_adapter_reconcile/4.

rlm_effect_executor:effect_adapter_submit(Adapter, _, Request,
                                          observed(Observation)) :-
    memberchk(Adapter, [adversarial_a, adversarial_b]),
    plunit_rlm_effect_adversarial:bump(Adapter),
    Observation = observation{status:succeeded,
                              value:result{adapter:Adapter,request:Request},
                              usage:usage{units:1},
                              provenance:Adapter}.

rlm_effect_executor:effect_adapter_submit(adversarial_unresolved, _, _,
                                          indeterminate(remote_unknown)) :-
    plunit_rlm_effect_adversarial:bump(adversarial_unresolved).

rlm_effect_executor:effect_adapter_submit(adversarial_blocking, Attempt,
                                          Request, observed(Observation)) :-
    plunit_rlm_effect_adversarial:bump(adversarial_blocking),
    plunit_rlm_effect_adversarial:adversarial_gate(Entered, Release),
    thread_send_message(Entered, entered(Attempt.attempt_id)),
    thread_get_message(Release, release),
    Observation = observation{status:succeeded,
                              value:result{request:Request},
                              usage:usage{units:1},
                              provenance:adversarial_blocking}.

rlm_effect_executor:effect_adapter_reconcile(Adapter, _, _,
                                             indeterminate(should_not_run)) :-
    memberchk(Adapter, [adversarial_a, adversarial_b,
                        adversarial_unresolved, adversarial_blocking]),
    atom_concat(reconcile_, Adapter, Counter),
    plunit_rlm_effect_adversarial:bump(Counter).

setup_store(File) :-
    tmp_file(rlm_effect_adversarial, File),
    rlm_effect_store_open(File),
    retractall(adversarial_count(_, _)),
    retractall(adversarial_gate(_, _)).

cleanup_store(File) :-
    catch(rlm_effect_store_close, _, true),
    atom_concat(File, '.lock', Lock),
    catch(delete_file(File), _, true),
    catch(delete_file(Lock), _, true),
    retractall(adversarial_count(_, _)),
    retractall(adversarial_gate(_, _)).

with_store(Goal) :-
    setup_call_cleanup(setup_store(File), Goal, cleanup_store(File)).

bump(Name) :-
    with_mutex(rlm_effect_adversarial_counter,
               ( ( retract(adversarial_count(Name, N0)) -> true ; N0 = 0 ),
                 N is N0+1,
                 assertz(adversarial_count(Name, N)) )).

count(Name, N) :-
    ( adversarial_count(Name, Found) -> N = Found ; N = 0 ).

authority(authority_ref{source:adversarial,tier:dangerous}).

error_kind(error(Error), Kind) :-
    get_dict(kind, Error, Kind).

test(adapter_identity_scopes_executor_identity_and_provider_key) :-
    with_store(
        ( Request = request{operation:same,payload:payload{x:1}},
          effect_prepare(adversarial_a, tool, Request, _{}, execute(A)),
          effect_prepare(adversarial_b, tool, Request, _{}, execute(B)),
          get_dict(fingerprint, A, AFingerprint),
          get_dict(fingerprint, B, BFingerprint),
          get_dict(call_id, A, ACall),
          get_dict(call_id, B, BCall),
          get_dict(attempt_id, A, AAttempt),
          get_dict(attempt_id, B, BAttempt),
          get_dict(idempotency_key, A, AKey),
          get_dict(idempotency_key, B, BKey),
          assertion(AFingerprint \== BFingerprint),
          assertion(ACall \== BCall),
          assertion(AAttempt \== BAttempt),
          assertion(AKey \== BKey)
        )).

test(caller_cannot_override_trusted_adapter_identity) :-
    with_store(
        ( Options = _{semantics:semantics{executor_identity:
                                      executor_identity{adapter:adversarial_b}},
                      metadata:metadata{executor_identity:
                                     executor_identity{adapter:adversarial_b}}},
          effect_prepare(adversarial_a, tool,
                         request{operation:reserved_identity}, Options,
                         execute(Ticket)),
          get_dict(semantics, Ticket, Semantics),
          get_dict(executor_identity, Semantics, SemanticsIdentity),
          get_dict(adapter, SemanticsIdentity, adversarial_a),
          get_dict(metadata, Ticket, Metadata),
          get_dict(executor_identity, Metadata, MetadataIdentity),
          get_dict(adapter, MetadataIdentity, adversarial_a)
        )).

test(changed_adapter_executes_distinct_attempts_without_cross_replay) :-
    with_store(
        ( Request = request{operation:adapter_split},
          authority(Authority),
          effect_execute(adversarial_a, tool, Request, _{}, Authority, A),
          effect_execute(adversarial_b, tool, Request, _{}, Authority, B),
          get_dict(observation, A, AObservation),
          get_dict(observation, B, BObservation),
          get_dict(provenance, AObservation, AProvenance),
          get_dict(provenance, BObservation, BProvenance),
          assertion(AProvenance == adversarial_a),
          assertion(BProvenance == adversarial_b),
          count(adversarial_a, 1),
          count(adversarial_b, 1)
        )).

test(wrong_adapter_reconciliation_fails_before_callback) :-
    with_store(
        ( Request = request{operation:wrong_adapter},
          authority(Authority),
          effect_execute(adversarial_unresolved, tool, Request, _{},
                         Authority, First),
          get_dict(attempt, First, Attempt),
          get_dict(attempt_id, Attempt, AttemptId),
          effect_reconcile(adversarial_b, AttemptId, Wrong),
          assertion(error_kind(Wrong, adapter_identity_mismatch)),
          count(reconcile_adversarial_b, 0),
          count(adversarial_unresolved, 1)
        )).

test(authoritative_local_observation_replays_without_remote_reconcile) :-
    with_store(
        ( Request = request{operation:local_truth},
          authority(Authority),
          effect_prepare(adversarial_a, tool, Request, _{}, execute(Ticket)),
          effect_execute(adversarial_a, tool, Request, _{}, Authority, First),
          get_dict(observation, First, Observation),
          get_dict(attempt_id, Ticket, AttemptId),
          effect_reconcile(adversarial_a, AttemptId, Replayed),
          get_dict(observation, Replayed, Again),
          get_dict(source, Replayed, Source),
          assertion(Source == local_observation),
          assertion(Observation == Again),
          count(reconcile_adversarial_a, 0)
        )).

test(abandoned_does_not_authorize_retry_or_resample) :-
    with_store(
        ( Request = request{operation:abandoned},
          rlm_effect_prepare(tool, Request, _{}, execute(Ticket)),
          authority(Authority),
          rlm_effect_admit(Ticket, Authority, execute(Attempt)),
          get_dict(attempt_id, Attempt, AttemptId),
          rlm_effect_dispatch(AttemptId, dispatch(_)),
          rlm_effect_mark_indeterminate(AttemptId, remote_unknown,
                                        indeterminate(_)),
          rlm_effect_resolve_indeterminate(AttemptId, abandoned, resolved(_)),
          rlm_effect_prepare(tool, Request,
                             _{mode:retry,parent_attempt:AttemptId}, Retry),
          rlm_effect_prepare(tool, Request,
                             _{mode:resample,parent_attempt:AttemptId}, Resample),
          assertion(error_kind(Retry, abandoned_retry_not_authorized)),
          assertion(error_kind(Resample, abandoned_retry_not_authorized))
        )).

test(prune_advances_epoch_and_rejects_stale_ticket) :-
    with_store(
        ( Request = request{operation:post_prune},
          rlm_effect_prepare(tool, Request, _{}, execute(Old)),
          rlm_effect_cancel_ticket(Old, not_needed, cancelled(OldAttempt)),
          get_dict(call_id, Old, OldCall),
          get_dict(attempt_id, Old, OldAttemptId),
          get_dict(idempotency_key, Old, OldKey),
          get_dict(attempt_id, OldAttempt, CancelledAttemptId),
          assertion(CancelledAttemptId == OldAttemptId),
          rlm_effect_prune(OldCall, pruned),
          authority(Authority),
          rlm_effect_admit(Old, Authority, StaleAdmission),
          assertion(error_kind(StaleAdmission, invalid_ticket_identity)),
          rlm_effect_prepare(tool, Request, _{}, execute(New)),
          get_dict(call_id, New, NewCall),
          get_dict(attempt_id, New, NewAttemptId),
          get_dict(idempotency_key, New, NewKey),
          assertion(NewCall \== OldCall),
          assertion(NewAttemptId \== OldAttemptId),
          assertion(NewKey \== OldKey)
        )).

test(prune_racing_retry_admission_is_linearizable_without_orphan) :-
    with_store(
        setup_call_cleanup(
            create_race_queues(Start, Results),
            ( Request = request{operation:prune_retry_race},
              rlm_effect_prepare(tool, Request, _{}, execute(Initial)),
              rlm_effect_cancel_ticket(Initial, terminal_parent, cancelled(_)),
              get_dict(attempt_id, Initial, ParentId),
              get_dict(call_id, Initial, CallId),
              rlm_effect_prepare(tool, Request,
                                 _{mode:retry,parent_attempt:ParentId},
                                 execute(Retry)),
              authority(Authority),
              thread_create(race_admit(Retry, Authority, Start, Results),
                            AdmitThread, []),
              thread_create(race_prune(CallId, Start, Results),
                            PruneThread, []),
              thread_send_message(Start, go),
              thread_send_message(Start, go),
              thread_get_message(Results, admit(Admission)),
              thread_get_message(Results, prune(Prune)),
              thread_join(AdmitThread, true),
              thread_join(PruneThread, true),
              assert_linearized_prune_race(Admission, Prune, Retry)
            ),
            destroy_race_queues(Start, Results))).

test(prune_racing_preparation_is_linearizable_without_old_epoch_orphan) :-
    with_store(
        setup_call_cleanup(
            create_race_queues(Start, Results),
            ( Options = _{logical_key:logical_job},
              rlm_effect_prepare(tool, request{version:1}, Options,
                                 execute(Initial)),
              rlm_effect_cancel_ticket(Initial, terminal, cancelled(_)),
              get_dict(call_id, Initial, OldCallId),
              thread_create(race_prepare(request{version:2}, Options,
                                         Start, Results), PrepareThread, []),
              thread_create(race_prune(OldCallId, Start, Results),
                            PruneThread, []),
              thread_send_message(Start, go),
              thread_send_message(Start, go),
              thread_get_message(Results, prepare(execute(NewTicket))),
              thread_get_message(Results, prune(pruned)),
              thread_join(PrepareThread, true),
              thread_join(PruneThread, true),
              authority(Authority),
              rlm_effect_admit(NewTicket, Authority, Admission),
              assert_linearized_prepare_race(Admission, NewTicket, OldCallId),
              get_dict(attempt_id, Initial, OldAttemptId),
              rlm_effect_status(OldAttemptId, Missing),
              error_kind(Missing, unknown_attempt)
            ),
            destroy_race_queues(Start, Results))).

test(prune_racing_dispatch_refuses_to_delete_active_attempt) :-
    with_store(
        ( with_transition_race_fixture(dispatch, AttemptId, CallId,
                                       Transition, Prune),
          assertion(Transition = dispatch(_)),
          assertion(error_kind(Prune, active_or_indeterminate_attempt)),
          rlm_effect_status(AttemptId, Stored),
          get_dict(status, Stored, dispatching),
          assertion(CallId \== '') )).

test(prune_racing_observation_is_linearizable) :-
    with_store(
        ( with_transition_race_fixture(observe, AttemptId, _,
                                       Transition, Prune),
          assertion(Transition = observed(_)),
          assert_terminal_transition_prune(Prune, AttemptId, observed) )).

test(prune_racing_pre_dispatch_cancellation_is_linearizable) :-
    with_store(
        ( with_transition_race_fixture(cancel, AttemptId, _,
                                       Transition, Prune),
          assertion(Transition = cancelled(_)),
          assert_terminal_transition_prune(
              Prune, AttemptId, cancelled_pre_dispatch) )).

test(prune_racing_indeterminate_resolution_is_linearizable) :-
    with_store(
        ( with_transition_race_fixture(resolve, AttemptId, _,
                                       Transition, Prune),
          assertion(Transition = resolved(_)),
          assert_terminal_transition_prune(Prune, AttemptId, abandoned) )).

with_transition_race_fixture(Action, AttemptId, CallId, Transition, Prune) :-
    prepare_transition_fixture(Action, AttemptId, CallId),
    setup_call_cleanup(
        create_race_queues(Start, Results),
        ( thread_create(race_transition(Action, AttemptId, Start, Results),
                        TransitionThread, []),
          thread_create(race_prune(CallId, Start, Results), PruneThread, []),
          thread_send_message(Start, go),
          thread_send_message(Start, go),
          thread_get_message(Results, transition(Transition)),
          thread_get_message(Results, prune(Prune)),
          thread_join(TransitionThread, true),
          thread_join(PruneThread, true)
        ),
        destroy_race_queues(Start, Results)).

prepare_transition_fixture(Action, AttemptId, CallId) :-
    rlm_effect_prepare(tool, request{operation:Action}, _{}, execute(Ticket)),
    authority(Authority),
    rlm_effect_admit(Ticket, Authority, execute(Attempt)),
    get_dict(attempt_id, Attempt, AttemptId),
    get_dict(call_id, Attempt, CallId),
    prepare_transition_state(Action, AttemptId).

prepare_transition_state(observe, AttemptId) :-
    rlm_effect_dispatch(AttemptId, dispatch(_)).
prepare_transition_state(resolve, AttemptId) :-
    rlm_effect_dispatch(AttemptId, dispatch(_)),
    rlm_effect_mark_indeterminate(AttemptId, unknown_remote,
                                  indeterminate(_)).
prepare_transition_state(dispatch, _).
prepare_transition_state(cancel, _).

race_transition(dispatch, AttemptId, Start, Results) :-
    thread_get_message(Start, go),
    rlm_effect_dispatch(AttemptId, Outcome),
    thread_send_message(Results, transition(Outcome)).
race_transition(observe, AttemptId, Start, Results) :-
    thread_get_message(Start, go),
    Observation = observation{status:succeeded,value:race,
                              usage:usage{units:1},provenance:race},
    rlm_effect_observe(AttemptId, Observation, Outcome),
    thread_send_message(Results, transition(Outcome)).
race_transition(cancel, AttemptId, Start, Results) :-
    thread_get_message(Start, go),
    rlm_effect_cancel(AttemptId, race_cancel, Outcome),
    thread_send_message(Results, transition(Outcome)).
race_transition(resolve, AttemptId, Start, Results) :-
    thread_get_message(Start, go),
    rlm_effect_resolve_indeterminate(AttemptId, abandoned, Outcome),
    thread_send_message(Results, transition(Outcome)).

assert_terminal_transition_prune(pruned, AttemptId, _) :-
    !,
    rlm_effect_status(AttemptId, Missing),
    error_kind(Missing, unknown_attempt).
assert_terminal_transition_prune(error(Error), AttemptId, Status) :-
    get_dict(kind, Error, active_or_indeterminate_attempt),
    rlm_effect_status(AttemptId, Stored),
    get_dict(status, Stored, Status).

create_race_queues(Start, Results) :-
    message_queue_create(Start),
    message_queue_create(Results).

destroy_race_queues(Start, Results) :-
    catch(message_queue_destroy(Start), _, true),
    catch(message_queue_destroy(Results), _, true).

race_admit(Ticket, Authority, Start, Results) :-
    thread_get_message(Start, go),
    rlm_effect_admit(Ticket, Authority, Admission),
    thread_send_message(Results, admit(Admission)).

race_prepare(Request, Options, Start, Results) :-
    thread_get_message(Start, go),
    rlm_effect_prepare(tool, Request, Options, Prepared),
    thread_send_message(Results, prepare(Prepared)).

race_prune(CallId, Start, Results) :-
    thread_get_message(Start, go),
    rlm_effect_prune(CallId, Outcome),
    thread_send_message(Results, prune(Outcome)).

assert_linearized_prune_race(error(Error), pruned, Retry) :-
    !,
    get_dict(kind, Error, invalid_ticket_identity),
    get_dict(attempt_id, Retry, RetryId),
    rlm_effect_status(RetryId, Missing),
    error_kind(Missing, unknown_attempt).
assert_linearized_prune_race(execute(Attempt), error(Error), Retry) :-
    get_dict(kind, Error, active_or_indeterminate_attempt),
    get_dict(attempt_id, Attempt, AttemptId),
    get_dict(attempt_id, Retry, AttemptId),
    rlm_effect_status(AttemptId, Stored),
    get_dict(status, Stored, admitted).

assert_linearized_prepare_race(execute(Attempt), Ticket, OldCallId) :-
    get_dict(attempt_id, Attempt, AttemptId),
    get_dict(attempt_id, Ticket, AttemptId),
    get_dict(call_id, Ticket, NewCallId),
    assertion(NewCallId \== OldCallId).
assert_linearized_prepare_race(error(Error), Ticket, OldCallId) :-
    get_dict(kind, Error, invalid_ticket_identity),
    get_dict(call_id, Ticket, OldCallId).

test(independent_stores_have_distinct_namespace_bound_identity) :-
    tmp_file(rlm_effect_store_a, StoreA),
    tmp_file(rlm_effect_store_b, StoreB),
    setup_call_cleanup(
        true,
        ( rlm_effect_store_open(StoreA),
          rlm_effect_store_id(NamespaceA),
          effect_prepare(adversarial_a, tool, request{operation:store_scope},
                         _{}, execute(A)),
          rlm_effect_store_close,
          rlm_effect_store_open(StoreB),
          rlm_effect_store_id(NamespaceB),
          effect_prepare(adversarial_a, tool, request{operation:store_scope},
                         _{}, execute(B)),
          assertion(NamespaceA \== NamespaceB),
          assertion(A.fingerprint == B.fingerprint),
          assertion(A.call_id \== B.call_id),
          assertion(A.attempt_id \== B.attempt_id),
          assertion(A.idempotency_key \== B.idempotency_key),
          rlm_effect_store_close,
          rlm_effect_store_open(StoreA),
          rlm_effect_store_id(NamespaceA),
          effect_prepare(adversarial_a, tool, request{operation:store_scope},
                         _{}, execute(AReopened)),
          get_dict(call_id, A, ACallId),
          get_dict(call_id, AReopened, ACallId),
          get_dict(attempt_id, A, AAttemptId),
          get_dict(attempt_id, AReopened, AAttemptId),
          get_dict(idempotency_key, A, AIdempotencyKey),
          get_dict(idempotency_key, AReopened, AIdempotencyKey),
          rlm_effect_store_close
        ),
        cleanup_two_stores(StoreA, StoreB)).

test(store_namespace_survives_relative_absolute_path_alias_reopen) :-
    tmp_file(rlm_effect_alias, Store),
    file_directory_name(Store, Directory),
    file_base_name(Store, BaseName),
    setup_call_cleanup(
        working_directory(OldDirectory, Directory),
        ( rlm_effect_store_open(Store),
          rlm_effect_store_id(Namespace),
          rlm_effect_store_close,
          rlm_effect_store_open(BaseName),
          rlm_effect_store_id(Namespace),
          rlm_effect_store_close
        ),
        ( working_directory(_, OldDirectory),
          cleanup_one_store(Store) )).

test(independent_store_cannot_cross_reconcile_observation) :-
    tmp_file(rlm_effect_cross_a, StoreA),
    tmp_file(rlm_effect_cross_b, StoreB),
    setup_call_cleanup(
        true,
        ( rlm_effect_store_open(StoreA),
          authority(Authority),
          effect_prepare(adversarial_a, tool, request{operation:cross_store},
                         _{}, execute(TicketA)),
          effect_execute(adversarial_a, tool, request{operation:cross_store},
                         _{}, Authority, _),
          get_dict(attempt_id, TicketA, AttemptA),
          rlm_effect_store_close,
          rlm_effect_store_open(StoreB),
          effect_reconcile(adversarial_a, AttemptA, Cross),
          assertion(error_kind(Cross, unknown_attempt)),
          count(reconcile_adversarial_a, 0),
          rlm_effect_store_close
        ),
        cleanup_two_stores(StoreA, StoreB)).

test(nonempty_legacy_store_fails_closed_with_explicit_migration_error) :-
    tmp_file(rlm_effect_legacy, Ledger),
    setup_call_cleanup(
        true,
        ( rlm_effect_persist:db_attach(Ledger, [sync(close)]),
          rlm_effect_persist:assert_effect_call_record(
              'legacy-call', 'legacy-fingerprint', tool,
              request{operation:legacy}, auto, 0.0),
          rlm_effect_persist:db_detach,
          catch(rlm_effect_store_open(Ledger), Error, true),
          assertion(Error = error(permission_error(
                                      open,
                                      legacy_effect_store_requires_migration,
                                      _), _)),
          assertion(\+ rlm_effect_store_attached(_))
        ),
        cleanup_one_store(Ledger)).

test(inflight_adapter_rejects_store_switch_and_completion_stays_in_origin) :-
    tmp_file(rlm_effect_switch_a, StoreA),
    tmp_file(rlm_effect_switch_b, StoreB),
    setup_call_cleanup(
        setup_switch_fixture(StoreA, Entered, Release),
        ( authority(Authority),
          Request = request{operation:inflight_store_switch},
          effect_prepare(adversarial_blocking, tool, Request, _{},
                         execute(Ticket)),
          effect_execute_async(adversarial_blocking, tool, Request, _{},
                               Authority, Future),
          thread_get_message(Entered, entered(AttemptId)),
          catch(rlm_effect_store_close, CloseError, true),
          assertion(CloseError = error(permission_error(close, effect_store,
                                                        _), _)),
          catch(rlm_effect_store_open(StoreB), SwitchError, true),
          assertion(SwitchError = error(permission_error(switch, effect_store,
                                                         _), _)),
          rlm_effect_store_attached(StoreA),
          thread_send_message(Release, release),
          rlm_future_await(Future, Result),
          assertion(Result.state == observed),
          rlm_future_destroy(Future),
          rlm_effect_store_close,
          rlm_effect_store_open(StoreB),
          effect_prepare(adversarial_blocking, tool, Request, _{},
                         execute(StoreBTicket)),
          assertion(StoreBTicket.attempt_id \== AttemptId),
          rlm_effect_store_close,
          rlm_effect_store_open(StoreA),
          effect_prepare(adversarial_blocking, tool, Request, _{},
                         replay(_)),
          assertion(Ticket.attempt_id == AttemptId),
          count(adversarial_blocking, 1)
        ),
        cleanup_switch_fixture(StoreA, StoreB, Entered, Release)).

setup_switch_fixture(StoreA, Entered, Release) :-
    rlm_effect_store_open(StoreA),
    message_queue_create(Entered),
    message_queue_create(Release),
    assertz(adversarial_gate(Entered, Release)),
    retractall(adversarial_count(_, _)).

cleanup_switch_fixture(StoreA, StoreB, Entered, Release) :-
    catch(rlm_effect_store_close, _, true),
    catch(message_queue_destroy(Entered), _, true),
    catch(message_queue_destroy(Release), _, true),
    retractall(adversarial_gate(_, _)),
    cleanup_two_stores(StoreA, StoreB).

cleanup_two_stores(A, B) :-
    cleanup_one_store(A),
    cleanup_one_store(B).

cleanup_one_store(File) :-
    atom_concat(File, '.lock', Lock),
    catch(delete_file(File), _, true),
    catch(delete_file(Lock), _, true).

:- end_tests(rlm_effect_adversarial).
