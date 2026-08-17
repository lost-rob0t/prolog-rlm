:- module(rlm_authority,
          [ rlm_authority/2,
            rlm_set_authority_if_unset/3,
            rlm_set_authority/3,
            rlm_authority_narrow/3,
            rlm_authority_child/4,
            rlm_authority_clear/1,
            rlm_authority_clear_runtime/1,
            rlm_effect_class/1,
            rlm_operation_fingerprint/3,
            rlm_authorize_operation/5,
            rlm_authority_complete_once/3,
            rlm_pending_approval/3,
            rlm_pending_approvals/2,
            rlm_pending_resolution_async/2,
            rlm_pending_resolution/2,
            rlm_authority_events/2,
            rlm_approve/2,
            rlm_deny/3,
            rlm_edit/3,
            rlm_pending_cancel_owner/2
          ]).

/** <module> Host-owned authority and non-blocking pending operations

Authority is mediation of an already valid, capability-permitted, normalized
operation. It never replaces schemas, confinement, process/network policy,
budgets, timeouts, output limits, tracing or accounting.

The canonical modes are exactly:

  approve_diff < allow_once < allow_session < dangerous

Unset contexts read as approve_diff. Host code may select a mode explicitly;
children may only inherit the same or a stricter mode. There is deliberately no
`yolo` alias.

Human approval is unbounded wall-clock latency. approve_diff therefore creates
in-process pending state backed by a deferred Future that is *not* queued on the
shared rlm_async worker pool. Approval later schedules only the trusted exact
continuation. A short private execution gate arms the scheduled task only after
its Future is attached to authority state. Cancellation and execution then race
one mutex-protected execution claim: cancellation before the claim means the
continuation can never run; cancellation after the claim is best-effort async
interruption of work that has already crossed the authoritative boundary.

Terminal pending records are retained only as bounded sanitized history. Their
trusted continuation/edit-validator state is dropped immediately, execution
Futures are released after terminal transfer, and only the bounded public
resolution Future remains queryable until that history entry is pruned.
*/

:- use_module(library(crypto)).
:- use_module(library(gensym)).
:- use_module(rlm_async, []).

:- dynamic authority_mode/2.
:- dynamic authority_once/4.
:- dynamic authority_pending/3.
:- dynamic authority_pending_control/5.
:- dynamic authority_pending_gate/2.
:- dynamic authority_terminal_resolution/3.
:- dynamic authority_sequence/2.
:- dynamic authority_event/3.

terminal_history_limit(64).

/* Modes ----------------------------------------------------------------- */

mode_rank(approve_diff, 0).
mode_rank(allow_once, 1).
mode_rank(allow_session, 2).
mode_rank(dangerous, 3).

rlm_authority(Context, Mode) :-
    require_context(Context),
    with_mutex(rlm_authority, current_mode_locked(Context, Mode)).

rlm_set_authority_if_unset(Context, Mode, Outcome) :-
    catch(( require_context(Context),
            require_mode(Mode),
            with_mutex(rlm_authority,
                       set_if_unset_locked(Context, Mode, Outcome))
          ),
          Exception,
          authority_exception(set_if_unset, Exception, Outcome)).

set_if_unset_locked(Context, _,
                    ok(authority_unchanged{context:Context, mode:Existing})) :-
    authority_mode(Context, Existing),
    !.
set_if_unset_locked(Context, Mode,
                    ok(authority_set{context:Context, mode:Mode})) :-
    assertz(authority_mode(Context, Mode)),
    event_locked(Context, authority_set,
                 _{mode:Mode, source:set_if_unset}).

rlm_set_authority(Context, Mode, Outcome) :-
    catch(( require_context(Context),
            require_mode(Mode),
            with_mutex(rlm_authority,
                       set_authority_locked(Context, Mode, Outcome))
          ),
          Exception,
          authority_exception(set, Exception, Outcome)).

set_authority_locked(Context, Mode,
                     ok(authority_set{context:Context,
                                      previous:Previous,
                                      mode:Mode})) :-
    current_mode_locked(Context, Previous),
    retractall(authority_mode(Context, _)),
    retractall(authority_once(Context, _, _, _)),
    assertz(authority_mode(Context, Mode)),
    event_locked(Context, authority_set,
                 _{mode:Mode, previous:Previous, source:trusted_host}).

rlm_authority_narrow(Parent, Requested, Outcome) :-
    catch(( require_mode(Parent),
            require_mode(Requested),
            mode_rank(Parent, ParentRank),
            mode_rank(Requested, RequestedRank),
            (   RequestedRank =< ParentRank
            ->  Outcome = ok(Requested)
            ;   Outcome = error(authority_error{
                                    kind:widening_denied,
                                    parent:Parent,
                                    requested:Requested,
                                    message:"child authority may only stay equal or narrow"
                                })
            )
          ),
          Exception,
          authority_exception(narrow, Exception, Outcome)).

rlm_authority_child(ParentContext, ChildContext, Requested0, Outcome) :-
    catch(( require_context(ParentContext),
            require_context(ChildContext),
            rlm_authority(ParentContext, ParentMode),
            child_requested_mode(Requested0, ParentMode, Requested),
            rlm_authority_narrow(ParentMode, Requested, NarrowOutcome),
            child_after_narrow(NarrowOutcome, ChildContext, Outcome)
          ),
          Exception,
          authority_exception(child, Exception, Outcome)).

child_requested_mode(inherit, Parent, Parent) :- !.
child_requested_mode(none, Parent, Parent) :- !.
child_requested_mode(Requested, _, Requested) :- require_mode(Requested).

child_after_narrow(error(Error), _, error(Error)) :- !.
child_after_narrow(ok(Mode), Context,
                   ok(authority_child{context:Context, mode:Mode})) :-
    with_mutex(rlm_authority,
               ( retractall(authority_mode(Context, _)),
                 retractall(authority_once(Context, _, _, _)),
                 assertz(authority_mode(Context, Mode)),
                 event_locked(Context, authority_inherited, _{mode:Mode})
               )).

current_mode_locked(Context, Mode) :-
    ( authority_mode(Context, Found) -> Mode = Found ; Mode = approve_diff ).

