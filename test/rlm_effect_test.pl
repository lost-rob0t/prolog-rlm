:- begin_tests(rlm_effect).

:- use_module('../prolog/rlm_effect').
:- use_module(library(lists)).

:- dynamic fake_submit_count/1.

setup_effect_store(File) :-
    tmp_file(rlm_effect, File),
    rlm_effect_store_open(File),
    retractall(fake_submit_count(_)),
    assertz(fake_submit_count(0)).

cleanup_effect_store(File) :-
    catch(rlm_effect_store_close, _, true),
    catch(delete_file(File), _, true),
    retractall(fake_submit_count(_)).

with_effect_store(Goal) :-
    setup_call_cleanup(setup_effect_store(File), Goal, cleanup_effect_store(File)).

fake_submit(remote_result) :-
    with_mutex(rlm_effect_fake,
               ( retract(fake_submit_count(N0)),
                 N is N0+1,
                 assertz(fake_submit_count(N)) )).

fake_count(N) :- fake_submit_count(N).

observation(Value,
            observation{status:succeeded,
                        value:Value,
                        usage:usage{units:1},
                        provenance:fake_provider}).

execute_ticket(Ticket, Observation) :-
    rlm_effect_admit(Ticket, authority_ref{tier:dangerous}, execute(Attempt)),
    rlm_effect_dispatch(Attempt.attempt_id, dispatch(_)),
    fake_submit(Value),
    observation(Value, Observation0),
    rlm_effect_observe(Attempt.attempt_id, Observation0, observed(Observation)).

error_kind(error(Error), Kind) :- Error.kind == Kind.

assert_attempt_status(Attempt, Status) :-
    assertion(is_dict(Attempt, effect_attempt)),
    assertion(Attempt.status == Status).

test(normalization_is_deterministic_for_dict_key_order) :-
    RequestA = request{provider:fake, payload:payload{b:2, a:1}},
    dict_create(PayloadB, payload, [a-1,b-2]),
    RequestB = request{payload:PayloadB, provider:fake},
    rlm_effect_normalize(RequestA, NormalA),
    rlm_effect_normalize(RequestB, NormalB),
    assertion(NormalA == NormalB).

test(metadata_does_not_change_executable_fingerprint) :-
    with_effect_store(
        ( Request = request{provider:fake, payload:payload{x:1}},
          rlm_effect_prepare(model, Request,
                             _{metadata:metadata{trace_id:trace_a,session_id:s1}},
                             execute(A)),
          rlm_effect_prepare(model, Request,
                             _{metadata:metadata{trace_id:trace_b,session_id:s2}},
                             execute(B)),
          assertion(A.call_id == B.call_id),
          assertion(A.fingerprint == B.fingerprint),
          assertion(A.attempt_id == B.attempt_id)
        )).

test(changed_semantics_changes_fingerprint) :-
    with_effect_store(
        ( Request = request{provider:fake, payload:payload{x:1}},
          rlm_effect_prepare(model, Request,
                             _{semantics:semantics{temperature:0.1}}, execute(A)),
          rlm_effect_prepare(model, Request,
                             _{semantics:semantics{temperature:0.2}}, execute(B)),
          assertion(A.fingerprint \== B.fingerprint)
        )).

test(changed_payload_changes_fingerprint) :-
    with_effect_store(
        ( rlm_effect_prepare(tool, request{target:a}, _{}, execute(A)),
          rlm_effect_prepare(tool, request{target:b}, _{}, execute(B)),
          assertion(A.fingerprint \== B.fingerprint)
        )).

test(non_ground_request_rejected) :-
    with_effect_store(
        ( Request = request{target:_},
          rlm_effect_prepare(tool, Request, _{}, Outcome),
          assertion(error_kind(Outcome, non_ground_request))
        )).

test(cyclic_request_rejected) :-
    with_effect_store(
        ( X = cycle(X),
          rlm_effect_prepare(tool, request{target:X}, _{}, Outcome),
          assertion(error_kind(Outcome, cyclic_request))
        )).

test(unsupported_runtime_value_rejected) :-
    with_effect_store(
        setup_call_cleanup(
            open_null_stream(Stream),
            ( rlm_effect_prepare(tool, request{stream:Stream}, _{}, Outcome),
              assertion(error_kind(Outcome, unsupported_value)) ),
            close(Stream))).

test(first_execution_then_replay) :-
    with_effect_store(
        ( rlm_effect_prepare(model, request{prompt:test}, _{}, execute(Ticket)),
          execute_ticket(Ticket, FirstObservation),
          rlm_effect_prepare(model, request{prompt:test}, _{}, replay(Replay)),
          assertion(Replay == FirstObservation),
          fake_count(1)
        )).

