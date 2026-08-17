:- module(rlm_effect,
          [ rlm_effect_store_open/1,
            rlm_effect_store_close/0,
            rlm_effect_store_attached/1,
            rlm_effect_normalize/2,
            rlm_effect_prepare/4,
            rlm_effect_admit/3,
            rlm_effect_dispatch/2,
            rlm_effect_observe/3,
            rlm_effect_reconcile/3,
            rlm_effect_mark_indeterminate/3,
            rlm_effect_resolve_indeterminate/3,
            rlm_effect_cancel_ticket/3,
            rlm_effect_cancel/3,
            rlm_effect_status/2,
            rlm_effect_observation/2,
            rlm_effect_attempts/3,
            rlm_effect_history/2,
            rlm_effect_idempotency_key/2,
            rlm_effect_prune/2
          ]).

/** <module> Durable identity and observation boundary for external effects

Logical search may backtrack; externally effectful execution may not be replayed
implicitly.  This module separates a logical call, its normalized executable
fingerprint, admitted attempts, and immutable authoritative observations.

The critical crash rule is conservative.  `rlm_effect_dispatch/2` durably marks
an admitted attempt as `dispatching` *before* provider code is called.  A later
process that finds `dispatching` without an observation returns
`reconciliation_required(...)`; it never infers that a missing local result
means the provider did nothing.

This is not a claim of protocol-independent exactly-once execution.  Provider
adapters may use the stable per-attempt idempotency key and may reconcile remote
state.  If they cannot establish the remote outcome, the attempt remains
indeterminate until trusted host policy explicitly resolves it.
*/

:- use_module(library(crypto)).
:- use_module(library(lists)).
:- use_module(rlm_effect_persist, []).

/* Store lifecycle ------------------------------------------------------- */

rlm_effect_store_open(File) :-
    rlm_effect_persist:effect_persist_open(File).

rlm_effect_store_close :-
    rlm_effect_persist:effect_persist_close.

rlm_effect_store_attached(File) :-
    rlm_effect_persist:effect_persist_attached(File).

/* Deterministic normalization ------------------------------------------ */

rlm_effect_normalize(Value, Normalized) :-
    require_normalizable(Value),
    canonical_value(Value, Normalized).

require_normalizable(Value) :-
    (   ground(Value)
    ->  true
    ;   throw(effect_fault(non_ground_request))
    ),
    (   acyclic_term(Value)
    ->  true
    ;   throw(effect_fault(cyclic_request))
    ).

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
canonical_value(Value, Value) :-
    atom(Value),
    !.
canonical_value(Value, Value) :-
    string(Value),
    !.
canonical_value(Value, Value) :-
    number(Value),
    !.
canonical_value(Value, Canonical) :-
    compound(Value),
    !,
    Value =.. [Functor|Args0],
    maplist(canonical_value, Args0, Args),
    Canonical =.. [Functor|Args].
canonical_value(_, _) :-
    throw(effect_fault(unsupported_value)).

canonical_pair(Key-Value0, Key-Value) :-
    canonical_value(Value0, Value).

/* Planning -------------------------------------------------------------- */

rlm_effect_prepare(Kind, Request0, Options0, Outcome) :-
    catch(effect_prepare_(Kind, Request0, Options0, Outcome),
          Exception,
          effect_exception(Exception, Outcome)).

effect_prepare_(Kind, Request0, Options0, Outcome) :-
    require_store,
    require_kind(Kind),
    rlm_effect_normalize(Request0, Request),
    normalize_options(Options0, Options),
    executable_fingerprint(Kind, Request, Options.semantics, Fingerprint),
    logical_call_id(Kind, Request, Options.semantics,
                    Options.logical_key, CallId, LogicalKey),
    ensure_call(CallId, Fingerprint, Kind, Request, LogicalKey),
    prepare_mode(Options.mode, CallId, Fingerprint, Kind, Request,
                 LogicalKey, Options, Outcome).

