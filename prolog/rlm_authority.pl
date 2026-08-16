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
            rlm_approve/2,
            rlm_deny/3,
            rlm_edit/3,
            rlm_pending_cancel_owner/2
          ]).

/** <module> Host-controlled authority and pending operations

Authority is a host/library policy layered after hard validation and capability
checks. It never widens capabilities or makes an invalid operation executable.
Human approval is represented as durable-in-process pending state plus a
manually-resolved Future. No rlm_async worker is occupied while approval is
pending.

The only canonical public authority modes are approve_diff, allow_once,
allow_session, and dangerous. Unset contexts read as approve_diff. Child
contexts may inherit the same or a stricter mode, never a wider one.
*/

:- use_module(library(crypto)).
:- use_module(library(gensym)).
:- use_module(library(lists)).
:- use_module(rlm_async, []).

:- dynamic authority_mode/2.
:- dynamic authority_once/4.
:- dynamic authority_pending/3.
:- dynamic authority_pending_control/4.
:- dynamic authority_sequence/2.
:- dynamic authority_event/3.

/* -------------------------------------------------------------------------
 * Modes and narrowing
 * ---------------------------------------------------------------------- */

rlm_authority(Context, Mode) :-
    require_context(Context),
    with_mutex(rlm_authority,
               (   authority_mode(Context, Found)
               ->  Mode = Found
               ;   Mode = approve_diff
               )).

rlm_set_authority_if_unset(Context, Mode, Outcome) :-
    catch(( require_context(Context),
            require_mode(Mode),
            with_mutex(rlm_authority,
                       set_authority_if_unset_locked(Context, Mode, Outcome))
          ),
          Exception,
          authority_exception(set_if_unset, Exception, Outcome)).

set_authority_if_unset_locked(Context, _, ok(authority_unchanged{context:Context,
                                                                  mode:Existing})) :-
    authority_mode(Context, Existing),
    !.
set_authority_if_unset_locked(Context, Mode,
                              ok(authority_set{context:Context, mode:Mode})) :-
    assertz(authority_mode(Context, Mode)),
    event_locked(Context, authority_set, _{mode:Mode, source:set_if_unset}).

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
    assertz(authority_mode(Context, Mode)),
    event_locked(Context, authority_set, _{mode:Mode, previous:Previous, source:trusted_host}).

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
child_after_narrow(ok(Mode), Context, Outcome) :-
    with_mutex(rlm_authority,
               ( retractall(authority_mode(Context, _)),
                 assertz(authority_mode(Context, Mode)),
                 event_locked(Context, authority_inherited, _{mode:Mode}),
                 Outcome = ok(authority_child{context:Context, mode:Mode})
               )).

mode_rank(approve_diff, 0).
mode_rank(allow_once, 1).
mode_rank(allow_session, 2).
mode_rank(dangerous, 3).

require_mode(Mode) :-
    mode_rank(Mode, _),
    !.
require_mode(Mode) :-
    throw(authority_fault(invalid_mode(Mode))).

/* -------------------------------------------------------------------------
 * Effect vocabulary and exact fingerprints
 * ---------------------------------------------------------------------- */

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
    Canonical0 = authority_fingerprint{context:Context, operation:Operation},
    canonical_value(Canonical0, Canonical),
    term_string(Canonical,
                Serialized,
                [ quoted(true),
                  numbervars(true),
                  ignore_ops(true)
                ]),
    crypto_data_hash(Serialized,
                     Hex,
                     [algorithm(sha256), encoding(utf8)]),
    atom_concat('sha256:', Hex, Fingerprint).

normalize_operation(Operation0, Operation) :-
    is_dict(Operation0),
    !,
    required_operation_field(Operation0, name, Name),
    required_operation_field(Operation0, effect, Effect),
    required_operation_field(Operation0, capability, Capability),
    require_operation_name(Name),
    require_effect(Effect),
    ground(Capability),
    canonical_value(Operation0, Operation).