require_mode(Mode) :- mode_rank(Mode, _), !.
require_mode(Mode) :- throw(authority_fault(invalid_mode(Mode))).

/* Effects and exact fingerprint ---------------------------------------- */

rlm_effect_class(read).
rlm_effect_class(write).
rlm_effect_class(process).
rlm_effect_class(network_write).
rlm_effect_class(install).
rlm_effect_class(service_start).
rlm_effect_class(service_stop).
rlm_effect_class(repository_mutation).

rlm_operation_fingerprint(Context, Operation0, Fingerprint) :-
    require_context(Context),
    normalize_operation(Operation0, Operation),
    fingerprint_operation(Operation, ExecutableOperation),
    canonical_value(authority_fingerprint{context:Context,
                                          operation:ExecutableOperation},
                    Canonical),
    term_string(Canonical, Serialized,
                [quoted(true), numbervars(true), ignore_ops(true)]),
    crypto_data_hash(Serialized, Hex,
                     [algorithm(sha256), encoding(utf8)]),
    atom_concat('sha256:', Hex, Fingerprint).

fingerprint_operation(Operation, ExecutableOperation) :-
    (   del_dict(correlation, Operation, _, WithoutCorrelation)
    ->  ExecutableOperation = WithoutCorrelation
    ;   ExecutableOperation = Operation
    ).

normalize_operation(Operation0, Operation) :-
    is_dict(Operation0),
    !,
    require_operation_field(Operation0, name, Name),
    require_operation_field(Operation0, effect, Effect),
    require_operation_field(Operation0, capability, Capability),
    require_operation_name(Name),
    require_effect(Effect),
    require_ground(Capability, capability),
    canonical_value(Operation0, Operation).
normalize_operation(Operation, _) :-
    throw(authority_fault(invalid_operation(Operation))).

require_operation_field(Operation, Key, Value) :-
    ( get_dict(Key, Operation, Value)
    -> true
    ;  throw(authority_fault(missing_operation_field(Key)))
    ).

require_operation_name(Name) :- atom(Name), Name \== '', !.
require_operation_name(Name) :-
    throw(authority_fault(invalid_operation_name(Name))).

require_effect(Effect) :- rlm_effect_class(Effect), !.
require_effect(Effect) :- throw(authority_fault(invalid_effect(Effect))).

canonical_value(Value, _) :-
    var(Value),
    !,
    throw(authority_fault(nonground_authority_value)).
canonical_value(Value, Canonical) :-
    is_dict(Value),
    !,
    dict_pairs(Value, Tag, Pairs0),
    keysort(Pairs0, Sorted),
    maplist(canonical_pair, Sorted, Pairs),
    dict_pairs(Canonical, Tag, Pairs).
canonical_value(Value, Canonical) :-
    is_list(Value),
    !,
    maplist(canonical_value, Value, Canonical).
canonical_value(Value, Canonical) :-
    compound(Value),
    !,
    Value =.. [Functor|Args0],
    maplist(canonical_value, Args0, Args),
    Canonical =.. [Functor|Args].
canonical_value(Value, Value) :- atomic(Value), !.
canonical_value(Value, _) :-
    throw(authority_fault(invalid_authority_value(Value))).

canonical_pair(Key-Value0, Key-Value) :- canonical_value(Value0, Value).

/* Decision boundary ---------------------------------------------------- */

rlm_authorize_operation(Context, Operation0, Continuation, EditValidator,
                        Outcome) :-
    catch(authorize_operation_(Context, Operation0, Continuation,
                               EditValidator, Outcome),
          Exception,
          authority_exception(authorize, Exception, Outcome)).

authorize_operation_(Context, Operation0, Continuation, EditValidator,
                     Outcome) :-
    require_context(Context),
    require_host_continuation(Continuation),
    require_edit_validator(EditValidator),
    normalize_operation(Operation0, Operation),
    rlm_operation_fingerprint(Context, Operation, Fingerprint),
    authorize_normalized(Context, Operation, Fingerprint,
                         Continuation, EditValidator, Outcome).

authorize_normalized(_, Operation, Fingerprint, _, _,
                     execute(authority_permit{kind:read,
                                              fingerprint:Fingerprint})) :-
    Operation.effect == read,
    !.
authorize_normalized(Context, Operation, Fingerprint,
                     Continuation, EditValidator, Outcome) :-
    with_mutex(rlm_authority,
               nonread_decision_locked(Context, Fingerprint, Decision)),
    apply_nonread_decision(Decision, Context, Operation, Fingerprint,
                           Continuation, EditValidator, Outcome).

nonread_decision_locked(Context, Fingerprint, replay(Saved)) :-
    authority_once(Context, Fingerprint, completed, Saved),
    !.
nonread_decision_locked(Context, Fingerprint, once_in_progress) :-
    authority_once(Context, Fingerprint, started, _),
    !.
nonread_decision_locked(Context, Fingerprint, execute(allow_once)) :-
    current_mode_locked(Context, allow_once),
    !,
    retractall(authority_mode(Context, _)),
    assertz(authority_mode(Context, approve_diff)),
    assertz(authority_once(Context, Fingerprint, started, none)),
    event_locked(Context, allow_once_consumed,
                 _{fingerprint:Fingerprint, next_mode:approve_diff}).
nonread_decision_locked(Context, _, execute(Mode)) :-
    current_mode_locked(Context, Mode),
    memberchk(Mode, [allow_session, dangerous]),
    !.
nonread_decision_locked(Context, _, pending) :-
    current_mode_locked(Context, approve_diff),
    !.
nonread_decision_locked(Context, _, invalid(Mode)) :-
    current_mode_locked(Context, Mode).

apply_nonread_decision(replay(Saved), _, _, _, _, _, replay(Saved)) :- !.
apply_nonread_decision(once_in_progress, _, _, Fingerprint, _, _,
                       error(authority_error{
                                 kind:allow_once_in_progress,
                                 fingerprint:Fingerprint,
                                 message:"the exact single-use operation has already started"
                             })) :- !.
apply_nonread_decision(execute(Mode), _, _, Fingerprint, _, _,
                       execute(authority_permit{kind:Mode,
                                                fingerprint:Fingerprint})) :- !.