normalize_options(Options0, Options) :-
    (   is_dict(Options0), ground(Options0)
    ->  true
    ;   throw(effect_fault(invalid_options))
    ),
    validate_option_keys(Options0),
    Defaults = effect_options{mode:initial,
                              parent_attempt:none,
                              logical_key:auto,
                              semantics:semantics{},
                              metadata:metadata{}},
    put_dict(Options0, Defaults, Merged),
    require_mode(Merged.mode),
    normalize_named_dict(semantics, Merged.semantics, Semantics),
    normalize_named_dict(metadata, Merged.metadata, Metadata),
    normalize_logical_key(Merged.logical_key, LogicalKey),
    normalize_parent(Merged.parent_attempt, Parent),
    Options = Merged.put(_{semantics:Semantics,
                           metadata:Metadata,
                           logical_key:LogicalKey,
                           parent_attempt:Parent}).

validate_option_keys(Options) :-
    dict_keys(Options, Keys),
    forall(member(Key, Keys),
           ( memberchk(Key, [mode,parent_attempt,logical_key,semantics,metadata])
           -> true
           ;  throw(effect_fault(unsupported_option)) )).

normalize_named_dict(_, Value0, Value) :-
    is_dict(Value0),
    !,
    rlm_effect_normalize(Value0, Value).
normalize_named_dict(_, _, _) :-
    throw(effect_fault(invalid_options)).

normalize_logical_key(auto, auto) :- !.
normalize_logical_key(Value0, Value) :-
    rlm_effect_normalize(Value0, Value).

normalize_parent(none, none) :- !.
normalize_parent(Value, Value) :-
    atom(Value),
    Value \== '',
    !.
normalize_parent(_, _) :-
    throw(effect_fault(invalid_parent_attempt)).

require_mode(initial) :- !.
require_mode(retry) :- !.
require_mode(resample) :- !.
require_mode(_) :- throw(effect_fault(invalid_mode)).

require_kind(Kind) :-
    atom(Kind),
    Kind \== '',
    !.
require_kind(_) :- throw(effect_fault(invalid_kind)).

executable_fingerprint(Kind, Request, Semantics, Fingerprint) :-
    stable_hash(effect_execution{kind:Kind,
                                 request:Request,
                                 semantics:Semantics},
                'sha256:', Fingerprint).

logical_call_id(Kind, Request, Semantics, auto, CallId, auto) :-
    !,
    stable_hash(effect_logical_call{kind:Kind,
                                    request:Request,
                                    semantics:Semantics},
                'effect-call:', CallId).
logical_call_id(Kind, _, _, LogicalKey, CallId, LogicalKey) :-
    stable_hash(effect_logical_call{kind:Kind,
                                    logical_key:LogicalKey},
                'effect-call:', CallId).

stable_hash(Term, Prefix, Hash) :-
    term_string(Term, Serialized,
                [quoted(true), numbervars(true), ignore_ops(true)]),
    crypto_data_hash(Serialized, Hex,
                     [algorithm(sha256), encoding(utf8)]),
    atom_concat(Prefix, Hex, Hash).

ensure_call(CallId, Fingerprint, Kind, Request, LogicalKey) :-
    get_time(Now),
    Call = effect_call{call_id:CallId,
                       fingerprint:Fingerprint,
                       kind:Kind,
                       request:Request,
                       logical_key:LogicalKey,
                       created_at:Now},
    rlm_effect_persist:effect_persist_put_call(Call).

prepare_mode(initial, CallId, Fingerprint, Kind, Request, LogicalKey,
             Options, Outcome) :-
    !,
    rlm_effect_persist:effect_persist_attempts(CallId, Fingerprint, Attempts),
    prepare_initial(Attempts, CallId, Fingerprint, Kind, Request, LogicalKey,
                    Options, Outcome).
prepare_mode(Mode, CallId, Fingerprint, Kind, Request, LogicalKey,
             Options, Outcome) :-
    memberchk(Mode, [retry,resample]),
    require_explicit_parent(Options.parent_attempt, Parent),
    rlm_effect_persist:effect_persist_get_attempt(Parent, ParentAttempt),
    validate_retry_parent(ParentAttempt, CallId, Fingerprint),
    prepare_explicit(Mode, ParentAttempt, Kind, Request, LogicalKey,
                     Options, Outcome).