normalize_operation(Operation, _) :-
    throw(authority_fault(invalid_operation(Operation))).

required_operation_field(Operation, Key, Value) :-
    (   get_dict(Key, Operation, Value)
    ->  true
    ;   throw(authority_fault(missing_operation_field(Key)))
    ).

require_operation_name(Name) :-
    atom(Name), Name \== '',
    !.
require_operation_name(Name) :-
    throw(authority_fault(invalid_operation_name(Name))).

require_effect(Effect) :-
    rlm_effect_class(Effect),
    !.
require_effect(Effect) :-
    throw(authority_fault(invalid_effect(Effect))).

canonical_value(Value, Value) :-
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

canonical_pair(Key-Value0, Key-Value) :-
    canonical_value(Value0, Value).

/* -------------------------------------------------------------------------
 * Authority decision
 * ---------------------------------------------------------------------- */

rlm_authorize_operation(Context, Operation0, Continuation, EditValidator, Outcome) :-
    catch(authorize_operation_(Context,
                               Operation0,
                               Continuation,
                               EditValidator,
                               Outcome),
          Exception,
          authority_exception(authorize, Exception, Outcome)).

authorize_operation_(Context, Operation0, Continuation, EditValidator, Outcome) :-
    require_context(Context),
    require_host_continuation(Continuation),
    require_edit_validator(EditValidator),
    normalize_operation(Operation0, Operation),
    rlm_operation_fingerprint(Context, Operation, Fingerprint),
    rlm_authority(Context, Mode),
    authorize_mode(Mode,
                   Context,
                   Operation,
                   Fingerprint,
                   Continuation,
                   EditValidator,
                   Outcome).

authorize_mode(_, _, Operation, Fingerprint, _, _,
               execute(authority_permit{kind:read,
                                        fingerprint:Fingerprint})) :-
    Operation.effect == read,
    !.
authorize_mode(dangerous, _, _, Fingerprint, _, _,
               execute(authority_permit{kind:dangerous,
                                        fingerprint:Fingerprint})) :- !.
authorize_mode(allow_session, _, _, Fingerprint, _, _,
               execute(authority_permit{kind:allow_session,
                                        fingerprint:Fingerprint})) :- !.
authorize_mode(allow_once, Context, Operation, Fingerprint, _, _, Outcome) :-
    !,
    with_mutex(rlm_authority,
               allow_once_locked(Context, Operation, Fingerprint, Outcome)).
authorize_mode(approve_diff,
               Context,
               Operation,
               Fingerprint,
               Continuation,
               EditValidator,
               Outcome) :-
    create_pending(Context,
                   Operation,
                   Fingerprint,
                   Continuation,
                   EditValidator,
                   Outcome).

allow_once_locked(Context, _, Fingerprint,
                  execute(authority_permit{kind:allow_once,
                                           fingerprint:Fingerprint})) :-
    current_mode_locked(Context, allow_once),
    \+ authority_once(Context, _, started, _),
    !,
    retractall(authority_mode(Context, _)),
    assertz(authority_mode(Context, approve_diff)),
    assertz(authority_once(Context, Fingerprint, started, none)),
    event_locked(Context,
                 allow_once_consumed,
                 _{fingerprint:Fingerprint, next_mode:approve_diff}).
allow_once_locked(Context, _, Fingerprint,
                  error(authority_error{
                            kind:allow_once_already_started,
                            fingerprint:Fingerprint,
                            message:"single-use authority was already consumed"
                        })) :-
    authority_once(Context, Fingerprint, started, _),
    !.
allow_once_locked(Context, _, Fingerprint,
                  error(authority_error{
                            kind:allow_once_consumed,
                            fingerprint:Fingerprint,
                            message:"single-use authority is no longer available"
                        })).