test(backtracking_consumes_recorded_observation_without_resubmit) :-
    with_effect_store(
        ( findall(Branch-Value,
                  ( member(Branch, [one,two,three]),
                    rlm_effect_prepare(model, request{prompt:backtrack}, _{}, Decision),
                    ( Decision = execute(Ticket)
                    -> execute_ticket(Ticket, Observation)
                    ;  Decision = replay(Observation) ),
                    Value = Observation.value
                  ),
                  Results),
          assertion(Results == [one-remote_result,
                                two-remote_result,
                                three-remote_result]),
          fake_count(1)
        )).

test(repeated_prepare_while_admitted_has_no_second_owner) :-
    with_effect_store(
        ( Request = request{target:single},
          rlm_effect_prepare(tool, Request, _{}, execute(Ticket)),
          rlm_effect_admit(Ticket, authority_ref{tier:dangerous}, execute(Attempt)),
          rlm_effect_prepare(tool, Request, _{}, in_progress(Current)),
          assertion(Current.attempt_id == Attempt.attempt_id),
          fake_count(0)
        )).

test(repeated_dispatch_does_not_cross_boundary_twice) :-
    with_effect_store(
        ( rlm_effect_prepare(tool, request{target:dispatch}, _{}, execute(Ticket)),
          rlm_effect_admit(Ticket, authority_ref{tier:dangerous}, execute(Attempt)),
          rlm_effect_dispatch(Attempt.attempt_id, dispatch(_)),
          rlm_effect_dispatch(Attempt.attempt_id, Second),
          assertion(Second = in_progress(SecondAttempt)),
          assert_attempt_status(SecondAttempt, dispatching),
          fake_count(0)
        )).

test(idempotency_key_is_stable_and_distinct) :-
    with_effect_store(
        ( rlm_effect_prepare(model, request{prompt:key}, _{}, execute(Ticket)),
          rlm_effect_idempotency_key(Ticket.attempt_id, KeyA),
          rlm_effect_idempotency_key(Ticket.attempt_id, KeyB),
          assertion(KeyA == KeyB),
          assertion(KeyA \== Ticket.call_id),
          assertion(KeyA \== Ticket.fingerprint)
        )).

test(explicit_retry_creates_new_linked_attempt) :-
    with_effect_store(
        ( Request = request{prompt:retry},
          rlm_effect_prepare(model, Request, _{}, execute(Initial)),
          execute_ticket(Initial, _),
          rlm_effect_prepare(model, Request,
                             _{mode:retry,parent_attempt:Initial.attempt_id},
                             execute(Retry)),
          assertion(Retry.mode == retry),
          assertion(Retry.parent_attempt == Initial.attempt_id),
          assertion(Retry.attempt_id \== Initial.attempt_id),
          assertion(Retry.fingerprint == Initial.fingerprint)
        )).

test(reentering_same_explicit_retry_reuses_attempt_identity) :-
    with_effect_store(
        ( Request = request{prompt:retry_identity},
          rlm_effect_prepare(model, Request, _{}, execute(Initial)),
          execute_ticket(Initial, _),
          Options = _{mode:retry,parent_attempt:Initial.attempt_id},
          rlm_effect_prepare(model, Request, Options, execute(RetryA)),
          rlm_effect_prepare(model, Request, Options, execute(RetryB)),
          assertion(RetryA.attempt_id == RetryB.attempt_id)
        )).

test(explicit_resample_is_distinct_from_retry_and_replay) :-
    with_effect_store(
        ( Request = request{prompt:sample},
          rlm_effect_prepare(model, Request, _{}, execute(Initial)),
          execute_ticket(Initial, _),
          rlm_effect_prepare(model, Request,
                             _{mode:resample,parent_attempt:Initial.attempt_id},
                             execute(Resample)),
          rlm_effect_prepare(model, Request,
                             _{mode:retry,parent_attempt:Initial.attempt_id},
                             execute(Retry)),
          assertion(Resample.mode == resample),
          assertion(Resample.attempt_id \== Initial.attempt_id),
          assertion(Resample.attempt_id \== Retry.attempt_id)
        )).

test(changed_payload_same_logical_key_is_new_execution_identity) :-
    with_effect_store(
        ( Options = _{logical_key:job_42},
          rlm_effect_prepare(tool, request{target:a}, Options, execute(A)),
          execute_ticket(A, _),
          rlm_effect_prepare(tool, request{target:b}, Options, execute(B)),
          assertion(A.call_id == B.call_id),
          assertion(A.fingerprint \== B.fingerprint),
          assertion(B.mode == initial)
        )).