prepare_initial([], CallId, Fingerprint, Kind, Request, LogicalKey,
                Options, execute(Ticket)) :-
    !,
    make_ticket(CallId, Fingerprint, Kind, Request, LogicalKey,
                1, none, initial, Options.metadata, Ticket).
prepare_initial(Attempts, _, _, _, _, _, _, Outcome) :-
    last(Attempts, Latest),
    decision_for_existing(Latest, Outcome).

prepare_explicit(Mode, Parent, Kind, Request, LogicalKey, Options, Outcome) :-
    allowed_explicit_parent_status(Parent.status, Parent),
    Sequence is Parent.sequence+1,
    make_ticket(Parent.call_id, Parent.fingerprint, Kind, Request, LogicalKey,
                Sequence, Parent.attempt_id, Mode, Options.metadata, Ticket),
    (   rlm_effect_persist:effect_persist_get_attempt(Ticket.attempt_id, Existing)
    ->  decision_for_existing(Existing, Outcome)
    ;   Outcome = execute(Ticket)
    ).

require_explicit_parent(none, _) :-
    !,
    throw(effect_fault(explicit_parent_required)).
require_explicit_parent(Parent, Parent).

validate_retry_parent(Parent, CallId, Fingerprint) :-
    (   Parent.call_id == CallId,
        Parent.fingerprint == Fingerprint
    ->  true
    ;   throw(effect_fault(changed_payload_not_retry))
    ).

allowed_explicit_parent_status(observed, _) :- !.
allowed_explicit_parent_status(cancelled_before_claim, _) :- !.
allowed_explicit_parent_status(cancelled_pre_dispatch, _) :- !.
allowed_explicit_parent_status(retry_authorized, _) :- !.
allowed_explicit_parent_status(abandoned, _) :- !.
allowed_explicit_parent_status(dispatching, _) :-
    !,
    throw(effect_fault(indeterminate_requires_resolution)).
allowed_explicit_parent_status(cancellation_requested, _) :-
    !,
    throw(effect_fault(indeterminate_requires_resolution)).
allowed_explicit_parent_status(indeterminate, _) :-
    !,
    throw(effect_fault(indeterminate_requires_resolution)).
allowed_explicit_parent_status(admitted, _) :-
    !,
    throw(effect_fault(parent_attempt_active)).
allowed_explicit_parent_status(_, _) :-
    throw(effect_fault(invalid_parent_status)).

make_ticket(CallId, Fingerprint, Kind, Request, LogicalKey, Sequence,
            ParentAttempt, Mode, Metadata, Ticket) :-
    stable_hash(effect_attempt_identity{call_id:CallId,
                                        fingerprint:Fingerprint,
                                        sequence:Sequence,
                                        parent_attempt:ParentAttempt,
                                        mode:Mode},
                'effect-attempt:', AttemptId),
    rlm_effect_idempotency_key(AttemptId, IdempotencyKey),
    get_time(Now),
    Ticket = effect_ticket{call_id:CallId,
                           fingerprint:Fingerprint,
                           kind:Kind,
                           request:Request,
                           logical_key:LogicalKey,
                           attempt_id:AttemptId,
                           sequence:Sequence,
                           parent_attempt:ParentAttempt,
                           mode:Mode,
                           idempotency_key:IdempotencyKey,
                           metadata:Metadata,
                           created_at:Now}.

decision_for_existing(Attempt, replay(Observation)) :-
    rlm_effect_persist:effect_persist_get_observation(Attempt.attempt_id,
                                                      Observation),
    !.
decision_for_existing(Attempt, in_progress(Attempt)) :-
    Attempt.status == admitted,
    !.
decision_for_existing(Attempt, reconciliation_required(Attempt)) :-
    memberchk(Attempt.status,
              [dispatching,cancellation_requested,indeterminate,retry_authorized]),
    !.
decision_for_existing(Attempt, terminal(Attempt)) :-
    memberchk(Attempt.status,
              [cancelled_before_claim,cancelled_pre_dispatch,abandoned]),
    !.