rlm_authority_complete_once(Context, Fingerprint, Outcome) :-
    with_mutex(rlm_authority,
               (   retract(authority_once(Context, Fingerprint, started, _))
               ->  assertz(authority_once(Context,
                                          Fingerprint,
                                          completed,
                                          Outcome)),
                   event_locked(Context,
                                allow_once_completed,
                                _{fingerprint:Fingerprint})
               ;   true
               )).

/* -------------------------------------------------------------------------
 * Pending operations and non-blocking approval wait
 * ---------------------------------------------------------------------- */

create_pending(Context,
               Operation,
               Fingerprint,
               Continuation,
               EditValidator,
               approval_required(Public)) :-
    pending_public_operation(Operation, PublicOperation),
    rlm_async:rlm_future_deferred(
        async_metadata{operation:authority_pending_resolution,
                       authority_context:Context,
                       fingerprint:Fingerprint},
        ResolutionFuture),
    with_mutex(rlm_authority,
               ( gensym(approval_, ApprovalId),
                 get_time(CreatedAt),
                 Record = pending_operation{
                              id:ApprovalId,
                              operation:PublicOperation,
                              name:Operation.name,
                              effect:Operation.effect,
                              capability:Operation.capability,
                              context:Context,
                              authority:approve_diff,
                              fingerprint:Fingerprint,
                              created_at:CreatedAt,
                              state:pending
                          },
                 assertz(authority_pending(ApprovalId, Context, Record)),
                 assertz(authority_pending_control(ApprovalId,
                                                   Continuation,
                                                   EditValidator,
                                                   ResolutionFuture)),
                 event_locked(Context,
                              approval_pending,
                              _{approval_id:ApprovalId,
                                fingerprint:Fingerprint,
                                effect:Operation.effect}),
                 Public = Record
               )).

pending_public_operation(Operation, Public) :-
    sanitize_value(Operation, Public).

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

rlm_pending_approval(Context, ApprovalId, Approval) :-
    require_context(Context),
    authority_pending(ApprovalId, Context, Approval).

rlm_pending_approvals(Context, Approvals) :-
    require_context(Context),
    findall(Id-Approval,
            authority_pending(Id, Context, Approval),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Approvals).

rlm_pending_resolution_async(ApprovalId, Future) :-
    (   authority_pending_control(ApprovalId, _, _, Found)
    ->  Future = Found
    ;   throw(error(existence_error(rlm_pending_operation, ApprovalId), _))
    ).

rlm_pending_resolution(ApprovalId, Outcome) :-
    rlm_pending_resolution_async(ApprovalId, Future),
    rlm_async:rlm_future_await(Future, Outcome).

rlm_approve(ApprovalId, Outcome) :-
    catch(approve_(ApprovalId, Outcome),
          Exception,
          authority_exception(approve, Exception, Outcome)).

approve_(ApprovalId, Outcome) :-
    with_mutex(rlm_authority,
               approval_transition_locked(ApprovalId,
                                          Transition,
                                          Context,
                                          Record,
                                          Continuation,
                                          ResolutionFuture)),
    approve_transition(Transition,
                       ApprovalId,
                       Context,
                       Record,
                       Continuation,
                       ResolutionFuture,
                       Outcome).

approval_transition_locked(ApprovalId,
                           schedule,
                           Context,
                           Updated,
                           Continuation,
                           ResolutionFuture) :-
    retract(authority_pending(ApprovalId, Context, Record)),
    Record.state == pending,
    !,
    authority_pending_control(ApprovalId,
                              Continuation,
                              _,
                              ResolutionFuture),
    put_dict(state, Record, approved, Updated),
    assertz(authority_pending(ApprovalId, Context, Updated)),
    event_locked(Context,
                 approval_granted,
                 _{approval_id:ApprovalId,
                   fingerprint:Record.fingerprint}).
approval_transition_locked(ApprovalId,
                           existing,
                           Context,
                           Record,
                           none,
                           none) :-
    authority_pending(ApprovalId, Context, Record),
    !.