apply_nonread_decision(pending, Context, Operation, Fingerprint,
                       Continuation, EditValidator, Outcome) :-
    create_pending(Context, Operation, Fingerprint,
                   Continuation, EditValidator, none, Outcome).
apply_nonread_decision(invalid(Mode), _, _, _, _, _,
                       error(authority_error{
                                 kind:invalid_runtime_mode,
                                 mode:Mode,
                                 message:"authority context contains an invalid mode"
                             })).

rlm_authority_complete_once(Context, Fingerprint, Outcome) :-
    require_context(Context),
    with_mutex(rlm_authority,
               (   retract(authority_once(Context, Fingerprint, started, _))
               ->  assertz(authority_once(Context, Fingerprint,
                                          completed, Outcome)),
                   event_locked(Context, allow_once_completed,
                                _{fingerprint:Fingerprint})
               ;   true
               )).

/* Pending records ------------------------------------------------------- */

create_pending(Context, Operation, Fingerprint, Continuation, EditValidator,
               EditedFrom, approval_required(Public)) :-
    resolution_metadata(Context, Fingerprint, Metadata),
    rlm_async:rlm_future_deferred(Metadata, ResolutionFuture),
    catch(with_mutex(rlm_authority,
                     create_pending_locked(Context, Operation, Fingerprint,
                                           Continuation, EditValidator,
                                           ResolutionFuture, EditedFrom,
                                           Public)),
          Exception,
          ( catch(rlm_async:rlm_future_destroy(ResolutionFuture), _, true),
            throw(Exception)
          )).

create_pending_locked(Context, Operation, Fingerprint, Continuation,
                      EditValidator, ResolutionFuture, EditedFrom, Public) :-
    gensym(approval_, ApprovalId),
    get_time(CreatedAt),
    sanitize_value(Operation, PublicOperation),
    pending_correlation(Operation, Correlation),
    Base = pending_operation{id:ApprovalId,
                             operation:PublicOperation,
                             name:Operation.name,
                             effect:Operation.effect,
                             capability:Operation.capability,
                             context:Context,
                             correlation:Correlation,
                             authority:approve_diff,
                             fingerprint:Fingerprint,
                             created_at:CreatedAt,
                             state:pending},
    add_edited_from(EditedFrom, Base, Record),
    assertz(authority_pending(ApprovalId, Context, Record)),
    assertz(authority_pending_control(ApprovalId, Continuation,
                                      EditValidator, ResolutionFuture, none)),
    event_locked(Context, approval_pending,
                 _{approval_id:ApprovalId,
                   fingerprint:Fingerprint,
                   effect:Operation.effect}),
    Public = Record.

add_edited_from(none, Record, Record) :- !.
add_edited_from(OldId, Record0, Record) :-
    put_dict(edited_from, Record0, OldId, Record).

pending_correlation(Operation, Correlation) :-
    ( get_dict(correlation, Operation, Found)
    -> sanitize_value(Found, Correlation)
    ;  Correlation = correlation{}
    ).

resolution_metadata(Context, Fingerprint,
                    async_metadata{operation:authority_pending_resolution,
                                   authority_context:Context,
                                   fingerprint:Fingerprint}).

rlm_pending_approval(Context, ApprovalId, Approval) :-
    require_context(Context),
    authority_pending(ApprovalId, Context, Approval).

rlm_pending_approvals(Context, Approvals) :-
    require_context(Context),
    findall(Id-Approval, authority_pending(Id, Context, Approval), Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Approvals).

rlm_pending_resolution_async(ApprovalId, Future) :-
    (   authority_pending_control(ApprovalId, _, _, Future, _)
    ->  true
    ;   authority_terminal_resolution(ApprovalId, _, Future)
    ->  true
    ;   throw(error(existence_error(rlm_pending_operation, ApprovalId), _))
    ).

rlm_pending_resolution(ApprovalId, Outcome) :-
    rlm_pending_resolution_async(ApprovalId, Future),
    rlm_async:rlm_future_await(Future, Outcome).

rlm_authority_events(Context, Events) :-
    require_context(Context),
    findall(Seq-Event, authority_event(Context, Seq, Event), Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Events).

/* Approval and execution claim ----------------------------------------- */

rlm_approve(ApprovalId, Outcome) :-
    catch(approve_(ApprovalId, Outcome),
          Exception,
          authority_exception(approve, Exception, Outcome)).

approve_(ApprovalId, Outcome) :-
    message_queue_create(Gate, [max_size(1)]),
    catch(( with_mutex(rlm_authority,
                       approve_transition_locked(ApprovalId, Gate,
                                                 Transition, Context, Record,
                                                 Continuation,
                                                 ResolutionFuture)),
            apply_approve_transition(Transition, ApprovalId, Context, Record,
                                     Continuation, ResolutionFuture, Gate,
                                     Outcome) ),
          Exception,
          ( safe_destroy_gate(Gate),
            throw(Exception) )).

approve_transition_locked(ApprovalId, Gate, schedule, Context, Approved,
                          Continuation, ResolutionFuture) :-
    retract(authority_pending(ApprovalId, Context, Record)),
    Record.state == pending,
    !,
    authority_pending_control(ApprovalId, Continuation, _,
                              ResolutionFuture, none),
    put_dict(state, Record, approved, Approved),
    assertz(authority_pending(ApprovalId, Context, Approved)),
    assertz(authority_pending_gate(ApprovalId, Gate)),
    event_locked(Context, approval_granted,
                 _{approval_id:ApprovalId,
                   fingerprint:Record.fingerprint}).
approve_transition_locked(ApprovalId, _, not_pending(State), Context, Record,
                          none, none) :-
    authority_pending(ApprovalId, Context, Record),
    !,
    State = Record.state.
approve_transition_locked(ApprovalId, _, _, _, _, _, _) :-
    throw(authority_fault(unknown_approval(ApprovalId))).

apply_approve_transition(not_pending(State), ApprovalId, _, Record, _, _, Gate,
                         error(authority_error{
                                   kind:approval_not_pending,
                                   approval_id:ApprovalId,
                                   state:State,
                                   fingerprint:Record.fingerprint,
                                   message:"approval is no longer pending"
                               })) :-
    !,
    safe_destroy_gate(Gate).