decision_for_existing(Attempt, error(effect_error{kind:missing_observation})) :-
    Attempt.status == observed,
    !.
decision_for_existing(_, error(effect_error{kind:invalid_attempt_state})).

/* Admission ------------------------------------------------------------- */

rlm_effect_admit(Ticket, Authority0, Outcome) :-
    catch(effect_admit_(Ticket, Authority0, Outcome),
          Exception,
          effect_exception(Exception, Outcome)).

effect_admit_(Ticket, Authority0, Outcome) :-
    require_store,
    validate_ticket(Ticket),
    rlm_effect_normalize(Authority0, Authority),
    with_mutex(rlm_effect_state,
               admit_locked(Ticket, Authority, Outcome)).

admit_locked(Ticket, _, Outcome) :-
    rlm_effect_persist:effect_persist_get_attempt(Ticket.attempt_id, Existing),
    !,
    admission_existing(Existing, Outcome).
admit_locked(Ticket, Authority, execute(Attempt)) :-
    ticket_attempt(Ticket, Authority, admitted, 1, Attempt),
    rlm_effect_persist:effect_persist_put_attempt(Attempt),
    append_attempt_event(Attempt, attempt_admitted, _{authority:Authority}).

admission_existing(Attempt, replay(Observation)) :-
    rlm_effect_persist:effect_persist_get_observation(Attempt.attempt_id,
                                                      Observation),
    !.
admission_existing(Attempt, in_progress(Attempt)) :-
    memberchk(Attempt.status, [admitted,dispatching,cancellation_requested,
                               indeterminate,retry_authorized]),
    !.
admission_existing(Attempt, terminal(Attempt)) :-
    memberchk(Attempt.status,
              [cancelled_before_claim,cancelled_pre_dispatch,abandoned,observed]),
    !.
admission_existing(Attempt, error(effect_error{kind:invalid_attempt_state,
                                                status:Status})) :-
    Status = Attempt.status.

validate_ticket(Ticket) :-
    (   is_dict(Ticket, effect_ticket), ground(Ticket),
        get_dict(call_id, Ticket, _),
        get_dict(fingerprint, Ticket, _),
        get_dict(kind, Ticket, _),
        get_dict(request, Ticket, _),
        get_dict(logical_key, Ticket, _),
        get_dict(attempt_id, Ticket, _),
        get_dict(sequence, Ticket, _),
        get_dict(parent_attempt, Ticket, _),
        get_dict(mode, Ticket, _),
        get_dict(idempotency_key, Ticket, _),
        get_dict(metadata, Ticket, _),
        get_dict(created_at, Ticket, _)
    ->  true
    ;   throw(effect_fault(invalid_ticket))
    ).

ticket_attempt(Ticket, Authority, Status, Revision, Attempt) :-
    get_time(Now),
    Attempt = effect_attempt{attempt_id:Ticket.attempt_id,
                             revision:Revision,
                             call_id:Ticket.call_id,
                             fingerprint:Ticket.fingerprint,
                             sequence:Ticket.sequence,
                             parent_attempt:Ticket.parent_attempt,
                             mode:Ticket.mode,
                             status:Status,
                             idempotency_key:Ticket.idempotency_key,
                             authority:Authority,
                             metadata:Ticket.metadata,
                             created_at:Ticket.created_at,
                             updated_at:Now}.

/* Dispatch boundary ----------------------------------------------------- */

rlm_effect_dispatch(AttemptId, Outcome) :-
    catch(effect_dispatch_(AttemptId, Outcome),
          Exception,
          effect_exception(Exception, Outcome)).

effect_dispatch_(AttemptId, Outcome) :-
    require_store,
    require_attempt_id(AttemptId),
    with_mutex(rlm_effect_state,
               dispatch_locked(AttemptId, Outcome)).

dispatch_locked(AttemptId, replay(Observation)) :-
    rlm_effect_persist:effect_persist_get_observation(AttemptId, Observation),
    !.
