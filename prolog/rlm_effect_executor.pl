:- module(rlm_effect_executor,
          [ effect_execute/6,
            effect_execute_async/6,
            effect_execute_execute/6,
            effect_prepare/5,
            effect_reconcile/3,
            effect_adapter_submit/4,
            effect_adapter_reconcile/4,
            effect_adapter_cancel/4
          ]).

/** <module> Canonical execution harness for durable external effects

Provider and tool libraries extend the static multifile adapter hooks below.
These are code-owned extension points, never runtime/model-writable facts.

The #54 direction remains:

  effect_execute_execute/6 -> rlm_async Future -> sync await wrapper

The harness crosses the external boundary only after #57 has durably recorded
`dispatching`. Any ordinary adapter exception after that point is preserved as
an indeterminate remote outcome rather than interpreted as permission to submit
again. A provider may also report `in_progress(Detail)` when it positively knows
the original operation is still running; that is not collapsed into unknown
state. Async cancellation remains a control signal and is re-thrown after the
attempt lifecycle is updated conservatively.
*/

:- use_module(rlm_async, []).
:- use_module(rlm_effect, []).
:- use_module(rlm_effect_persist, []).

:- multifile effect_adapter_submit/4.
:- multifile effect_adapter_reconcile/4.
:- multifile effect_adapter_cancel/4.

%! effect_adapter_submit(+Adapter,+Attempt,+NormalizedRequest,-Outcome)
%
%  Outcome is observed(Observation), in_progress(Detail), or
%  indeterminate(Reason).

%! effect_adapter_reconcile(+Adapter,+Attempt,+NormalizedRequest,-Outcome)
%
%  Optional read-only reconciliation hook with the same outcome protocol. No
%  matching clause means reconciliation is unsupported.

%! effect_adapter_cancel(+Adapter,+Attempt,+NormalizedRequest,-Outcome)
%
%  Optional cancellation hook. Confirmed cancellation returns an observed
%  cancellation; uncertain cancellation returns indeterminate(Reason).

effect_execute_async(Adapter, Kind, Request, EffectOptions, AuthorityRef,
                     Future) :-
    executor_metadata(Adapter, Kind, EffectOptions, Metadata),
    rlm_async:rlm_async_submit(
        rlm_effect_executor:effect_execute_execute(
                              Adapter, Kind, Request,
                              EffectOptions, AuthorityRef),
        Metadata,
        Future).

effect_execute(Adapter, Kind, Request, EffectOptions, AuthorityRef, Outcome) :-
    effect_execute_async(Adapter, Kind, Request, EffectOptions,
                         AuthorityRef, Future),
    setup_call_cleanup(
        true,
        rlm_async:rlm_future_await(Future, Outcome),
        rlm_async:rlm_future_destroy(Future)).

effect_execute_execute(Adapter, Kind, Request, EffectOptions, AuthorityRef,
                       Outcome) :-
    (   rlm_effect:rlm_effect_store_id(StoreId)
    ->  catch(setup_call_cleanup(
                  rlm_effect_persist:effect_persist_acquire_lease(StoreId,
                                                                  Lease),
                  effect_execute_leased(Adapter, Kind, Request, EffectOptions,
                                        AuthorityRef, Outcome),
                  rlm_effect_persist:effect_persist_release_lease(Lease)),
              Exception,
              executor_exception(Exception, Outcome))
    ;   effect_prepare(Adapter, Kind, Request, EffectOptions, Decision),
        execute_after_prepare(Decision, Adapter, AuthorityRef, Outcome)
    ).

effect_execute_leased(Adapter, Kind, Request, EffectOptions, AuthorityRef,
                      Outcome) :-
    effect_prepare(Adapter, Kind, Request, EffectOptions, Decision),
    execute_after_prepare(Decision, Adapter, AuthorityRef, Outcome).

effect_prepare(Adapter, Kind, Request, EffectOptions0, Outcome) :-
    catch(( trusted_executor_options(Adapter, EffectOptions0, EffectOptions),
            rlm_effect:rlm_effect_prepare(Kind, Request, EffectOptions, Outcome)
          ),
          Exception,
          executor_exception(Exception, Outcome)).