apply_approve_transition(schedule, ApprovalId, Context, Record,
                         Continuation, ResolutionFuture, Gate, Outcome) :-
    approval_execution_metadata(Record, Metadata),
    catch(rlm_async:rlm_async_submit(
              rlm_authority:pending_execution(
                                ApprovalId, Context, Gate, Continuation),
              Metadata, ExecutionFuture),
          Exception,
          approval_schedule_failed(ApprovalId, Context, ResolutionFuture,
                                   Gate, none, Exception, Outcome)),
    (   var(Outcome)
    ->  catch(rlm_async:rlm_future_on_complete(
                  ExecutionFuture,
                  rlm_authority:pending_execution_complete(
                                    ApprovalId, Context, ResolutionFuture,
                                    ExecutionFuture, Gate)),
              CallbackException,
              approval_schedule_failed(ApprovalId, Context,
                                       ResolutionFuture, Gate,
                                       ExecutionFuture, CallbackException,
                                       Outcome))
    ;   true
    ),
    (   var(Outcome)
    ->  with_mutex(rlm_authority,
                   arm_execution_locked(ApprovalId, Context, ExecutionFuture,
                                        Arm)),
        apply_arm_execution(Arm, ApprovalId, Context, Record,
                            ResolutionFuture, ExecutionFuture, Gate, Outcome)
    ;   true
    ).

arm_execution_locked(ApprovalId, Context, Future, armed(Scheduled)) :-
    retract(authority_pending(ApprovalId, Context, Record)),
    Record.state == approved,
    authority_pending_gate(ApprovalId, _),
    retract(authority_pending_control(ApprovalId, Continuation, Validator,
                                      Resolution, none)),
    !,
    put_dict(state, Record, scheduled, Scheduled),
    assertz(authority_pending(ApprovalId, Context, Scheduled)),
    assertz(authority_pending_control(ApprovalId, Continuation, Validator,
                                      Resolution, Future)),
    event_locked(Context, approval_scheduled,
                 _{approval_id:ApprovalId,
                   fingerprint:Record.fingerprint}).
arm_execution_locked(ApprovalId, Context, _, abandoned(State, Record)) :-
    authority_pending(ApprovalId, Context, Record),
    !,
    State = Record.state.
arm_execution_locked(ApprovalId, _, _, missing(ApprovalId)).

apply_arm_execution(armed(Scheduled), ApprovalId, Context, Record, Resolution,
                    Future, Gate, Outcome) :-
    (   safe_signal_gate(Gate, start)
    ->  Outcome = ok(approval_transition{id:ApprovalId,
                                         state:scheduled,
                                         fingerprint:Record.fingerprint,
                                         approval:Scheduled})
    ;   approval_schedule_failed(
            ApprovalId, Context, Resolution, Gate, Future,
            error(resource_error(approval_execution_gate),
                  context(rlm_approve/2,
                          'could not arm approved execution')),
            Outcome)
    ).
apply_arm_execution(abandoned(State, Record), ApprovalId, _, _, _, Future,
                    Gate,
                    error(authority_error{
                              kind:approval_not_pending,
                              approval_id:ApprovalId,
                              state:State,
                              fingerprint:Record.fingerprint,
                              message:"approval was cancelled before execution was armed"
                          })) :-
    safe_signal_gate(Gate, cancel),
    catch(rlm_async:rlm_future_cancel(Future, _), _, true),
    catch(rlm_async:rlm_future_destroy(Future), _, true),
    safe_destroy_gate(Gate).
apply_arm_execution(missing(ApprovalId), _, _, _, _, Future, Gate,
                    error(authority_error{
                              kind:approval_not_pending,
                              approval_id:ApprovalId,
                              message:"approval disappeared before execution was armed"
                          })) :-
    safe_signal_gate(Gate, cancel),
    catch(rlm_async:rlm_future_cancel(Future, _), _, true),
    catch(rlm_async:rlm_future_destroy(Future), _, true),
    safe_destroy_gate(Gate).

pending_execution(ApprovalId, Context, Gate, Continuation, Outcome) :-
    setup_call_cleanup(
        true,
        pending_execution_wait(ApprovalId, Context, Gate, Continuation,
                               Outcome),
        safe_destroy_gate(Gate)).

pending_execution_wait(ApprovalId, Context, Gate, Continuation, Outcome) :-
    catch(thread_get_message(Gate, Signal), _, Signal = cancel),
    (   Signal == start
    ->  with_mutex(rlm_authority,
                   execution_claim_locked(ApprovalId, Context, Claim)),
        apply_execution_claim(Claim, ApprovalId, Continuation, Outcome)
    ;   cancelled_before_claim_outcome(ApprovalId, Outcome)
    ).

execution_claim_locked(ApprovalId, Context, execute(Executing)) :-
    retract(authority_pending(ApprovalId, Context, Record)),
    Record.state == scheduled,
    !,
    put_dict(state, Record, executing, Executing),
    assertz(authority_pending(ApprovalId, Context, Executing)),
    event_locked(Context, approval_execution_claimed,
                 _{approval_id:ApprovalId,
                   fingerprint:Record.fingerprint}).
execution_claim_locked(ApprovalId, Context, denied(State)) :-
    authority_pending(ApprovalId, Context, Record),
    !,
    State = Record.state.
execution_claim_locked(_, _, denied(missing)).

apply_execution_claim(execute(_), _, Continuation, Outcome) :-
    call(Continuation, Outcome).
apply_execution_claim(denied(_), ApprovalId, _, Outcome) :-
    cancelled_before_claim_outcome(ApprovalId, Outcome).

cancelled_before_claim_outcome(
    ApprovalId,
    error(authority_error{kind:cancelled_before_execution_claim,
                          approval_id:ApprovalId,
                          message:"approval owner cancelled before execution claim"})).

pending_execution_complete(ApprovalId, Context, ResolutionFuture,
                           ExecutionFuture, Gate, Result) :-
    with_mutex(rlm_authority,
               execution_complete_locked(ApprovalId, Context, Result,
                                         Completion, PrunedFutures)),
    apply_execution_completion(Completion, ResolutionFuture, Result),
    safe_destroy_gate(Gate),
    catch(rlm_async:rlm_future_destroy(ExecutionFuture), _, true),
    destroy_futures(PrunedFutures).

