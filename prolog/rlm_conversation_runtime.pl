:- module(rlm_conversation_runtime,
          [ rlm_conversation_runtime_ready/0,
            conversation_context_pack/3,
            conversation_token_ledger/3,
            conversation_turn/4
          ]).

/** <module> Managed conversation orchestration

This is the canonical managed-conversation facade.  The lower-level
`rlm_conversation` module owns durable transcript storage, hot projection and
cold-history access.  This module wires already-published warm context into the
same context pack when a warm artifact store is configured.

Warm *consumption* is integrated; warm *production* is not automatic.
`conversation_turn/4` never derives, publishes or compacts warm context.  A
caller may publish warm artifacts explicitly with `rlm_conversation_warm` and
then configure `warm_store(Store)` so subsequent managed turns automatically
reuse those artifacts.
*/

:- use_module(library(option)).
:- use_module(rlm_conversation, []).
:- use_module(rlm_conversation_warm, []).

rlm_conversation_runtime_ready :-
    rlm_conversation:rlm_conversation_ready,
    rlm_conversation_warm:rlm_conversation_warm_ready.

conversation_context_pack(Conversation, Options0, Outcome) :-
    catch(( prepare_context_options(Conversation,
                                    Options0,
                                    Options,
                                    WarmStatus),
            rlm_conversation:conversation_context_pack(Conversation,
                                                       Options,
                                                       BaseOutcome),
            annotate_pack_outcome(BaseOutcome, WarmStatus, Outcome)
          ),
          Exception,
          runtime_exception(context_pack, Exception, Outcome)).

conversation_token_ledger(Conversation, Options, Outcome) :-
    conversation_context_pack(Conversation, Options, PackOutcome),
    (   PackOutcome = ok(Pack)
    ->  Outcome = ok(Pack.ledger)
    ;   PackOutcome = error(Error)
    ->  Outcome = error(Error)
    ;   Outcome = error(conversation_runtime_error{
                            phase:token_ledger,
                            kind:invalid_pack_outcome,
                            value:PackOutcome
                        })
    ).

conversation_turn(Conversation, UserMessage, Options0, Outcome) :-
    catch(( require_options(Options0),
            option(context_options(ContextOptions0), Options0, []),
            prepare_context_options(Conversation,
                                    ContextOptions0,
                                    ContextOptions,
                                    WarmStatus),
            replace_unary_option(context_options,
                                 ContextOptions,
                                 Options0,
                                 Options),
            rlm_conversation:conversation_turn(Conversation,
                                               UserMessage,
                                               Options,
                                               BaseOutcome),
            annotate_turn_outcome(BaseOutcome, WarmStatus, Outcome)
          ),
          Exception,
          runtime_exception(turn, Exception, Outcome)).

/* -------------------------------------------------------------------------
 * Warm integration
 * ---------------------------------------------------------------------- */

prepare_context_options(Conversation, Options0, Options, WarmStatus) :-
    require_options(Options0),
    option(context_units(ExplicitUnits), Options0, []),
    require_list(ExplicitUnits, context_units),
    option(warm_store(WarmStore), Options0, none),
    warm_context_units(WarmStore,
                       Conversation,
                       Options0,
                       WarmUnits,
                       WarmStatus0),
    remove_explicit_duplicates(WarmUnits, ExplicitUnits, AutoWarmUnits),
    append(AutoWarmUnits, ExplicitUnits, CombinedUnits),
    length(AutoWarmUnits, LoadedCount),
    put_dict(loaded_units, WarmStatus0, LoadedCount, WarmStatus),
    strip_managed_context_options(Options0, Stripped),
    Options = [context_units(CombinedUnits)|Stripped].

warm_context_units(none,
                   _,
                   _,
                   [],
                   warm_context_status{configured:false,
                                       store:none,
                                       loaded_units:0}) :-
    !.
