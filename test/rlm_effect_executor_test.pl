:- begin_tests(rlm_effect_executor).

:- use_module('../prolog/rlm_effect').
:- use_module('../prolog/rlm_effect_executor').
:- use_module('../prolog/rlm_async').

:- dynamic executor_submit_count/1.
:- dynamic executor_seen_key/1.
:- dynamic executor_gate/2.

:- multifile rlm_effect_executor:effect_adapter_submit/4.
:- multifile rlm_effect_executor:effect_adapter_reconcile/4.
:- multifile rlm_effect_executor:effect_adapter_cancel/4.

rlm_effect_executor:effect_adapter_submit(test_counter, Attempt, Request,
                                          observed(Observation)) :-
    plunit_rlm_effect_executor:record_submit(Attempt.idempotency_key),
    Observation = observation{status:succeeded,
                              value:result{request:Request},
                              usage:usage{units:1},
                              provenance:test_counter}.

rlm_effect_executor:effect_adapter_submit(test_failure, Attempt, _,
                                          observed(Observation)) :-
    plunit_rlm_effect_executor:record_submit(Attempt.idempotency_key),
    Observation = observation{status:failed,
                              value:provider_error,
                              usage:usage{units:1},
                              provenance:test_failure}.

rlm_effect_executor:effect_adapter_submit(test_exception, Attempt, _, _) :-
    plunit_rlm_effect_executor:record_submit(Attempt.idempotency_key),
    throw(test_remote_transport_exploded).

rlm_effect_executor:effect_adapter_submit(Adapter, Attempt, Request,
                                          observed(Observation)) :-
    memberchk(Adapter, [test_blocking,test_cancel_confirmed]),
    plunit_rlm_effect_executor:record_submit(Attempt.idempotency_key),
    plunit_rlm_effect_executor:executor_gate(Entered, Release),
    thread_send_message(Entered, entered(Attempt.attempt_id)),
    thread_get_message(Release, release),
    Observation = observation{status:succeeded,
                              value:result{request:Request},
                              usage:usage{units:1},
                              provenance:Adapter}.

rlm_effect_executor:effect_adapter_reconcile(test_blocking, Attempt, _,
                                             indeterminate(still_running)) :-
    plunit_rlm_effect_executor:executor_gate(Entered, _),
    thread_send_message(Entered, reconciled(Attempt.attempt_id)).

rlm_effect_executor:effect_adapter_cancel(test_blocking, _, _,
                                          indeterminate(cancel_unknown)).

rlm_effect_executor:effect_adapter_cancel(test_cancel_confirmed, _, _,
                                          observed(Observation)) :-
    Observation = observation{status:cancelled,
                              value:provider_cancelled,
                              usage:usage{units:1},
                              provenance:test_cancel_confirmed}.

setup_executor(File) :-
    tmp_file(rlm_effect_executor, File),
    rlm_effect_store_open(File),
    retractall(executor_submit_count(_)),
    retractall(executor_seen_key(_)),
    retractall(executor_gate(_, _)),
    assertz(executor_submit_count(0)).

cleanup_executor(File) :-
    catch(rlm_effect_store_close, _, true),
    catch(delete_file(File), _, true),
    retractall(executor_submit_count(_)),
    retractall(executor_seen_key(_)),
    retractall(executor_gate(_, _)).

with_executor(Goal) :-
    setup_call_cleanup(setup_executor(File), Goal, cleanup_executor(File)).

record_submit(Key) :-
    with_mutex(rlm_effect_executor_test,
               ( retract(executor_submit_count(N0)),
                 N is N0+1,
                 assertz(executor_submit_count(N)),
                 assertz(executor_seen_key(Key)) )).

submit_count(N) :- executor_submit_count(N).

callback_to(Queue, Outcome) :-
    thread_send_message(Queue, callback(Outcome)).

continuation_identity(Outcome, Outcome).

authority_ref(authority_ref{source:test,tier:dangerous}).

request(Name, request{operation:Name,payload:payload{value:1}}).

test(sync_repeat_replays_without_second_submit) :-
    with_executor(
        ( request(sync_repeat, Request),
          authority_ref(Authority),
          effect_execute(test_counter, tool, Request, _{}, Authority, First),
          effect_execute(test_counter, tool, Request, _{}, Authority, Second),
          assertion(First.state == observed),
          assertion(First.source == submit),
          assertion(Second.state == observed),
          assertion(Second.source == replay),
          assertion(First.observation == Second.observation),
          submit_count(1)
        )).

test(async_status_await_callback_and_continuation_do_not_resubmit) :-
    with_executor(
        setup_call_cleanup(
            message_queue_create(Callbacks),
            ( request(async_repeat, Request),
              authority_ref(Authority),
              effect_execute_async(test_counter, tool, Request, _{}, Authority,
                                   Future),
              rlm_future_status(Future, _),
              rlm_future_status(Future, _),
              rlm_future_on_complete(
                  Future,
                  plunit_rlm_effect_executor:callback_to(Callbacks)),
              rlm_future_then(
                  Future,
                  plunit_rlm_effect_executor:continuation_identity,
                  Next),
              rlm_future_await(Future, First),
              rlm_future_await(Future, Again),
              rlm_future_await(Next, Continued),
              thread_get_message(Callbacks, callback(CallbackOutcome)),
              assertion(First == Again),
              assertion(First == Continued),
              assertion(First == CallbackOutcome),
              assertion(First.state == observed),
              submit_count(1),
              rlm_future_destroy(Next),
              rlm_future_destroy(Future) ),
            message_queue_destroy(Callbacks))).