execution_complete_locked(ApprovalId, Context, Result,
                          resolve, PrunedFutures) :-
    retract(authority_pending(ApprovalId, Context, Record)),
    memberchk(Record.state, [scheduled, executing, cancelling]),
    !,
    retract_control_locked(ApprovalId, ResolutionFuture, _Execution),
    retractall(authority_pending_gate(ApprovalId, _)),
    sanitize_value(Result, PublicResult),
    completion_terminal_state(Record.state, Result, TerminalState),
    get_time(ResolvedAt),
    put_dict(_{state:TerminalState,
               resolution:PublicResult,
               resolved_at:ResolvedAt},
             Record, Resolved),
    assertz(authority_pending(ApprovalId, Context, Resolved)),
    assertz(authority_terminal_resolution(ApprovalId, Context,
                                          ResolutionFuture)),
    terminal_event_type(TerminalState, EventType),
    event_locked(Context, EventType,
                 _{approval_id:ApprovalId,
                   fingerprint:Record.fingerprint,
                   outcome:PublicResult}),
    prune_terminal_locked(Context, PrunedFutures).
execution_complete_locked(ApprovalId, Context, _, ignore, []) :-
    authority_pending(ApprovalId, Context, Record),
    terminal_state(Record.state),
    !.
execution_complete_locked(_, _, _, ignore, []).

completion_terminal_state(cancelling, _, cancelled) :- !.
completion_terminal_state(_, Result, cancelled) :-
    result_is_cancelled(Result),
    !.
completion_terminal_state(_, _, resolved).

result_is_cancelled(error(Error)) :-
    is_dict(Error),
    get_dict(kind, Error, cancelled),
    !.
result_is_cancelled(error(Error)) :-
    is_dict(Error),
    get_dict(kind, Error, exception),
    get_dict(exception, Error, Safe),
    sub_string(Safe, _, _, _, "rlm_async_cancelled"),
    !.

terminal_event_type(cancelled, approval_cancelled) :- !.
terminal_event_type(_, approval_resolved).

apply_execution_completion(resolve, ResolutionFuture, Result) :-
    catch(rlm_async:rlm_future_resolve(ResolutionFuture, Result), _, true).
apply_execution_completion(ignore, _, _).

approval_schedule_failed(ApprovalId, Context, ResolutionFuture, Gate,
                         ExecutionFuture, Exception, Outcome) :-
    safe_exception(Exception, Safe),
    Error = authority_error{kind:resume_schedule_failed,
                            approval_id:ApprovalId,
                            exception:Safe,
                            message:"approved operation could not be scheduled"},
    with_mutex(rlm_authority,
               schedule_failure_locked(ApprovalId, Context, Error,
                                       ResolutionFuture, Transition,
                                       PrunedFutures)),
    apply_schedule_failure(Transition, ResolutionFuture, Error),
    maybe_cancel_destroy_future(ExecutionFuture),
    safe_signal_gate(Gate, cancel),
    safe_destroy_gate(Gate),
    destroy_futures(PrunedFutures),
    Outcome = error(Error).

schedule_failure_locked(ApprovalId, Context, Error, ResolutionFuture,
                        resolve, PrunedFutures) :-
    retract(authority_pending(ApprovalId, Context, Record)),
    memberchk(Record.state, [approved, scheduled]),
    !,
    retractall(authority_pending_gate(ApprovalId, _)),
    retract_control_locked(ApprovalId, StoredResolution, _),
    StoredResolution = ResolutionFuture,
    sanitize_value(error(Error), PublicResult),
    get_time(ResolvedAt),
    put_dict(_{state:resolved,
               resolution:PublicResult,
               resolved_at:ResolvedAt},
             Record, Resolved),
    assertz(authority_pending(ApprovalId, Context, Resolved)),
    assertz(authority_terminal_resolution(ApprovalId, Context,
                                          ResolutionFuture)),
    event_locked(Context, approval_schedule_failed,
                 _{approval_id:ApprovalId,
                   fingerprint:Record.fingerprint}),
    prune_terminal_locked(Context, PrunedFutures).
schedule_failure_locked(_, _, _, _, ignore, []).

apply_schedule_failure(resolve, ResolutionFuture, Error) :-
    catch(rlm_async:rlm_future_resolve(ResolutionFuture, error(Error)), _, true).
apply_schedule_failure(ignore, _, _).

approval_execution_metadata(Record,
                            async_metadata{operation:authority_resume,
                                           approval_id:Record.id,
                                           authority_context:Record.context,
                                           fingerprint:Record.fingerprint}).

/* Denial ---------------------------------------------------------------- */

rlm_deny(ApprovalId, Reason, Outcome) :-
    catch(deny_(ApprovalId, Reason, Outcome),
          Exception,
          authority_exception(deny, Exception, Outcome)).

deny_(ApprovalId, Reason, Outcome) :-
    require_ground(Reason, denial_reason),
    with_mutex(rlm_authority,
               deny_transition_locked(ApprovalId, Reason, Transition,
                                      Record, ResolutionFuture,
                                      PrunedFutures)),
    apply_deny_transition(Transition, ApprovalId, Reason,
                          Record, ResolutionFuture, Outcome),
    destroy_futures(PrunedFutures).

deny_transition_locked(ApprovalId, Reason, deny, Denied,
                       ResolutionFuture, PrunedFutures) :-
    retract(authority_pending(ApprovalId, Context, Record)),
    Record.state == pending,
    !,
    retract_control_locked(ApprovalId, ResolutionFuture, _),
    retractall(authority_pending_gate(ApprovalId, _)),
    get_time(ResolvedAt),
    put_dict(_{state:denied,
               denial_reason:Reason,
               resolved_at:ResolvedAt},
             Record, Denied),
    assertz(authority_pending(ApprovalId, Context, Denied)),
    assertz(authority_terminal_resolution(ApprovalId, Context,
                                          ResolutionFuture)),
    event_locked(Context, approval_denied,
                 _{approval_id:ApprovalId,
                   fingerprint:Record.fingerprint,
                   reason:Reason}),
    prune_terminal_locked(Context, PrunedFutures).