test(cancellation_before_claim_is_durable_and_blocks_admission) :-
    with_effect_store(
        ( rlm_effect_prepare(tool, request{target:cancel_early}, _{}, execute(Ticket)),
          rlm_effect_cancel_ticket(Ticket, caller_cancelled, cancelled(Cancelled)),
          assert_attempt_status(Cancelled, cancelled_before_claim),
          rlm_effect_admit(Ticket, authority_ref{tier:dangerous}, terminal(Again)),
          assert_attempt_status(Again, cancelled_before_claim)
        )).

test(cancellation_after_claim_before_dispatch_is_terminal_without_effect) :-
    with_effect_store(
        ( rlm_effect_prepare(tool, request{target:cancel_admitted}, _{}, execute(Ticket)),
          rlm_effect_admit(Ticket, authority_ref{tier:dangerous}, execute(Attempt)),
          rlm_effect_cancel(Attempt.attempt_id, caller_cancelled, cancelled(Cancelled)),
          assert_attempt_status(Cancelled, cancelled_pre_dispatch),
          rlm_effect_dispatch(Attempt.attempt_id, terminal(DispatchState)),
          assert_attempt_status(DispatchState, cancelled_pre_dispatch),
          fake_count(0)
        )).

test(cancellation_while_dispatching_preserves_remote_uncertainty) :-
    with_effect_store(
        ( rlm_effect_prepare(tool, request{target:cancel_remote}, _{}, execute(Ticket)),
          rlm_effect_admit(Ticket, authority_ref{tier:dangerous}, execute(Attempt)),
          rlm_effect_dispatch(Attempt.attempt_id, dispatch(_)),
          rlm_effect_cancel(Attempt.attempt_id, caller_cancelled,
                            reconciliation_required(CancelState)),
          assert_attempt_status(CancelState, cancellation_requested)
        )).

test(crash_window_state_requires_reconciliation_not_resubmit) :-
    with_effect_store(
        ( Request = request{prompt:crash_window},
          rlm_effect_prepare(model, Request, _{}, execute(Ticket)),
          rlm_effect_admit(Ticket, authority_ref{tier:dangerous}, execute(Attempt)),
          rlm_effect_dispatch(Attempt.attempt_id, dispatch(_)),
          fake_submit(_),
          rlm_effect_prepare(model, Request, _{}, reconciliation_required(Unknown)),
          assertion(Unknown.attempt_id == Attempt.attempt_id),
          assert_attempt_status(Unknown, dispatching),
          fake_count(1)
        )).

test(reconciliation_recovers_original_observation) :-
    with_effect_store(
        ( Request = request{prompt:reconcile},
          rlm_effect_prepare(model, Request, _{}, execute(Ticket)),
          rlm_effect_admit(Ticket, authority_ref{tier:dangerous}, execute(Attempt)),
          rlm_effect_dispatch(Attempt.attempt_id, dispatch(_)),
          fake_submit(Value),
          observation(Value, Observation0),
          rlm_effect_reconcile(Attempt.attempt_id, Observation0, reconciled(Observation)),
          rlm_effect_prepare(model, Request, _{}, replay(Replay)),
          assertion(Replay == Observation),
          fake_count(1)
        )).

test(non_reconcilable_outcome_requires_host_resolution_before_retry) :-
    with_effect_store(
        ( Request = request{prompt:unknown},
          rlm_effect_prepare(model, Request, _{}, execute(Ticket)),
          rlm_effect_admit(Ticket, authority_ref{tier:dangerous}, execute(Attempt)),
          rlm_effect_dispatch(Attempt.attempt_id, dispatch(_)),
          fake_submit(_),
          rlm_effect_mark_indeterminate(Attempt.attempt_id, provider_cannot_query,
                                        indeterminate(Unknown)),
          assert_attempt_status(Unknown, indeterminate),
          rlm_effect_prepare(model, Request,
                             _{mode:retry,parent_attempt:Attempt.attempt_id},
                             BeforeResolution),
          assertion(error_kind(BeforeResolution,
                               indeterminate_requires_resolution)),
          rlm_effect_resolve_indeterminate(Attempt.attempt_id, retry_authorized,
                                           resolved(Resolved)),
          assert_attempt_status(Resolved, retry_authorized),
          rlm_effect_prepare(model, Request,
                             _{mode:retry,parent_attempt:Attempt.attempt_id},
                             execute(Retry)),
          assertion(Retry.parent_attempt == Unknown.attempt_id),
          fake_count(1)
        )).