approval_transition_locked(ApprovalId, _, _, _, _, _) :-
    throw(authority_fault(unknown_approval(ApprovalId))).

approve_transition(existing, ApprovalId, _, Record, _, _,
                   ok(approval_transition{id:ApprovalId,
                                          state:Record.state,
                                          fingerprint:Record.fingerprint})) :- !.
approve_transition(schedule,
                   ApprovalId,
                   Context,
                   Record,
                   Continuation,
                   ResolutionFuture,
                   Outcome) :-
    approval_execution_metadata(Record, Metadata),
    rlm_async:rlm_async_submit(
        rlm_authority:pending_execution(ApprovalId, Continuation),
        Metadata,
        ExecutionFuture),
    rlm_async:rlm_future_on_complete(
        ExecutionFuture,
        rlm_authority:pending_execution_complete(ApprovalId,
                                                 Context,
                                                 ResolutionFuture)),
    with_mutex(rlm_authority,
               mark_execution_future_locked(ApprovalId,
                                            Context,
                                            ExecutionFuture,
                                            Updated)),
    Outcome = ok(approval_transition{id:ApprovalId,
                                     state:executing,
                                     fingerprint:Record.fingerprint,
                                     execution_future:ExecutionFuture,
                                     approval:Updated}).

pending_execution(_, Continuation, Outcome) :-
    call(Continuation, Outcome).

pending_execution_complete(ApprovalId, Context, ResolutionFuture, Outcome) :-
    with_mutex(rlm_authority,
               complete_pending_locked(ApprovalId, Context, Outcome)),
    catch(rlm_async:rlm_future_resolve(ResolutionFuture, Outcome), _, true).

mark_execution_future_locked(ApprovalId, Context, Future, Updated) :-
    retract(authority_pending(ApprovalId, Context, Record)),
    put_dict(_{state:executing, execution_future:Future}, Record, Updated),
    assertz(authority_pending(ApprovalId, Context, Updated)).

complete_pending_locked(ApprovalId, Context, Outcome) :-
    (   retract(authority_pending(ApprovalId, Context, Record))
    ->  put_dict(_{state:resolved, resolution:Outcome}, Record, Updated),
        assertz(authority_pending(ApprovalId, Context, Updated)),
        event_locked(Context,
                     approval_resolved,
                     _{approval_id:ApprovalId,
                       fingerprint:Record.fingerprint,
                       outcome:Outcome})
    ;   true
    ).

approval_execution_metadata(Record,
                            async_metadata{operation:authority_resume,
                                           approval_id:Record.id,
                                           authority_context:Record.context,
                                           fingerprint:Record.fingerprint}).

rlm_deny(ApprovalId, Reason, Outcome) :-
    catch(deny_(ApprovalId, Reason, Outcome),
          Exception,
          authority_exception(deny, Exception, Outcome)).

deny_(ApprovalId, Reason, Outcome) :-
    require_ground_reason(Reason),
    with_mutex(rlm_authority,
               deny_locked(ApprovalId,
                           Reason,
                           Transition,
                           Context,
                           Record,
                           ResolutionFuture)),
    deny_transition(Transition,
                    ApprovalId,
                    Reason,
                    Record,
                    ResolutionFuture,
                    Outcome),
    (Context = _ -> true).

deny_locked(ApprovalId,
            Reason,
            denied,
            Context,
            Updated,
            ResolutionFuture) :-
    retract(authority_pending(ApprovalId, Context, Record)),
    Record.state == pending,
    !,
    authority_pending_control(ApprovalId, _, _, ResolutionFuture),
    put_dict(_{state:denied, denial_reason:Reason}, Record, Updated),
    assertz(authority_pending(ApprovalId, Context, Updated)),
    event_locked(Context,
                 approval_denied,
                 _{approval_id:ApprovalId,
                   fingerprint:Record.fingerprint,
                   reason:Reason}).