test(sync_after_async_reuses_same_underlying_effect_identity) :-
    with_executor(
        ( request(sync_async, Request),
          authority_ref(Authority),
          effect_execute_async(test_counter, tool, Request, _{}, Authority,
                               Future),
          rlm_future_await(Future, AsyncResult),
          effect_execute(test_counter, tool, Request, _{}, Authority,
                         SyncResult),
          assertion(AsyncResult.observation == SyncResult.observation),
          assertion(SyncResult.source == replay),
          submit_count(1),
          rlm_future_destroy(Future)
        )).

test(adapter_receives_ticket_idempotency_key) :-
    with_executor(
        ( request(idempotency, Request),
          authority_ref(Authority),
          rlm_effect_prepare(tool, Request, _{}, execute(Ticket)),
          effect_execute(test_counter, tool, Request, _{}, Authority, Result),
          assertion(Result.state == observed),
          executor_seen_key(Key),
          assertion(Key == Ticket.idempotency_key),
          assertion(Key \== Ticket.call_id),
          assertion(Key \== Ticket.fingerprint),
          sub_atom(Key, 0, _, _, 'rlm-effect:'),
          submit_count(1)
        )).

test(provider_reported_failure_is_observed_and_replayed) :-
    with_executor(
        ( request(failure, Request),
          authority_ref(Authority),
          effect_execute(test_failure, tool, Request, _{}, Authority, First),
          assertion(First.observation.status == failed),
          effect_execute(test_failure, tool, Request, _{}, Authority, Second),
          assertion(Second.source == replay),
          assertion(Second.observation == First.observation),
          submit_count(1)
        )).

test(adapter_exception_after_dispatch_becomes_indeterminate_not_retry) :-
    with_executor(
        ( request(exception, Request),
          authority_ref(Authority),
          effect_execute(test_exception, tool, Request, _{}, Authority, Result),
          assertion(Result.state == indeterminate),
          submit_count(1),
          effect_execute(test_exception, tool, Request, _{}, Authority, Again),
          assertion(Again.state == indeterminate),
          submit_count(1)
        )).

test(second_wrapper_while_remote_running_does_not_submit_again) :-
    with_executor(
        setup_call_cleanup(
            create_executor_gate(Entered, Release),
            ( request(running, Request),
              authority_ref(Authority),
              effect_execute_async(test_blocking, tool, Request, _{}, Authority,
                                   FirstFuture),
              thread_get_message(Entered, entered(AttemptId)),
              effect_execute_async(test_blocking, tool, Request, _{}, Authority,
                                   SecondFuture),
              rlm_future_await(SecondFuture, SecondResult),
              thread_get_message(Entered, reconciled(AttemptId)),
              assertion(SecondResult.state == indeterminate),
              submit_count(1),
              thread_send_message(Release, release),
              rlm_future_await(FirstFuture, FirstResult),
              assertion(FirstResult.state == observed),
              rlm_effect_status(AttemptId, FinalAttempt),
              assertion(FinalAttempt.status == observed),
              submit_count(1),
              rlm_future_destroy(SecondFuture),
              rlm_future_destroy(FirstFuture) ),
            destroy_executor_gate(Entered, Release))).

test(cancelling_inflight_future_preserves_uncertain_remote_state) :-
    with_executor(
        setup_call_cleanup(
            create_executor_gate(Entered, Release),
            ( request(cancel_running, Request),
              authority_ref(Authority),
              effect_execute_async(test_blocking, tool, Request, _{}, Authority,
                                   Future),
              thread_get_message(Entered, entered(AttemptId)),
              rlm_future_cancel(Future, ok(cancelled)),
              rlm_future_destroy(Future),
              rlm_effect_status(AttemptId, Attempt),
              assertion(Attempt.status == indeterminate),
              submit_count(1),
              effect_execute(test_blocking, tool, Request, _{}, Authority,
                             AfterCancel),
              assertion(AfterCancel.state == indeterminate),
              submit_count(1) ),
            destroy_executor_gate(Entered, Release))).

test(provider_confirmed_cancel_becomes_authoritative_observation) :-
    with_executor(
        setup_call_cleanup(
            create_executor_gate(Entered, Release),
            ( request(cancel_confirmed, Request),
              authority_ref(Authority),
              effect_execute_async(test_cancel_confirmed, tool, Request, _{},
                                   Authority, Future),
              thread_get_message(Entered, entered(AttemptId)),
              rlm_future_cancel(Future, ok(cancelled)),
              rlm_future_destroy(Future),
              rlm_effect_status(AttemptId, Attempt),
              assertion(Attempt.status == observed),
              rlm_effect_observation(AttemptId, Observation),
              assertion(Observation.status == cancelled),
              effect_execute(test_cancel_confirmed, tool, Request, _{},
                             Authority, Replay),
              assertion(Replay.source == replay),
              assertion(Replay.observation == Observation),
              submit_count(1) ),
            destroy_executor_gate(Entered, Release))).

create_executor_gate(Entered, Release) :-
    message_queue_create(Entered),
    message_queue_create(Release),
    assertz(executor_gate(Entered, Release)).

destroy_executor_gate(Entered, Release) :-
    retractall(executor_gate(_, _)),
    catch(message_queue_destroy(Entered), _, true),
    catch(message_queue_destroy(Release), _, true).

:- end_tests(rlm_effect_executor).
