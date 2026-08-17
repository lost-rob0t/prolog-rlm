:- module(rlm_effect_authority,
          [ effect_authority_operation/4,
            effect_authorize/6
          ]).

/** <module> #57 effect identity composition with #53 host authority

Authority mediates an already-normalized executable proposal.  Effect identity
must therefore be part of the authority fingerprint, but trace/session
correlation must not be.  This module builds that exact composition without
creating a second authority system.

An explicit retry or resample has a different attempt identity from its parent.
Consequently an `allow_once` permit for the parent cannot silently authorize the
new attempt.  A changed executable payload likewise carries a new #57
fingerprint.
*/

:- use_module(rlm_authority, []).

%! effect_authority_operation(+Ticket,+BaseOperation,+Correlation,-Operation)
%
%  BaseOperation is the already validated #53 operation shape containing at
%  least name/effect/capability. Correlation is preserved for tracing and is
%  excluded by rlm_authority from executable authority identity.

effect_authority_operation(Ticket, BaseOperation0, Correlation, Operation) :-
    require_ticket(Ticket),
    require_base_operation(BaseOperation0),
    require_ground(Correlation, correlation),
    Identity = effect_identity{call_id:Ticket.call_id,
                               fingerprint:Ticket.fingerprint,
                               attempt_id:Ticket.attempt_id,
                               mode:Ticket.mode,
                               parent_attempt:Ticket.parent_attempt},
    put_dict(_{effect_identity:Identity,
               correlation:Correlation},
             BaseOperation0,
             Operation).

%! effect_authorize(+Context,+Ticket,+BaseOperation,+Continuation,
%!                  +EditValidator,-Outcome)
%
%  Delegate the actual policy decision to #53. No mode widening occurs here.

effect_authorize(Context, Ticket, BaseOperation, Continuation, EditValidator,
                 Outcome) :-
    effect_authority_operation(Ticket, BaseOperation, correlation{}, Operation),
    rlm_authority:rlm_authorize_operation(Context, Operation,
                                          Continuation, EditValidator,
                                          Outcome).

require_ticket(Ticket) :-
    is_dict(Ticket, effect_ticket),
    ground(Ticket),
    get_dict(call_id, Ticket, _),
    get_dict(fingerprint, Ticket, _),
    get_dict(attempt_id, Ticket, _),
    get_dict(mode, Ticket, _),
    get_dict(parent_attempt, Ticket, _),
    !.
require_ticket(Ticket) :-
    throw(error(domain_error(effect_ticket, Ticket), _)).

require_base_operation(Operation) :-
    is_dict(Operation),
    ground(Operation),
    get_dict(name, Operation, _),
    get_dict(effect, Operation, _),
    get_dict(capability, Operation, _),
    !.
require_base_operation(Operation) :-
    throw(error(domain_error(authority_operation, Operation), _)).

require_ground(Value, _) :- ground(Value), !.
require_ground(Value, Role) :-
    throw(error(instantiation_error,
                context(rlm_effect_authority, Role-Value))).