trusted_executor_options(Adapter, Options0, Options) :-
    require_adapter_identity(Adapter),
    (   is_dict(Options0), dict_payload_ground(Options0)
    ->  true
    ;   throw(error(domain_error(effect_options, Options0), _))
    ),
    ( get_dict(semantics, Options0, Semantics0) -> true
    ; Semantics0 = semantics{} ),
    ( get_dict(metadata, Options0, Metadata0) -> true
    ; Metadata0 = metadata{} ),
    (   is_dict(Semantics0), is_dict(Metadata0)
    ->  true
    ;   throw(error(domain_error(effect_options, Options0), _))
    ),
    ExecutorIdentity = executor_identity{adapter:Adapter},
    put_dict(executor_identity, Semantics0, ExecutorIdentity, Semantics),
    put_dict(executor_identity, Metadata0, ExecutorIdentity, Metadata),
    Options = Options0.put(_{semantics:Semantics, metadata:Metadata}).

dict_payload_ground(Dict) :-
    dict_pairs(Dict, _, Pairs),
    ground(Pairs).

require_adapter_identity(Adapter) :-
    atom(Adapter),
    Adapter \== '',
    !.
require_adapter_identity(Adapter) :-
    throw(error(domain_error(effect_adapter_identity, Adapter), _)).

execute_after_prepare(error(Error), _, _, error(Error)) :- !.
execute_after_prepare(replay(Observation), _, _,
                      effect_result{state:observed,
                                    source:replay,
                                    observation:Observation}) :- !.
execute_after_prepare(in_progress(Attempt), _, _,
                      effect_result{state:in_progress,
                                    source:ledger,
                                    attempt:Attempt}) :- !.
execute_after_prepare(terminal(Attempt), _, _,
                      effect_result{state:terminal,
                                    source:ledger,
                                    attempt:Attempt}) :- !.
execute_after_prepare(reconciliation_required(Attempt), Adapter, _, Outcome) :-
    !,
    reconcile_attempt(Adapter, Attempt, Outcome).
execute_after_prepare(execute(Ticket), Adapter, AuthorityRef, Outcome) :-
    catch(execute_ticket(Adapter, Ticket, AuthorityRef, Outcome),
          rlm_async_cancelled(FutureId),
          ( cancel_interrupted_ticket(Adapter, Ticket, Ticket.request, FutureId),
            throw(rlm_async_cancelled(FutureId)) )).

execute_ticket(Adapter, Ticket, AuthorityRef, Outcome) :-
    rlm_effect:rlm_effect_admit(Ticket, AuthorityRef, Admission),
    execute_after_admission(Admission, Adapter, Ticket.request, Outcome).

execute_after_admission(error(Error), _, _, error(Error)) :- !.
execute_after_admission(replay(Observation), _, _,
                        effect_result{state:observed,
                                      source:admission_race_replay,
                                      observation:Observation}) :- !.
execute_after_admission(in_progress(Attempt), _, _,
                        effect_result{state:in_progress,
                                      source:admission_race,
                                      attempt:Attempt}) :- !.
execute_after_admission(terminal(Attempt), _, _,
                        effect_result{state:terminal,
                                      source:ledger,
                                      attempt:Attempt}) :- !.
execute_after_admission(execute(Attempt), Adapter, Request, Outcome) :-
    rlm_effect:rlm_effect_dispatch(Attempt.attempt_id, Dispatch),
    execute_after_dispatch(Dispatch, Adapter, Request, Outcome).

execute_after_dispatch(error(Error), _, _, error(Error)) :- !.
execute_after_dispatch(replay(Observation), _, _,
                       effect_result{state:observed,
                                     source:dispatch_race_replay,
                                     observation:Observation}) :- !.
execute_after_dispatch(in_progress(Attempt), _, _,
                       effect_result{state:in_progress,
                                     source:dispatch_race,
                                     attempt:Attempt}) :- !.
execute_after_dispatch(reconciliation_required(Attempt), Adapter, _, Outcome) :-
    !,
    reconcile_attempt(Adapter, Attempt, Outcome).