deny_transition_locked(ApprovalId, _, not_pending(State), Record, none, []) :-
    authority_pending(ApprovalId, _, Record),
    !,
    State = Record.state.
deny_transition_locked(ApprovalId, _, _, _, _, _) :-
    throw(authority_fault(unknown_approval(ApprovalId))).

apply_deny_transition(not_pending(State), ApprovalId, _, Record, _,
                      error(authority_error{
                                kind:approval_not_pending,
                                approval_id:ApprovalId,
                                state:State,
                                fingerprint:Record.fingerprint,
                                message:"approval is no longer pending"
                            })) :- !.
apply_deny_transition(deny, ApprovalId, Reason, Record, ResolutionFuture,
                      ok(approval_transition{id:ApprovalId,
                                             state:denied,
                                             fingerprint:Record.fingerprint,
                                             reason:Reason})) :-
    catch(rlm_async:rlm_future_resolve(
              ResolutionFuture,
              denied(authority_denial{approval_id:ApprovalId,
                                      fingerprint:Record.fingerprint,
                                      reason:Reason})),
          _, true).

/* Edit ------------------------------------------------------------------ */

rlm_edit(ApprovalId, EditedOperation0, Outcome) :-
    catch(edit_(ApprovalId, EditedOperation0, Outcome),
          Exception,
          authority_exception(edit, Exception, Outcome)).

edit_(ApprovalId, EditedOperation0, Outcome) :-
    editable_snapshot(ApprovalId, Context, Record,
                      Validator, OldResolution),
    require_editable_validator(Validator),
    call(Validator, EditedOperation0,
         NormalizedOperation0, NewContinuation),
    require_host_continuation(NewContinuation),
    normalize_operation(NormalizedOperation0, NormalizedOperation),
    rlm_operation_fingerprint(Context, NormalizedOperation, NewFingerprint),
    resolution_metadata(Context, NewFingerprint, Metadata),
    rlm_async:rlm_future_deferred(Metadata, NewResolution),
    catch(with_mutex(rlm_authority,
                     edit_transition_locked(ApprovalId, Context,
                                            Record.fingerprint,
                                            NormalizedOperation,
                                            NewFingerprint,
                                            NewContinuation, Validator,
                                            OldResolution, NewResolution,
                                            NewRecord, PrunedFutures)),
          Exception,
          ( catch(rlm_async:rlm_future_destroy(NewResolution), _, true),
            throw(Exception)
          )),
    NewId = NewRecord.id,
    catch(rlm_async:rlm_future_resolve(
              OldResolution,
              superseded(authority_edit{old_id:ApprovalId,
                                        new_id:NewId,
                                        old_fingerprint:Record.fingerprint,
                                        fingerprint:NewFingerprint})),
          _, true),
    destroy_futures(PrunedFutures),
    Outcome = ok(authority_edit{old_id:ApprovalId,
                                id:NewId,
                                old_fingerprint:Record.fingerprint,
                                fingerprint:NewFingerprint,
                                approval:NewRecord}).

editable_snapshot(ApprovalId, Context, Record, Validator, Resolution) :-
    with_mutex(rlm_authority,
               (   authority_pending(ApprovalId, Context, Found),
                   Found.state == pending,
                   authority_pending_control(ApprovalId, _, Validator,
                                             Resolution, none)
               ->  Record = Found
               ;   throw(authority_fault(approval_not_editable(ApprovalId)))
               )).

edit_transition_locked(ApprovalId, Context, ExpectedFingerprint,
                       Operation, NewFingerprint, NewContinuation, Validator,
                       OldResolution, NewResolution, NewRecord,
                       PrunedFutures) :-
    retract(authority_pending(ApprovalId, Context, Current)),
    Current.state == pending,
    Current.fingerprint == ExpectedFingerprint,
    !,
    retract_control_locked(ApprovalId, StoredOldResolution, _),
    StoredOldResolution = OldResolution,
    retractall(authority_pending_gate(ApprovalId, _)),
    gensym(approval_, NewId),
    get_time(CreatedAt),
    get_time(ResolvedAt),
    put_dict(_{state:superseded,
               superseded_by:NewId,
               resolved_at:ResolvedAt},
             Current, Superseded),
    assertz(authority_pending(ApprovalId, Context, Superseded)),
    assertz(authority_terminal_resolution(ApprovalId, Context,
                                          OldResolution)),
    sanitize_value(Operation, PublicOperation),
    pending_correlation(Operation, Correlation),
    NewRecord = pending_operation{id:NewId,
                                  operation:PublicOperation,
                                  name:Operation.name,
                                  effect:Operation.effect,
                                  capability:Operation.capability,
                                  context:Context,
                                  correlation:Correlation,
                                  authority:approve_diff,
                                  fingerprint:NewFingerprint,
                                  created_at:CreatedAt,
                                  state:pending,
                                  edited_from:ApprovalId},
    assertz(authority_pending(NewId, Context, NewRecord)),
    assertz(authority_pending_control(NewId, NewContinuation, Validator,
                                      NewResolution, none)),
    event_locked(Context, approval_edited,
                 _{approval_id:ApprovalId,
                   new_approval_id:NewId,
                   old_fingerprint:ExpectedFingerprint,
                   fingerprint:NewFingerprint}),
    prune_terminal_locked(Context, PrunedFutures).
edit_transition_locked(ApprovalId, _, _, _, _, _, _, _, _, _, _) :-
    throw(authority_fault(stale_edit(ApprovalId))).

/* Ownership, cancellation and teardown -------------------------------- */

rlm_pending_cancel_owner(Context, Reason) :-
    require_context(Context),
    with_mutex(rlm_authority,
               findall(Id-State,
                       ( authority_pending(Id, Context, Record),
                         State = Record.state,
                         active_pending_state(State) ),
                       Owned)),
    maplist(cancel_owned(Reason), Owned).

active_pending_state(pending).
active_pending_state(approved).
active_pending_state(scheduled).
active_pending_state(executing).
active_pending_state(cancelling).

cancel_owned(Reason, ApprovalId-pending) :-
    !,
    rlm_deny(ApprovalId, cancelled(Reason), _).
cancel_owned(Reason, ApprovalId-_) :-
    cancel_nonpending_owned(ApprovalId, Reason).