dispatch_locked(AttemptId, dispatch(Updated)) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    Attempt.status == admitted,
    !,
    update_attempt_status(Attempt, dispatching, Attempt.authority,
                          Attempt.metadata, Updated),
    append_attempt_event(Updated, attempt_dispatched,
                         _{idempotency_key:Updated.idempotency_key}).
dispatch_locked(AttemptId, in_progress(Attempt)) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    Attempt.status == dispatching,
    !.
dispatch_locked(AttemptId, reconciliation_required(Attempt)) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    memberchk(Attempt.status,
              [cancellation_requested,indeterminate,retry_authorized]),
    !.
dispatch_locked(AttemptId, terminal(Attempt)) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    memberchk(Attempt.status,
              [cancelled_before_claim,cancelled_pre_dispatch,abandoned,observed]),
    !.
dispatch_locked(AttemptId, error(effect_error{kind:unknown_attempt})) :-
    \+ rlm_effect_persist:effect_persist_get_attempt(AttemptId, _),
    !.
dispatch_locked(_, error(effect_error{kind:invalid_attempt_state})).

/* Observations and reconciliation -------------------------------------- */

rlm_effect_observe(AttemptId, Observation0, Outcome) :-
    catch(record_observation_(normal, AttemptId, Observation0, Outcome),
          Exception,
          effect_exception(Exception, Outcome)).

rlm_effect_reconcile(AttemptId, Observation0, Outcome) :-
    catch(record_observation_(reconciliation, AttemptId, Observation0,
                              ReconcileOutcome),
          Exception,
          effect_exception(Exception, ReconcileOutcome)),
    reconcile_shape(ReconcileOutcome, Outcome).

reconcile_shape(observed(Observation), reconciled(Observation)) :- !.
reconcile_shape(Other, Other).

record_observation_(Source, AttemptId, Observation0, Outcome) :-
    require_store,
    require_attempt_id(AttemptId),
    normalize_observation(Observation0, ObservationBody),
    with_mutex(rlm_effect_state,
               record_observation_locked(Source, AttemptId, ObservationBody,
                                         Outcome)).

normalize_observation(Observation0, Observation) :-
    (   is_dict(Observation0), ground(Observation0)
    ->  true
    ;   throw(effect_fault(invalid_observation))
    ),
    require_observation_field(Observation0, status, Status),
    require_observation_field(Observation0, value, _),
    require_observation_field(Observation0, usage, _),
    require_observation_field(Observation0, provenance, _),
    (   memberchk(Status, [succeeded,failed,cancelled])
    ->  true
    ;   throw(effect_fault(invalid_observation_status))
    ),
    rlm_effect_normalize(Observation0, Observation).

require_observation_field(Observation, Key, Value) :-
    (   get_dict(Key, Observation, Value)
    ->  true
    ;   throw(effect_fault(invalid_observation))
    ).

record_observation_locked(_, AttemptId, ObservationBody,
                          observed(Existing)) :-
    rlm_effect_persist:effect_persist_get_observation(AttemptId, Existing),
    Existing == ObservationBody,
    !,
    settle_observed_status(AttemptId).
record_observation_locked(_, AttemptId, _,
                          error(effect_error{kind:observation_conflict})) :-
    rlm_effect_persist:effect_persist_get_observation(AttemptId, _),
    !.
record_observation_locked(Source, AttemptId, ObservationBody,
                          observed(ObservationBody)) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    observation_allowed_status(Attempt.status),
    !,
    rlm_effect_persist:effect_persist_put_observation(AttemptId,
                                                      ObservationBody),
    update_attempt_status(Attempt, observed, Attempt.authority,
                          Attempt.metadata, Updated),
    append_attempt_event(Updated, observation_recorded,
                         _{source:Source,
                           observation_status:ObservationBody.status,
                           usage:ObservationBody.usage,
                           provenance:ObservationBody.provenance}).
record_observation_locked(_, AttemptId, _,
                          error(effect_error{kind:observation_not_admissible})) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, _),
    !.
record_observation_locked(_, _, _,
                          error(effect_error{kind:unknown_attempt})).

observation_allowed_status(dispatching).
observation_allowed_status(cancellation_requested).
observation_allowed_status(indeterminate).
observation_allowed_status(retry_authorized).