execute_after_dispatch(terminal(Attempt), _, _,
                       effect_result{state:terminal,
                                     source:ledger,
                                     attempt:Attempt}) :- !.
execute_after_dispatch(dispatch(Attempt), Adapter, Request, Outcome) :-
    call_submit_adapter(Adapter, Attempt, Request, AdapterOutcome),
    apply_adapter_outcome(submit, Attempt, AdapterOutcome, Outcome).

call_submit_adapter(Adapter, Attempt, Request, Outcome) :-
    catch(call_submit_adapter_(Adapter, Attempt, Request, Outcome),
          Exception,
          submit_exception(Exception, Outcome)).

call_submit_adapter_(Adapter, Attempt, Request, Outcome) :-
    (   effect_adapter_submit(Adapter, Attempt, Request, Found)
    ->  Outcome = Found
    ;   Outcome = indeterminate(adapter_failed_without_outcome)
    ).

submit_exception(rlm_async_cancelled(Id), _) :-
    !,
    throw(rlm_async_cancelled(Id)).
submit_exception(Exception, indeterminate(adapter_exception(Safe))) :-
    safe_exception(Exception, Safe).

apply_adapter_outcome(Source, Attempt, observed(Observation0), Outcome) :-
    !,
    rlm_effect:rlm_effect_observe(Attempt.attempt_id, Observation0, Recorded),
    adapter_record_result(Source, Attempt, Recorded, Outcome).
apply_adapter_outcome(Source, Attempt, in_progress(Detail),
                      effect_result{state:in_progress,
                                    source:Source,
                                    attempt:Attempt,
                                    detail:Detail}) :-
    !.
apply_adapter_outcome(_, Attempt, indeterminate(Reason),
                      effect_result{state:indeterminate,
                                    source:adapter,
                                    attempt:Unknown}) :-
    !,
    rlm_effect:rlm_effect_mark_indeterminate(Attempt.attempt_id, Reason,
                                             Marked),
    marked_attempt(Marked, Attempt, Unknown).
apply_adapter_outcome(_, Attempt, Invalid,
                      effect_result{state:indeterminate,
                                    source:adapter_protocol_error,
                                    attempt:Unknown}) :-
    rlm_effect:rlm_effect_mark_indeterminate(
                   Attempt.attempt_id,
                   invalid_adapter_outcome(Invalid),
                   Marked),
    marked_attempt(Marked, Attempt, Unknown).

adapter_record_result(Source, _, observed(Observation),
                      effect_result{state:observed,
                                    source:Source,
                                    observation:Observation}) :- !.
adapter_record_result(_, Attempt, error(Error),
                      effect_result{state:indeterminate,
                                    source:observation_rejected,
                                    error:Error,
                                    attempt:Unknown}) :-
    !,
    rlm_effect:rlm_effect_mark_indeterminate(
                   Attempt.attempt_id,
                   observation_rejected(Error),
                   Marked),
    marked_attempt(Marked, Attempt, Unknown).
adapter_record_result(Source, _, replay(Observation),
                      effect_result{state:observed,
                                    source:Source,
                                    observation:Observation}).

marked_attempt(indeterminate(Attempt), _, Attempt) :- !.
marked_attempt(reconciliation_required(Attempt), _, Attempt) :- !.
marked_attempt(replay(_), Fallback, Fallback) :- !.
marked_attempt(_, Fallback, Fallback).

/* Reconciliation -------------------------------------------------------- */

effect_reconcile(Adapter, AttemptId, Outcome) :-
    (   rlm_effect:rlm_effect_store_id(StoreId)
    ->  catch(setup_call_cleanup(
                  rlm_effect_persist:effect_persist_acquire_lease(StoreId,
                                                                  Lease),
                  effect_reconcile_leased(Adapter, AttemptId, Outcome),
                  rlm_effect_persist:effect_persist_release_lease(Lease)),
              Exception,
              executor_exception(Exception, Outcome))
    ;   Outcome = error(effect_error{kind:store_not_open})
    ).

effect_reconcile_leased(Adapter, AttemptId, Outcome) :-
    rlm_effect:rlm_effect_status(AttemptId, Status),
    reconcile_from_status(Status, Adapter, Outcome).