cancel_nonpending_owned(ApprovalId, Reason) :-
    with_mutex(rlm_authority,
               cancel_transition_locked(ApprovalId, Reason, Transition)),
    apply_cancel_owned_transition(Transition, ApprovalId, Reason).

cancel_transition_locked(ApprovalId, Reason,
                         preclaim(Context, Record, ResolutionFuture,
                                  ExecutionFuture, Gate, PrunedFutures)) :-
    retract(authority_pending(ApprovalId, Context, Record0)),
    memberchk(Record0.state, [approved, scheduled]),
    !,
    retract_control_locked(ApprovalId, ResolutionFuture, ExecutionFuture),
    take_gate_locked(ApprovalId, Gate),
    get_time(ResolvedAt),
    put_dict(_{state:cancelled,
               cancellation_reason:Reason,
               resolved_at:ResolvedAt},
             Record0, Record),
    assertz(authority_pending(ApprovalId, Context, Record)),
    assertz(authority_terminal_resolution(ApprovalId, Context,
                                          ResolutionFuture)),
    event_locked(Context, approval_cancelled,
                 _{approval_id:ApprovalId,
                   fingerprint:Record0.fingerprint,
                   reason:Reason,
                   before_execution_claim:true}),
    prune_terminal_locked(Context, PrunedFutures).
cancel_transition_locked(ApprovalId, Reason,
                         inflight(Context, Record, ExecutionFuture)) :-
    retract(authority_pending(ApprovalId, Context, Record0)),
    Record0.state == executing,
    !,
    authority_pending_control(ApprovalId, _, _, _, ExecutionFuture),
    put_dict(_{state:cancelling,
               cancellation_reason:Reason},
             Record0, Record),
    assertz(authority_pending(ApprovalId, Context, Record)),
    event_locked(Context, approval_cancellation_requested,
                 _{approval_id:ApprovalId,
                   fingerprint:Record0.fingerprint,
                   reason:Reason,
                   after_execution_claim:true}).
cancel_transition_locked(ApprovalId, _, already(State)) :-
    authority_pending(ApprovalId, _, Record),
    !,
    State = Record.state.
cancel_transition_locked(ApprovalId, _, missing(ApprovalId)).

apply_cancel_owned_transition(
    preclaim(_, Record, ResolutionFuture, ExecutionFuture, Gate,
             PrunedFutures),
    ApprovalId, Reason) :-
    safe_signal_gate(Gate, cancel),
    maybe_cancel_future(ExecutionFuture),
    catch(rlm_async:rlm_future_resolve(
              ResolutionFuture,
              error(authority_error{kind:cancelled,
                                    approval_id:ApprovalId,
                                    fingerprint:Record.fingerprint,
                                    reason:Reason,
                                    before_execution_claim:true,
                                    message:"owned approval was cancelled before execution claim"})),
          _, true),
    safe_destroy_gate(Gate),
    destroy_futures(PrunedFutures).
apply_cancel_owned_transition(inflight(_, _, ExecutionFuture), _, _) :-
    maybe_cancel_future(ExecutionFuture).
apply_cancel_owned_transition(already(_), _, _).
apply_cancel_owned_transition(missing(_), _, _).

rlm_authority_clear(Context) :-
    require_context(Context),
    rlm_pending_cancel_owner(Context, authority_context_destroyed),
    with_mutex(rlm_authority,
               clear_context_locked(Context, Resources)),
    destroy_context_resources(Resources).

clear_context_locked(Context,
                     resources(ResolutionFutures, ExecutionFutures, Gates)) :-
    findall(Resolution-Execution,
            ( authority_pending(Id, Context, _),
              authority_pending_control(Id, _, _, Resolution, Execution) ),
            Controls),
    control_futures(Controls, ActiveResolutions, ExecutionFutures0),
    findall(Resolution,
            authority_terminal_resolution(_, Context, Resolution),
            TerminalResolutions),
    append(ActiveResolutions, TerminalResolutions, ResolutionFutures0),
    sort(ResolutionFutures0, ResolutionFutures),
    exclude(==(none), ExecutionFutures0, ExecutionFutures1),
    sort(ExecutionFutures1, ExecutionFutures),
    findall(Gate,
            ( authority_pending(Id, Context, _),
              authority_pending_gate(Id, Gate) ),
            Gates0),
    sort(Gates0, Gates),
    findall(Id, authority_pending(Id, Context, _), Ids),
    retractall(authority_mode(Context, _)),
    retractall(authority_once(Context, _, _, _)),
    forall(member(Id, Ids),
           ( retractall(authority_pending(Id, Context, _)),
             retractall(authority_pending_control(Id, _, _, _, _)),
             retractall(authority_pending_gate(Id, _)),
             retractall(authority_terminal_resolution(Id, Context, _)) )),
    retractall(authority_sequence(Context, _)),
    retractall(authority_event(Context, _, _)).

control_futures([], [], []).
control_futures([Resolution-Execution|Controls],
                [Resolution|Resolutions], [Execution|Executions]) :-
    control_futures(Controls, Resolutions, Executions).

destroy_context_resources(resources(ResolutionFutures, ExecutionFutures,
                                    Gates)) :-
    maplist(maybe_cancel_destroy_future, ExecutionFutures),
    destroy_futures(ResolutionFutures),
    maplist(safe_destroy_gate, Gates).

rlm_authority_clear_runtime(Runtime) :-
    require_context(Runtime),
    findall(Context, runtime_context(Runtime, Context), Contexts0),
    sort(Contexts0, Contexts),
    maplist(rlm_authority_clear, Contexts).

runtime_context(Runtime, runtime(Runtime)).
runtime_context(Runtime, Context) :-
    authority_mode(Context, _), context_owned_by(Runtime, Context).
runtime_context(Runtime, Context) :-
    authority_once(Context, _, _, _), context_owned_by(Runtime, Context).
runtime_context(Runtime, Context) :-
    authority_pending(_, Context, _), context_owned_by(Runtime, Context).
runtime_context(Runtime, Context) :-
    authority_terminal_resolution(_, Context, _),
    context_owned_by(Runtime, Context).

