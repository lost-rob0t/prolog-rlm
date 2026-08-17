:- begin_tests(rlm_effect_authority).

:- use_module('../prolog/rlm_effect').
:- use_module('../prolog/rlm_effect_authority').
:- use_module('../prolog/rlm_effect_executor').
:- use_module('../prolog/rlm_authority').

setup_fixture(File, Context) :-
    tmp_file(rlm_effect_authority, File),
    rlm_effect_store_open(File),
    Context = runtime(effect_authority_test),
    rlm_authority_clear(Context).

cleanup_fixture(File, Context) :-
    catch(rlm_authority_clear(Context), _, true),
    catch(rlm_effect_store_close, _, true),
    catch(delete_file(File), _, true).

dummy_continuation(ok(dummy)).
dummy_edit_validator(Operation, Operation,
                     plunit_rlm_effect_authority:dummy_continuation).

base_operation(Ticket,
               authority_operation{name:effect_fixture,
                                   effect:write,
                                   capability:tool(effect_fixture),
                                   args:Ticket.request}).

authorize(Context, Ticket, Outcome) :-
    base_operation(Ticket, Operation),
    effect_authorize(Context, Ticket, Operation,
                     plunit_rlm_effect_authority:dummy_continuation,
                     plunit_rlm_effect_authority:dummy_edit_validator,
                     Outcome).

complete_once(Context, Ticket, Permit) :-
    rlm_effect_admit(Ticket,
                     authority_ref{fingerprint:Permit.fingerprint,
                                   tier:Permit.kind},
                     execute(Attempt)),
    rlm_effect_dispatch(Attempt.attempt_id, dispatch(_)),
    Observation = observation{status:succeeded,
                              value:done,
                              usage:usage{units:1},
                              provenance:authority_fake},
    rlm_effect_observe(Attempt.attempt_id, Observation, observed(_)),
    rlm_authority_complete_once(Context, Permit.fingerprint, ok(done)).

test(correlation_does_not_change_authority_fingerprint) :-
    setup_call_cleanup(
        setup_fixture(File, Context),
        ( rlm_effect_prepare(tool, request{target:a}, _{}, execute(Ticket)),
          base_operation(Ticket, Base),
          effect_authority_operation(Ticket, Base, correlation{trace:a}, A),
          effect_authority_operation(Ticket, Base, correlation{trace:b}, B),
          rlm_operation_fingerprint(Context, A, FA),
          rlm_operation_fingerprint(Context, B, FB),
          assertion(FA == FB) ),
        cleanup_fixture(File, Context)).

test(retry_requires_fresh_authority_after_allow_once) :-
    setup_call_cleanup(
        setup_fixture(File, Context),
        ( rlm_set_authority(Context, allow_once, ok(_)),
          Request = request{target:retry},
          rlm_effect_prepare(tool, Request, _{}, execute(Initial)),
          authorize(Context, Initial, execute(Permit)),
          complete_once(Context, Initial, Permit),
          rlm_effect_prepare(tool, Request,
                             _{mode:retry,
                               parent_attempt:Initial.attempt_id},
                             execute(Retry)),
          authorize(Context, Retry, approval_required(Pending)),
          rlm_deny(Pending.id, test_cleanup, ok(_)) ),
        cleanup_fixture(File, Context)).

test(changed_payload_cannot_reuse_allow_once) :-
    setup_call_cleanup(
        setup_fixture(File, Context),
        ( rlm_set_authority(Context, allow_once, ok(_)),
          Options = _{logical_key:stable_job},
          rlm_effect_prepare(tool, request{target:a}, Options, execute(A)),
          authorize(Context, A, execute(Permit)),
          complete_once(Context, A, Permit),
          rlm_effect_prepare(tool, request{target:b}, Options, execute(B)),
          assertion(A.call_id == B.call_id),
          assertion(A.fingerprint \== B.fingerprint),
          authorize(Context, B, approval_required(Pending)),
          rlm_deny(Pending.id, test_cleanup, ok(_)) ),
        cleanup_fixture(File, Context)).

test(changed_adapter_has_distinct_exact_authority_identity) :-
    setup_call_cleanup(
        setup_fixture(File, Context),
        ( Request = request{target:adapter_authority},
          effect_prepare(authority_adapter_a, tool, Request, _{}, execute(A)),
          effect_prepare(authority_adapter_b, tool, Request, _{}, execute(B)),
          base_operation(A, BaseA),
          base_operation(B, BaseB),
          effect_authority_operation(A, BaseA, correlation{}, OperationA),
          effect_authority_operation(B, BaseB, correlation{}, OperationB),
          rlm_operation_fingerprint(Context, OperationA, FingerprintA),
          rlm_operation_fingerprint(Context, OperationB, FingerprintB),
          assertion(FingerprintA \== FingerprintB) ),
        cleanup_fixture(File, Context)).

test(parallel_allow_once_has_one_authority_owner) :-
    setup_call_cleanup(
        setup_fixture(File, Context),
        ( rlm_set_authority(Context, allow_once, ok(_)),
          rlm_effect_prepare(tool, request{target:parallel}, _{}, execute(Ticket)),
          message_queue_create(Start),
          message_queue_create(Results),
          thread_create(authority_candidate(Context, Ticket, Start, Results), T1, []),
          thread_create(authority_candidate(Context, Ticket, Start, Results), T2, []),
          thread_send_message(Start, go),
          thread_send_message(Start, go),
          thread_get_message(Results, R1),
          thread_get_message(Results, R2),
          thread_join(T1, true),
          thread_join(T2, true),
          message_queue_destroy(Start),
          message_queue_destroy(Results),
          select(execute(Permit), [R1,R2], [Other]),
          assertion(Other = error(Error)),
          assertion(Error.kind == allow_once_in_progress),
          complete_once(Context, Ticket, Permit),
          rlm_authority(Context, approve_diff) ),
        cleanup_fixture(File, Context)).

authority_candidate(Context, Ticket, Start, Results) :-
    thread_get_message(Start, go),
    authorize(Context, Ticket, Outcome),
    thread_send_message(Results, Outcome).

:- end_tests(rlm_effect_authority).