settle_observed_status(AttemptId) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    (   Attempt.status == observed
    ->  true
    ;   observation_allowed_status(Attempt.status)
    ->  update_attempt_status(Attempt, observed, Attempt.authority,
                              Attempt.metadata, _)
    ;   true
    ).

rlm_effect_mark_indeterminate(AttemptId, Reason0, Outcome) :-
    catch(effect_mark_indeterminate_(AttemptId, Reason0, Outcome),
          Exception,
          effect_exception(Exception, Outcome)).

effect_mark_indeterminate_(AttemptId, Reason0, Outcome) :-
    require_store,
    rlm_effect_normalize(Reason0, Reason),
    with_mutex(rlm_effect_state,
               mark_indeterminate_locked(AttemptId, Reason, Outcome)).

mark_indeterminate_locked(AttemptId, _, replay(Observation)) :-
    rlm_effect_persist:effect_persist_get_observation(AttemptId, Observation),
    !.
mark_indeterminate_locked(AttemptId, Reason, indeterminate(Updated)) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    memberchk(Attempt.status, [dispatching,cancellation_requested]),
    !,
    put_dict(indeterminate_reason, Attempt.metadata, Reason, Metadata),
    update_attempt_status(Attempt, indeterminate, Attempt.authority,
                          Metadata, Updated),
    append_attempt_event(Updated, attempt_indeterminate, _{reason:Reason}).
mark_indeterminate_locked(AttemptId, _, indeterminate(Attempt)) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    Attempt.status == indeterminate,
    !.
mark_indeterminate_locked(AttemptId, _, error(effect_error{kind:unknown_attempt})) :-
    \+ rlm_effect_persist:effect_persist_get_attempt(AttemptId, _),
    !.
mark_indeterminate_locked(_, _,
                          error(effect_error{kind:invalid_indeterminate_transition})).

rlm_effect_resolve_indeterminate(AttemptId, Resolution, Outcome) :-
    catch(effect_resolve_indeterminate_(AttemptId, Resolution, Outcome),
          Exception,
          effect_exception(Exception, Outcome)).

effect_resolve_indeterminate_(AttemptId, Resolution, Outcome) :-
    require_store,
    (   memberchk(Resolution, [retry_authorized,abandoned])
    ->  true
    ;   throw(effect_fault(invalid_indeterminate_resolution))
    ),
    with_mutex(rlm_effect_state,
               resolve_indeterminate_locked(AttemptId, Resolution, Outcome)).

resolve_indeterminate_locked(AttemptId, _, replay(Observation)) :-
    rlm_effect_persist:effect_persist_get_observation(AttemptId, Observation),
    !.
resolve_indeterminate_locked(AttemptId, Resolution, resolved(Updated)) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    Attempt.status == indeterminate,
    !,
    put_dict(indeterminate_resolution, Attempt.metadata, Resolution, Metadata),
    update_attempt_status(Attempt, Resolution, Attempt.authority,
                          Metadata, Updated),
    append_attempt_event(Updated, indeterminate_resolved,
                         _{resolution:Resolution}).
resolve_indeterminate_locked(AttemptId, _, error(effect_error{kind:unknown_attempt})) :-
    \+ rlm_effect_persist:effect_persist_get_attempt(AttemptId, _),
    !.
resolve_indeterminate_locked(_, _,
                             error(effect_error{kind:not_indeterminate})).

/* Cancellation ---------------------------------------------------------- */

rlm_effect_cancel_ticket(Ticket, Reason0, Outcome) :-
    catch(effect_cancel_ticket_(Ticket, Reason0, Outcome),
          Exception,
          effect_exception(Exception, Outcome)).

effect_cancel_ticket_(Ticket, Reason0, Outcome) :-
    require_store,
    validate_ticket(Ticket),
    rlm_effect_normalize(Reason0, Reason),
    with_mutex(rlm_effect_state,
               cancel_ticket_locked(Ticket, Reason, Outcome)).

cancel_ticket_locked(Ticket, _, Outcome) :-
    rlm_effect_persist:effect_persist_get_attempt(Ticket.attempt_id, Attempt),
    !,
    cancellation_existing(Attempt, Outcome).