test(observation_is_immutable) :-
    with_effect_store(
        ( rlm_effect_prepare(model, request{prompt:immutable}, _{}, execute(Ticket)),
          execute_ticket(Ticket, First),
          Other = observation{status:succeeded,
                              value:different,
                              usage:usage{units:1},
                              provenance:fake_provider},
          rlm_effect_observe(Ticket.attempt_id, Other, Conflict),
          assertion(error_kind(Conflict, observation_conflict)),
          rlm_effect_observation(Ticket.attempt_id, Stored),
          assertion(Stored == First)
        )).

test(terminal_observation_never_returns_to_in_flight) :-
    with_effect_store(
        ( rlm_effect_prepare(model, request{prompt:terminal}, _{}, execute(Ticket)),
          execute_ticket(Ticket, Observation),
          rlm_effect_dispatch(Ticket.attempt_id, replay(Replay)),
          assertion(Replay == Observation),
          rlm_effect_status(Ticket.attempt_id, Attempt),
          assert_attempt_status(Attempt, observed)
        )).

test(history_preserves_execution_after_later_logic_failure) :-
    with_effect_store(
        ( rlm_effect_prepare(model, request{prompt:accounted}, _{}, execute(Ticket)),
          execute_ticket(Ticket, _),
          ( fail ; true ),
          rlm_effect_history(Ticket.call_id, Events),
          include(event_type(attempt_dispatched), Events, DispatchEvents),
          include(event_type(observation_recorded), Events, ObservationEvents),
          assertion(DispatchEvents \== []),
          assertion(ObservationEvents \== [])
        )).

event_type(Type, Event) :- Event.type == Type.

test(parallel_same_effect_has_one_execution_owner) :-
    with_effect_store(
        setup_call_cleanup(
            create_parallel_queues(Start, Done, Results),
            ( Request = request{target:parallel},
              thread_create(parallel_candidate(Request, Start, Done, Results), T1, []),
              thread_create(parallel_candidate(Request, Start, Done, Results), T2, []),
              thread_send_message(Start, go),
              thread_send_message(Start, go),
              thread_get_message(Results, R1),
              thread_get_message(Results, R2),
              thread_join(T1, true),
              thread_join(T2, true),
              msort([R1,R2], Sorted),
              assertion(Sorted == [executed,observed]),
              fake_count(1) ),
            destroy_parallel_queues(Start, Done, Results))).

create_parallel_queues(Start, Done, Results) :-
    message_queue_create(Start),
    message_queue_create(Done),
    message_queue_create(Results).

destroy_parallel_queues(Start, Done, Results) :-
    message_queue_destroy(Start),
    message_queue_destroy(Done),
    message_queue_destroy(Results).

parallel_candidate(Request, Start, Done, Results) :-
    thread_get_message(Start, go),
    rlm_effect_prepare(tool, Request, _{}, Decision),
    parallel_after_prepare(Decision, Done, Results).

parallel_after_prepare(replay(_), _, Results) :-
    thread_send_message(Results, observed).
parallel_after_prepare(in_progress(_), Done, Results) :-
    thread_get_message(Done, observed),
    thread_send_message(Results, observed).
parallel_after_prepare(execute(Ticket), Done, Results) :-
    rlm_effect_admit(Ticket, authority_ref{tier:dangerous}, Admission),
    parallel_after_admission(Admission, Done, Results).

parallel_after_admission(execute(Attempt), Done, Results) :-
    rlm_effect_dispatch(Attempt.attempt_id, dispatch(_)),
    fake_submit(Value),
    observation(Value, Observation),
    rlm_effect_observe(Attempt.attempt_id, Observation, observed(_)),
    thread_send_message(Done, observed),
    thread_send_message(Results, executed).
parallel_after_admission(in_progress(_), Done, Results) :-
    thread_get_message(Done, observed),
    thread_send_message(Results, observed).

test(prune_refuses_unresolved_attempt) :-
    with_effect_store(
        ( rlm_effect_prepare(model, request{prompt:retain}, _{}, execute(Ticket)),
          rlm_effect_admit(Ticket, authority_ref{tier:dangerous}, execute(Attempt)),
          rlm_effect_dispatch(Attempt.attempt_id, dispatch(_)),
          rlm_effect_prune(Ticket.call_id, Outcome),
          assertion(error_kind(Outcome, active_or_indeterminate_attempt))
        )).

test(prune_allows_fully_terminal_call) :-
    with_effect_store(
        ( rlm_effect_prepare(model, request{prompt:prune}, _{}, execute(Ticket)),
          execute_ticket(Ticket, _),
          rlm_effect_prune(Ticket.call_id, pruned),
          rlm_effect_status(Ticket.attempt_id, Outcome),
          assertion(error_kind(Outcome, unknown_attempt))
        )).

:- end_tests(rlm_effect).