reconcile_from_status(error(Error), _, error(Error)) :- !.
reconcile_from_status(Attempt, Adapter, Outcome) :-
    reconcile_attempt(Adapter, Attempt, Outcome).

reconcile_attempt(Adapter, Attempt, Outcome) :-
    (   adapter_identity_matches(Adapter, Attempt)
    ->  reconcile_matching_adapter(Adapter, Attempt, Outcome)
    ;   attempt_adapter_identity_or_unknown(Attempt, Expected),
        Outcome = error(effect_error{kind:adapter_identity_mismatch,
                                     expected:Expected,
                                     actual:Adapter})
    ).

reconcile_matching_adapter(_, Attempt,
                           effect_result{state:observed,
                                         source:local_observation,
                                         observation:Observation}) :-
    rlm_effect:rlm_effect_observation(Attempt.attempt_id, Observation),
    is_dict(Observation),
    \+ is_dict(Observation, error),
    !.
reconcile_matching_adapter(Adapter, Attempt, Outcome) :-
    request_for_attempt(Attempt, Request),
    call_reconcile_adapter(Adapter, Attempt, Request, AdapterOutcome),
    apply_reconcile_outcome(Attempt, AdapterOutcome, Outcome).

adapter_identity_matches(Adapter, Attempt) :-
    attempt_adapter_identity(Attempt, Expected),
    Expected == Adapter.

attempt_adapter_identity(Attempt, Adapter) :-
    get_dict(executor_identity, Attempt.metadata, Identity),
    is_dict(Identity, executor_identity),
    get_dict(adapter, Identity, Adapter),
    atom(Adapter).
attempt_adapter_identity(Attempt, Adapter) :-
    rlm_effect_persist:effect_persist_legacy_adapter(Attempt.attempt_id,
                                                     Adapter).

attempt_adapter_identity_or_unknown(Attempt, Adapter) :-
    ( attempt_adapter_identity(Attempt, Found) -> Adapter = Found
    ; Adapter = unknown ).

request_for_attempt(Attempt, Request) :-
    (   rlm_effect_persist:effect_persist_get_call(
            Attempt.call_id, Attempt.fingerprint, Call)
    ->  Request = Call.request
    ;   Request = unavailable
    ).

call_reconcile_adapter(Adapter, Attempt, Request, Outcome) :-
    catch((   effect_adapter_reconcile(Adapter, Attempt, Request, Found)
          ->  Outcome = Found
          ;   Outcome = indeterminate(reconciliation_unsupported)
          ),
          Exception,
          reconcile_exception(Exception, Outcome)).

reconcile_exception(rlm_async_cancelled(Id), _) :-
    !,
    throw(rlm_async_cancelled(Id)).
reconcile_exception(Exception,
                    indeterminate(reconciliation_exception(Safe))) :-
    safe_exception(Exception, Safe).

apply_reconcile_outcome(Attempt, observed(Observation0),
                        Outcome) :-
    !,
    rlm_effect:rlm_effect_reconcile(Attempt.attempt_id, Observation0,
                                    Reconciled),
    reconcile_record_result(Reconciled, Outcome).
apply_reconcile_outcome(Attempt, in_progress(Detail),
                        effect_result{state:in_progress,
                                      source:reconciliation,
                                      attempt:Attempt,
                                      detail:Detail}) :-
    !.
apply_reconcile_outcome(Attempt, indeterminate(Reason),
                        effect_result{state:indeterminate,
                                      source:reconciliation,
                                      attempt:Unknown}) :-
    !,
    mark_if_needed(Attempt, Reason, Unknown).
apply_reconcile_outcome(Attempt, Invalid,
                        effect_result{state:indeterminate,
                                      source:reconciliation_protocol_error,
                                      attempt:Unknown}) :-
    mark_if_needed(Attempt, invalid_reconcile_outcome(Invalid), Unknown).

reconciled_observation(reconciled(Observation), Observation) :- !.
reconciled_observation(observed(Observation), Observation) :- !.
reconciled_observation(replay(Observation), Observation).

reconcile_record_result(Reconciled,
                        effect_result{state:observed,
                                      source:reconciliation,
                                      observation:Observation}) :-
    reconciled_observation(Reconciled, Observation),
    !.