context_owned_by(Runtime, agent(Runtime, _)).
context_owned_by(Runtime, graph(Runtime, _, _)).
context_owned_by(Runtime, session(Runtime)).
context_owned_by(Runtime, runtime(Runtime)).

/* Bounded terminal retention ------------------------------------------- */

terminal_state(resolved).
terminal_state(denied).
terminal_state(superseded).
terminal_state(cancelled).

prune_terminal_locked(Context, Futures) :-
    terminal_history_limit(Limit),
    findall(CreatedAt-Id,
            ( authority_pending(Id, Context, Record),
              terminal_state(Record.state),
              CreatedAt = Record.created_at ),
            TerminalPairs0),
    keysort(TerminalPairs0, TerminalPairs),
    length(TerminalPairs, Count),
    Excess is max(0, Count-Limit),
    take_prefix(Excess, TerminalPairs, ToPrune),
    maplist(prune_terminal_one_locked(Context), ToPrune, Futures0),
    exclude(==(none), Futures0, Futures).

prune_terminal_one_locked(Context, _-ApprovalId, Future) :-
    retractall(authority_pending(ApprovalId, Context, _)),
    retractall(authority_pending_control(ApprovalId, _, _, _, _)),
    retractall(authority_pending_gate(ApprovalId, _)),
    (   retract(authority_terminal_resolution(ApprovalId, Context, Found))
    ->  Future = Found
    ;   Future = none
    ).

take_prefix(0, _, []) :- !.
take_prefix(_, [], []) :- !.
take_prefix(Count, [Item|Items], [Item|Prefix]) :-
    Count > 0,
    Next is Count-1,
    take_prefix(Next, Items, Prefix).

retract_control_locked(ApprovalId, ResolutionFuture, ExecutionFuture) :-
    (   retract(authority_pending_control(ApprovalId, _, _,
                                          ResolutionFuture,
                                          ExecutionFuture))
    ->  true
    ;   ResolutionFuture = none,
        ExecutionFuture = none
    ).

take_gate_locked(ApprovalId, Gate) :-
    ( retract(authority_pending_gate(ApprovalId, Found))
    -> Gate = Found
    ;  Gate = none ).

maybe_cancel_future(none) :- !.
maybe_cancel_future(Future) :-
    catch(rlm_async:rlm_future_cancel(Future, _), _, true).

maybe_cancel_destroy_future(none) :- !.
maybe_cancel_destroy_future(Future) :-
    catch(rlm_async:rlm_future_cancel(Future, _), _, true),
    catch(rlm_async:rlm_future_destroy(Future), _, true).

destroy_futures([]).
destroy_futures([Future|Futures]) :-
    catch(rlm_async:rlm_future_destroy(Future), _, true),
    destroy_futures(Futures).

safe_signal_gate(none, _) :- !, fail.
safe_signal_gate(Gate, Signal) :-
    catch(thread_send_message(Gate, Signal, [timeout(0)]), _, fail).

safe_destroy_gate(none) :- !.
safe_destroy_gate(Gate) :-
    catch(message_queue_destroy(Gate), _, true).

/* Public record sanitization ------------------------------------------- */

sanitize_value(Value, Value) :- atomic(Value), !.
sanitize_value(Value, Sanitized) :-
    is_list(Value),
    !,
    maplist(sanitize_value, Value, Sanitized).
sanitize_value(Value, Sanitized) :-
    is_dict(Value),
    !,
    dict_pairs(Value, Tag, Pairs0),
    maplist(sanitize_pair, Pairs0, Pairs),
    dict_pairs(Sanitized, Tag, Pairs).
sanitize_value(Value, Sanitized) :-
    compound(Value),
    !,
    Value =.. [Functor|Args0],
    maplist(sanitize_value, Args0, Args),
    Sanitized =.. [Functor|Args].

sanitize_pair(Key-_, Key-'<redacted>') :- secret_key(Key), !.
sanitize_pair(Key-Value0, Key-Value) :- sanitize_value(Value0, Value).

secret_key(Key) :-
    atom(Key),
    downcase_atom(Key, Lower),
    memberchk(Lower,
              [secret, token, password, api_key, authorization,
               access_token, refresh_token, private_key]).

/* Events and errors ----------------------------------------------------- */

event_locked(Context, Type, Fields) :-
    ( retract(authority_sequence(Context, Seq0)) -> true ; Seq0 = 0 ),
    Seq is Seq0+1,
    assertz(authority_sequence(Context, Seq)),
    get_time(At),
    put_dict(_{sequence:Seq, type:Type, at:At}, Fields, Event),
    assertz(authority_event(Context, Seq, Event)).

require_context(Context) :- ground(Context), nonvar(Context), !.
require_context(Context) :- throw(authority_fault(invalid_context(Context))).

require_host_continuation(Continuation) :-
    callable(Continuation), ground(Continuation), !.
require_host_continuation(Continuation) :-
    throw(authority_fault(invalid_continuation(Continuation))).

require_edit_validator(none) :- !.
require_edit_validator(Validator) :-
    callable(Validator), ground(Validator), !.
require_edit_validator(Validator) :-
    throw(authority_fault(invalid_edit_validator(Validator))).

require_editable_validator(none) :-
    throw(authority_fault(edit_not_supported)).
require_editable_validator(Validator) :- require_edit_validator(Validator).

require_ground(Value, _) :- ground(Value), !.
require_ground(Value, Field) :- throw(authority_fault(nonground(Field, Value))).

pairs_values([], []).
pairs_values([_-Value|Pairs], [Value|Values]) :- pairs_values(Pairs, Values).

authority_exception(_, Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
authority_exception(Phase, authority_fault(Detail), error(Error)) :-
    !,
    Error = authority_error{phase:Phase,
                            kind:invalid_authority_operation,
                            detail:Detail,
                            message:"authority operation is invalid"}.
authority_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = authority_error{phase:Phase,
                            kind:authority_exception,
                            exception:Safe,
                            message:"authority operation raised an exception"}.

control_exception(rlm_async_cancelled(_)).
control_exception(rlm_cancelled(_)).
control_exception(chain_cancelled(_)).
control_exception(graph_cancelled(_)).
control_exception(cancelled(_)).
control_exception('$aborted').
control_exception(abort).

safe_exception(Exception, Safe) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).