deny_locked(ApprovalId, _, existing, Context, Record, none) :-
    authority_pending(ApprovalId, Context, Record),
    !.
deny_locked(ApprovalId, _, _, _, _, _) :-
    throw(authority_fault(unknown_approval(ApprovalId))).

deny_transition(existing, ApprovalId, _, Record, _,
                ok(approval_transition{id:ApprovalId,
                                       state:Record.state,
                                       fingerprint:Record.fingerprint})) :- !.
deny_transition(denied, ApprovalId, Reason, Record, ResolutionFuture,
                ok(approval_transition{id:ApprovalId,
                                       state:denied,
                                       fingerprint:Record.fingerprint,
                                       reason:Reason})) :-
    catch(rlm_async:rlm_future_resolve(
              ResolutionFuture,
              denied(authority_denial{approval_id:ApprovalId,
                                      fingerprint:Record.fingerprint,
                                      reason:Reason})),
          _,
          true).

rlm_edit(ApprovalId, EditedOperation0, Outcome) :-
    catch(edit_(ApprovalId, EditedOperation0, Outcome),
          Exception,
          authority_exception(edit, Exception, Outcome)).

edit_(ApprovalId, EditedOperation0, Outcome) :-
    (   authority_pending(ApprovalId, Context, Record),
        Record.state == pending,
        authority_pending_control(ApprovalId,
                                  _,
                                  EditValidator,
                                  ResolutionFuture)
    ->  true
    ;   throw(authority_fault(approval_not_editable(ApprovalId)))
    ),
    require_editable_validator(EditValidator),
    call(EditValidator,
         EditedOperation0,
         NormalizedOperation0,
         NewContinuation),
    normalize_operation(NormalizedOperation0, NormalizedOperation),
    rlm_operation_fingerprint(Context, NormalizedOperation, NewFingerprint),
    pending_public_operation(NormalizedOperation, PublicOperation),
    with_mutex(rlm_authority,
               edit_locked(ApprovalId,
                           Context,
                           Record.fingerprint,
                           PublicOperation,
                           NormalizedOperation,
                           NewFingerprint,
                           NewContinuation,
                           EditValidator,
                           ResolutionFuture,
                           Updated)),
    Outcome = ok(approval_edit{id:ApprovalId,
                               old_fingerprint:Record.fingerprint,
                               fingerprint:NewFingerprint,
                               approval:Updated}).

edit_locked(ApprovalId,
            Context,
            ExpectedFingerprint,
            PublicOperation,
            Operation,
            NewFingerprint,
            NewContinuation,
            EditValidator,
            ResolutionFuture,
            Updated) :-
    retract(authority_pending(ApprovalId, Context, Current)),
    Current.state == pending,
    Current.fingerprint == ExpectedFingerprint,
    !,
    put_dict(_{operation:PublicOperation,
               name:Operation.name,
               effect:Operation.effect,
               capability:Operation.capability,
               fingerprint:NewFingerprint,
               edited_from:ExpectedFingerprint},
             Current,
             Updated),
    assertz(authority_pending(ApprovalId, Context, Updated)),
    retractall(authority_pending_control(ApprovalId, _, _, _)),
    assertz(authority_pending_control(ApprovalId,
                                      NewContinuation,
                                      EditValidator,
                                      ResolutionFuture)),
    event_locked(Context,
                 approval_edited,
                 _{approval_id:ApprovalId,
                   old_fingerprint:ExpectedFingerprint,
                   fingerprint:NewFingerprint}).
edit_locked(ApprovalId, _, _, _, _, _, _, _, _, _) :-
    throw(authority_fault(stale_edit(ApprovalId))).

/* -------------------------------------------------------------------------
 * Cleanup and ownership
 * ---------------------------------------------------------------------- */