reconcile_record_result(error(Error), error(Error)) :- !.
reconcile_record_result(Other,
                        error(effect_error{kind:reconciliation_record_failed,
                                           detail:Other})).

mark_if_needed(Attempt, _, Attempt) :-
    Attempt.status == indeterminate,
    !.
mark_if_needed(Attempt, Reason, Unknown) :-
    rlm_effect:rlm_effect_mark_indeterminate(Attempt.attempt_id, Reason, Marked),
    marked_attempt(Marked, Attempt, Unknown).

/* Cancellation ---------------------------------------------------------- */

cancel_interrupted_ticket(Adapter, Ticket, Request, FutureId) :-
    rlm_effect:rlm_effect_status(Ticket.attempt_id, Status),
    cancel_from_status(Status, Adapter, Ticket, Request, FutureId).

cancel_from_status(error(_), _, Ticket, _, FutureId) :-
    !,
    rlm_effect:rlm_effect_cancel_ticket(Ticket,
                                        async_cancelled(FutureId), _).
cancel_from_status(Attempt, Adapter, _, Request, FutureId) :-
    (   Attempt.status == dispatching
    ->  try_adapter_cancel(Adapter, Attempt, Request, FutureId)
    ;   rlm_effect:rlm_effect_cancel(Attempt.attempt_id,
                                     async_cancelled(FutureId), _)
    ).

try_adapter_cancel(Adapter, Attempt, Request, FutureId) :-
    rlm_effect:rlm_effect_cancel(Attempt.attempt_id,
                                 async_cancelled(FutureId), CancelState),
    (   catch(effect_adapter_cancel(Adapter, Attempt, Request, AdapterOutcome),
              _, fail)
    ->  apply_cancel_adapter_outcome(Attempt, AdapterOutcome)
    ;   preserve_cancel_uncertainty(CancelState)
    ).

apply_cancel_adapter_outcome(Attempt, observed(Observation)) :-
    !,
    rlm_effect:rlm_effect_observe(Attempt.attempt_id, Observation, _).
apply_cancel_adapter_outcome(Attempt, indeterminate(Reason)) :-
    !,
    rlm_effect:rlm_effect_mark_indeterminate(Attempt.attempt_id, Reason, _).
apply_cancel_adapter_outcome(Attempt, Invalid) :-
    rlm_effect:rlm_effect_mark_indeterminate(
                   Attempt.attempt_id,
                   invalid_cancel_outcome(Invalid), _).

preserve_cancel_uncertainty(reconciliation_required(_)) :- !.
preserve_cancel_uncertainty(_).

/* Future metadata ------------------------------------------------------- */

executor_metadata(Adapter, Kind, Options,
                  async_metadata{operation:effect_execute,
                                 adapter:Adapter,
                                 kind:Kind,
                                 correlation:Correlation}) :-
    (   is_dict(Options),
        get_dict(metadata, Options, Metadata),
        is_dict(Metadata)
    ->  Correlation = Metadata
    ;   Correlation = metadata{}
    ).

safe_exception(Exception, Safe) :-
    catch(term_string(Exception, Safe,
                      [quoted(true), numbervars(true), max_depth(6)]),
          _,
          Safe = "unavailable").

executor_exception(error(permission_error(_, effect_store, Detail), _),
                   error(effect_error{kind:store_lifecycle_conflict,
                                      detail:Safe})) :-
    !,
    safe_exception(Detail, Safe).
executor_exception(error(permission_error(acquire, effect_store_lease,
                                           Detail), _),
                   error(effect_error{kind:store_lifecycle_conflict,
                                      detail:Safe})) :-
    !,
    safe_exception(Detail, Safe).
executor_exception(error(domain_error(effect_adapter_identity, Adapter), _),
                   error(effect_error{kind:invalid_adapter_identity,
                                      adapter:Adapter})) :- !.
executor_exception(error(domain_error(effect_options, _), _),
                   error(effect_error{kind:invalid_options})) :- !.
executor_exception(Exception,
                   error(effect_error{kind:executor_internal_error,
                                      detail:Safe})) :-
    safe_exception(Exception, Safe).