warm_context_units(Store,
                   Conversation,
                   Options,
                   Units,
                   warm_context_status{configured:true,
                                       store:Store,
                                       loaded_units:0}) :-
    option(warm_signals(Signals), Options, []),
    require_list(Signals, warm_signals),
    option(warm_options(WarmOptions), Options, []),
    require_options(WarmOptions),
    rlm_conversation_warm:conversation_warm_context_units(
        Conversation,
        Store,
        Signals,
        WarmOptions,
        WarmOutcome),
    require_warm_outcome(WarmOutcome, Units).

require_warm_outcome(ok(Value), Value) :- !.
require_warm_outcome(error(Error), _) :-
    throw(conversation_runtime_fault(warm_context_failed(Error))).
require_warm_outcome(Outcome, _) :-
    throw(conversation_runtime_fault(invalid_warm_outcome(Outcome))).

remove_explicit_duplicates([], _, []).
remove_explicit_duplicates([Unit|Units], Explicit, Result) :-
    (   context_unit_id(Unit, Id),
        explicit_unit_id(Explicit, Id)
    ->  Result = Rest
    ;   Result = [Unit|Rest]
    ),
    remove_explicit_duplicates(Units, Explicit, Rest).

explicit_unit_id(Units, Id) :-
    member(Unit, Units),
    context_unit_id(Unit, Id),
    !.

context_unit_id(Unit, Id) :-
    is_dict(Unit),
    get_dict(id, Unit, Id).

strip_managed_context_options(Options, Stripped) :-
    exclude(managed_context_option, Options, Stripped).

managed_context_option(context_units(_)).
managed_context_option(warm_store(_)).
managed_context_option(warm_signals(_)).
managed_context_option(warm_options(_)).

replace_unary_option(Name, Value, Options0, [Replacement|Rest]) :-
    Replacement =.. [Name, Value],
    exclude(option_named(Name), Options0, Rest).

option_named(Name, Option) :-
    compound(Option),
    functor(Option, Name, 1).

/* -------------------------------------------------------------------------
 * Outcome annotation
 * ---------------------------------------------------------------------- */

annotate_pack_outcome(ok(Pack0), WarmStatus, ok(Pack)) :-
    !,
    put_dict(warm, Pack0, WarmStatus, Pack).
annotate_pack_outcome(error(Error), _, error(Error)) :- !.
annotate_pack_outcome(Outcome, _, error(conversation_runtime_error{
                                           phase:context_pack,
                                           kind:invalid_underlying_outcome,
                                           value:Outcome
                                       })).

annotate_turn_outcome(ok(Turn0), WarmStatus, ok(Turn)) :-
    !,
    (   is_dict(Turn0),
        get_dict(context, Turn0, Context0),
        is_dict(Context0)
    ->  put_dict(warm, Context0, WarmStatus, Context),
        put_dict(context, Turn0, Context, Turn)
    ;   Turn = Turn0
    ).
annotate_turn_outcome(error(Error), _, error(Error)) :- !.
annotate_turn_outcome(Outcome, _, error(conversation_runtime_error{
                                           phase:turn,
                                           kind:invalid_underlying_outcome,
                                           value:Outcome
                                       })).

/* -------------------------------------------------------------------------
 * Validation / errors
 * ---------------------------------------------------------------------- */

require_options(Value) :- is_list(Value), !.
require_options(Value) :-
    throw(conversation_runtime_fault(expected_options(Value))).

require_list(Value, _) :- is_list(Value), !.
require_list(Value, Field) :-
    throw(conversation_runtime_fault(expected_list(Field, Value))).

runtime_exception(Phase,
                  conversation_runtime_fault(Fault),
                  error(conversation_runtime_error{
                            phase:Phase,
                            kind:conversation_runtime_fault,
                            detail:Fault,
                            message:"managed conversation orchestration rejected the operation"
                        })) :-
    !.
runtime_exception(Phase,
                  Exception,
                  error(conversation_runtime_error{
                            phase:Phase,
                            kind:exception,
                            exception:Safe,
                            message:"managed conversation orchestration raised an exception"
                        })) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).