cancel_ticket_locked(Ticket, Reason, cancelled(Attempt)) :-
    Metadata = Ticket.metadata.put(cancellation_reason, Reason),
    TicketWithMetadata = Ticket.put(metadata, Metadata),
    ticket_attempt(TicketWithMetadata, none, cancelled_before_claim, 1, Attempt),
    rlm_effect_persist:effect_persist_put_attempt(Attempt),
    append_attempt_event(Attempt, attempt_cancelled,
                         _{phase:before_claim, reason:Reason}).

rlm_effect_cancel(AttemptId, Reason0, Outcome) :-
    catch(effect_cancel_(AttemptId, Reason0, Outcome),
          Exception,
          effect_exception(Exception, Outcome)).

effect_cancel_(AttemptId, Reason0, Outcome) :-
    require_store,
    require_attempt_id(AttemptId),
    rlm_effect_normalize(Reason0, Reason),
    with_mutex(rlm_effect_state,
               cancel_locked(AttemptId, Reason, Outcome)).

cancel_locked(AttemptId, _, replay(Observation)) :-
    rlm_effect_persist:effect_persist_get_observation(AttemptId, Observation),
    !.
cancel_locked(AttemptId, Reason, cancelled(Updated)) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    Attempt.status == admitted,
    !,
    put_dict(cancellation_reason, Attempt.metadata, Reason, Metadata),
    update_attempt_status(Attempt, cancelled_pre_dispatch, Attempt.authority,
                          Metadata, Updated),
    append_attempt_event(Updated, attempt_cancelled,
                         _{phase:pre_dispatch, reason:Reason}).
cancel_locked(AttemptId, Reason, reconciliation_required(Updated)) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    Attempt.status == dispatching,
    !,
    put_dict(cancellation_reason, Attempt.metadata, Reason, Metadata),
    update_attempt_status(Attempt, cancellation_requested, Attempt.authority,
                          Metadata, Updated),
    append_attempt_event(Updated, cancellation_requested,
                         _{reason:Reason}).
cancel_locked(AttemptId, _, reconciliation_required(Attempt)) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    memberchk(Attempt.status,
              [cancellation_requested,indeterminate,retry_authorized]),
    !.
cancel_locked(AttemptId, _, cancelled(Attempt)) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    memberchk(Attempt.status, [cancelled_before_claim,cancelled_pre_dispatch]),
    !.
cancel_locked(AttemptId, _, terminal(Attempt)) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    Attempt.status == abandoned,
    !.
cancel_locked(AttemptId, _, error(effect_error{kind:unknown_attempt})) :-
    \+ rlm_effect_persist:effect_persist_get_attempt(AttemptId, _),
    !.
cancel_locked(_, _, error(effect_error{kind:invalid_cancel_transition})).

cancellation_existing(Attempt, replay(Observation)) :-
    rlm_effect_persist:effect_persist_get_observation(Attempt.attempt_id,
                                                      Observation),
    !.
cancellation_existing(Attempt, cancelled(Attempt)) :-
    memberchk(Attempt.status,
              [cancelled_before_claim,cancelled_pre_dispatch]),
    !.
cancellation_existing(Attempt, reconciliation_required(Attempt)) :-
    memberchk(Attempt.status,
              [dispatching,cancellation_requested,indeterminate,retry_authorized]),
    !.
cancellation_existing(Attempt, in_progress(Attempt)) :-
    Attempt.status == admitted,
    !.
cancellation_existing(Attempt, terminal(Attempt)).

/* Inspection, accounting and retention --------------------------------- */

rlm_effect_status(AttemptId, Outcome) :-
    catch(effect_status_(AttemptId, Outcome),
          Exception,
          effect_exception(Exception, Outcome)).

effect_status_(AttemptId, Outcome) :-
    require_store,
    require_attempt_id(AttemptId),
    with_mutex(rlm_effect_state,
               status_locked(AttemptId, Outcome)).