rlm_pending_cancel_owner(Context, Reason) :-
    require_context(Context),
    findall(Id,
            ( authority_pending(Id, Context, Record),
              memberchk(Record.state, [pending, approved, executing])
            ),
            Ids),
    maplist(cancel_pending(Reason), Ids).

cancel_pending(Reason, ApprovalId) :-
    (   authority_pending(ApprovalId, _, Record), Record.state == pending
    ->  rlm_deny(ApprovalId, cancelled(Reason), _)
    ;   true
    ).

rlm_authority_clear(Context) :-
    require_context(Context),
    rlm_pending_cancel_owner(Context, authority_context_destroyed),
    with_mutex(rlm_authority,
               ( retractall(authority_mode(Context, _)),
                 retractall(authority_once(Context, _, _, _)),
                 retractall(authority_sequence(Context, _)),
                 retractall(authority_event(Context, _, _))
               )).

rlm_authority_clear_runtime(Runtime) :-
    require_context(Runtime),
    findall(Context,
            runtime_owned_context(Runtime, Context),
            Contexts0),
    sort([Runtime|Contexts0], Contexts),
    maplist(rlm_authority_clear, Contexts).

runtime_owned_context(Runtime, Context) :- authority_mode(Context, _), context_owned_by(Runtime, Context).
runtime_owned_context(Runtime, Context) :- authority_pending(_, Context, _), context_owned_by(Runtime, Context).

context_owned_by(Runtime, agent(Runtime, _)).
context_owned_by(Runtime, graph(Runtime, _)).
context_owned_by(Runtime, session(Runtime)).
context_owned_by(Runtime, runtime(Runtime)).

/* -------------------------------------------------------------------------
 * Helpers
 * ---------------------------------------------------------------------- */

current_mode_locked(Context, Mode) :-
    (   authority_mode(Context, Found)
    ->  Mode = Found
    ;   Mode = approve_diff
    ).

require_context(Context) :-
    ground(Context),
    nonvar(Context),
    !.
require_context(Context) :-
    throw(authority_fault(invalid_context(Context))).

require_host_continuation(Continuation) :-
    callable(Continuation),
    ground(Continuation),
    !.
require_host_continuation(Continuation) :-
    throw(authority_fault(invalid_continuation(Continuation))).

require_edit_validator(none) :- !.
require_edit_validator(Validator) :-
    callable(Validator),
    ground(Validator),
    !.
require_edit_validator(Validator) :-
    throw(authority_fault(invalid_edit_validator(Validator))).

require_editable_validator(none) :-
    throw(authority_fault(edit_not_supported)).
require_editable_validator(Validator) :- require_edit_validator(Validator).

require_ground_reason(Reason) :- ground(Reason), !.
require_ground_reason(Reason) :- throw(authority_fault(invalid_denial_reason(Reason))).

pairs_values([], []).
pairs_values([_-Value|Pairs], [Value|Values]) :- pairs_values(Pairs, Values).

event_locked(Context, Type, Fields) :-
    (   retract(authority_sequence(Context, Seq0))
    ->  true
    ;   Seq0 = 0
    ),
    Seq is Seq0+1,
    assertz(authority_sequence(Context, Seq)),
    get_time(At),
    put_dict(_{sequence:Seq, type:Type, at:At}, Fields, Event),
    assertz(authority_event(Context, Seq, Event)).

authority_exception(_, Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
authority_exception(Phase, authority_fault(Detail), error(Error)) :-
    !,
    Error = authority_error{
                phase:Phase,
                kind:invalid_authority_operation,
                detail:Detail,
                message:"authority operation is invalid"
            }.
authority_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = authority_error{
                phase:Phase,
                kind:authority_exception,
                exception:Safe,
                message:"authority operation raised an exception"
            }.

control_exception(rlm_async_cancelled(_)).
control_exception(rlm_cancelled(_)).
control_exception(chain_cancelled(_)).
control_exception(graph_cancelled(_)).
control_exception(cancelled(_)).
control_exception('$aborted').
control_exception(abort).