status_locked(AttemptId, Attempt) :-
    rlm_effect_persist:effect_persist_get_observation(AttemptId, _),
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Current),
    Current.status \== observed,
    observation_allowed_status(Current.status),
    !,
    update_attempt_status(Current, observed, Current.authority,
                          Current.metadata, Attempt).
status_locked(AttemptId, Attempt) :-
    rlm_effect_persist:effect_persist_get_attempt(AttemptId, Attempt),
    !.
status_locked(_, error(effect_error{kind:unknown_attempt})).

rlm_effect_observation(AttemptId, Outcome) :-
    catch(effect_observation_(AttemptId, Outcome),
          Exception,
          effect_exception(Exception, Outcome)).

effect_observation_(AttemptId, Observation) :-
    require_store,
    require_attempt_id(AttemptId),
    rlm_effect_persist:effect_persist_get_observation(AttemptId, Observation),
    !.
effect_observation_(_, error(effect_error{kind:no_observation})).

rlm_effect_attempts(CallId, Fingerprint, Attempts) :-
    rlm_effect_persist:effect_persist_attempts(CallId, Fingerprint, Attempts).

rlm_effect_history(CallId, Events) :-
    rlm_effect_persist:effect_persist_events(CallId, Events).

rlm_effect_idempotency_key(AttemptId, Key) :-
    require_attempt_id(AttemptId),
    stable_hash(provider_idempotency{attempt_id:AttemptId},
                'rlm-effect:', Key).

rlm_effect_prune(CallId, Outcome) :-
    catch(effect_prune_(CallId, Outcome),
          Exception,
          effect_exception(Exception, Outcome)).

effect_prune_(CallId, Outcome) :-
    require_store,
    atom(CallId),
    rlm_effect_persist:effect_persist_attempts(CallId, _, Attempts),
    (   forall(member(Attempt, Attempts), prunable_status(Attempt.status))
    ->  rlm_effect_persist:effect_persist_delete_call(CallId),
        Outcome = pruned
    ;   Outcome = error(effect_error{kind:active_or_indeterminate_attempt})
    ).

prunable_status(observed).
prunable_status(cancelled_before_claim).
prunable_status(cancelled_pre_dispatch).
prunable_status(abandoned).

/* State revision helpers ------------------------------------------------ */

update_attempt_status(Attempt, Status, Authority, Metadata, Updated) :-
    Revision is Attempt.revision+1,
    get_time(Now),
    Updated = Attempt.put(_{revision:Revision,
                            status:Status,
                            authority:Authority,
                            metadata:Metadata,
                            updated_at:Now}),
    rlm_effect_persist:effect_persist_put_attempt(Updated).

append_attempt_event(Attempt, Type, Detail0) :-
    get_time(Now),
    Detail = Detail0.put(_{attempt_id:Attempt.attempt_id,
                           fingerprint:Attempt.fingerprint,
                           mode:Attempt.mode,
                           status:Attempt.status,
                           timestamp:Now}),
    Event = effect_event{type:Type,
                         detail:Detail},
    rlm_effect_persist:effect_persist_append_event(Attempt.call_id, Event).

require_attempt_id(AttemptId) :-
    atom(AttemptId),
    AttemptId \== '',
    !.
require_attempt_id(_) :- throw(effect_fault(invalid_attempt_id)).

require_store :-
    (   rlm_effect_persist:effect_persist_attached(_)
    ->  true
    ;   throw(effect_fault(store_not_open))
    ).

/* Error boundary -------------------------------------------------------- */

effect_exception(effect_fault(Kind), error(effect_error{kind:Kind})) :- !.
effect_exception(error(permission_error(redefine, effect_observation, _), _),
                 error(effect_error{kind:observation_conflict})) :- !.
effect_exception(error(existence_error(effect_persistent_backend, attached), _),
                 error(effect_error{kind:store_not_open})) :- !.
effect_exception(Exception,
                 error(effect_error{kind:internal_error,
                                    detail:Safe})) :-
    safe_term(Exception, Safe).

safe_term(Term, Safe) :-
    catch(term_string(Term, Safe,
                      [quoted(true), numbervars(true), max_depth(6)]),
          _,
          Safe = "unavailable").
