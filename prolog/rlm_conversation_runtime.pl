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
same context pack when a warm artifact store is configured and injects a small
provider-visible cold-history boundary when history falls outside the guaranteed
hot tail.

Warm *consumption* is integrated; warm *production* is not automatic.
`conversation_turn/4` never derives, publishes or compacts warm context.  A
caller may publish warm artifacts explicitly with `rlm_conversation_warm` and
then configure `warm_store(Store)` so subsequent managed turns automatically
reuse those artifacts.

The cold-history boundary is synthetic projection state.  It never edits or
replaces a durable user/assistant/tool message.  Its only job is to tell the
model that older history remains addressable through the opaque conversation
context and to show the bounded retrieval operations available to recover it.
*/

:- use_module(library(option)).
:- use_module(rlm_context_budget, []).
:- use_module(rlm_conversation, []).
:- use_module(rlm_conversation_warm, []).

rlm_conversation_runtime_ready :-
    rlm_conversation:rlm_conversation_ready,
    rlm_conversation_warm:rlm_conversation_warm_ready,
    rlm_context_budget:rlm_context_budget_ready.

conversation_context_pack(Conversation, Options0, Outcome) :-
    catch(( prepare_context_options(Conversation,
                                    0,
                                    Options0,
                                    Options,
                                    WarmStatus,
                                    BoundaryStatus),
            rlm_conversation:conversation_context_pack(Conversation,
                                                       Options,
                                                       BaseOutcome),
            annotate_pack_outcome(BaseOutcome,
                                  WarmStatus,
                                  BoundaryStatus,
                                  Outcome)
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
            % The lower conversation layer persists the user message before
            % compiling context, so account for that pending sequence here.
            prepare_context_options(Conversation,
                                    1,
                                    ContextOptions0,
                                    ContextOptions,
                                    WarmStatus,
                                    BoundaryStatus),
            replace_unary_option(context_options,
                                 ContextOptions,
                                 Options0,
                                 Options),
            rlm_conversation:conversation_turn(Conversation,
                                               UserMessage,
                                               Options,
                                               BaseOutcome),
            annotate_turn_outcome(BaseOutcome,
                                  WarmStatus,
                                  BoundaryStatus,
                                  Outcome)
          ),
          Exception,
          runtime_exception(turn, Exception, Outcome)).

/* -------------------------------------------------------------------------
 * Managed context integration
 * ---------------------------------------------------------------------- */

prepare_context_options(Conversation,
                        PendingTurns,
                        Options0,
                        Options,
                        WarmStatus,
                        BoundaryStatus) :-
    require_options(Options0),
    require_nonnegative_integer(PendingTurns, pending_turns),
    option(context_units(ExplicitUnits), Options0, []),
    require_list(ExplicitUnits, context_units),
    option(warm_store(WarmStore), Options0, none),
    warm_context_units(WarmStore,
                       Conversation,
                       Options0,
                       WarmUnits,
                       WarmStatus0),
    remove_explicit_duplicates(WarmUnits, ExplicitUnits, AutoWarmUnits),
    cold_history_boundary_units(Conversation,
                                PendingTurns,
                                Options0,
                                BoundaryUnits,
                                BoundaryStatus),
    append(AutoWarmUnits, BoundaryUnits, ManagedUnits),
    append(ManagedUnits, ExplicitUnits, CombinedUnits),
    length(AutoWarmUnits, LoadedCount),
    put_dict(loaded_units, WarmStatus0, LoadedCount, WarmStatus),
    strip_managed_context_options(Options0, Stripped),
    Options = [context_units(CombinedUnits)|Stripped].

/* -------------------------------------------------------------------------
 * Warm integration
 * ---------------------------------------------------------------------- */

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

/* -------------------------------------------------------------------------
 * Synthetic cold-history boundary
 * ---------------------------------------------------------------------- */

cold_history_boundary_units(Conversation,
                            PendingTurns,
                            Options,
                            Units,
                            Status) :-
    option(cold_history_boundary(Enabled), Options, true),
    require_boolean(Enabled, cold_history_boundary),
    (   Enabled == false
    ->  Units = [],
        Status = cold_history_boundary_status{configured:false,
                                              active:false,
                                              reason:disabled}
    ;   boundary_policy(Options, Policy),
        conversation_message_count(Conversation, ExistingCount),
        ProjectedCount is ExistingCount+PendingTurns,
        ColdThrough is ProjectedCount-Policy.min_recent_turns,
        (   ColdThrough > 0
        ->  HotStart is ColdThrough+1,
            boundary_context_unit(Conversation.id,
                                  ColdThrough,
                                  HotStart,
                                  Options,
                                  Unit,
                                  Tokens),
            Units = [Unit],
            Status = cold_history_boundary_status{
                         configured:true,
                         active:true,
                         cold_range:range(1, ColdThrough),
                         guaranteed_hot_start:HotStart,
                         projected_messages:ProjectedCount,
                         tokens:Tokens}
        ;   Units = [],
            Status = cold_history_boundary_status{
                         configured:true,
                         active:false,
                         reason:no_cold_prefix,
                         projected_messages:ProjectedCount}
        )
    ).

boundary_policy(Options, Policy) :-
    option(policy(PolicyInput), Options, []),
    rlm_context_budget:context_policy(PolicyInput, PolicyOutcome),
    require_budget_outcome(PolicyOutcome, Policy).

conversation_message_count(Conversation, Count) :-
    rlm_conversation:conversation_stats(Conversation, StatsOutcome),
    require_conversation_outcome(StatsOutcome, Stats),
    Count = Stats.messages.

boundary_context_unit(ConversationId,
                      ColdThrough,
                      HotStart,
                      Options,
                      Unit,
                      Tokens) :-
    format(string(Text),
           "Cold history boundary: this conversation has durable history outside the guaranteed rolling hot tail. Sequences 1..~d may be absent from active attention; the guaranteed hot tail begins at sequence ~d. The omitted history is not deleted. If the user refers to an earlier decision, fact, file, symbol, task, person, requirement, or discussion that is not present in active context, retrieve the original history before guessing. Use the opaque conversation context with bounded operations such as context(input(context), search(\"query\"), Result), context(input(context), slice(Start, Length), Result), or context(input(context), peek(item(Index)), Result). Refine searches when results are truncated. Older material may also be represented by warm context, but the cold transcript remains authoritative.",
           [ColdThrough, HotStart]),
    option(token_options(TokenOptions), Options, []),
    require_options(TokenOptions),
    rlm_context_budget:token_count_text(Text,
                                        TokenOptions,
                                        TokenOutcome),
    require_budget_outcome(TokenOutcome, TokenCount),
    Tokens = TokenCount.tokens,
    Value = cold_history_boundary{
                text:Text,
                conversation_id:ConversationId,
                cold_range:range(1, ColdThrough),
                guaranteed_hot_start:HotStart,
                operations:[search, slice, peek]},
    Variant = context_variant{kind:instruction,
                              tokens:Tokens,
                              utility:2000000,
                              value:Value},
    Unit = context_unit{id:managed_cold_history_boundary,
                        section:cold_history_boundary,
                        mandatory:true,
                        variants:[Variant]}.

/* -------------------------------------------------------------------------
 * Context-unit merging
 * ---------------------------------------------------------------------- */

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
managed_context_option(cold_history_boundary(_)).

replace_unary_option(Name, Value, Options0, [Replacement|Rest]) :-
    Replacement =.. [Name, Value],
    exclude(option_named(Name), Options0, Rest).

option_named(Name, Option) :-
    compound(Option),
    functor(Option, Name, 1).

/* -------------------------------------------------------------------------
 * Outcome annotation
 * ---------------------------------------------------------------------- */

annotate_pack_outcome(ok(Pack0), WarmStatus, BoundaryStatus, ok(Pack)) :-
    !,
    put_dict(_{warm:WarmStatus,
               cold_history_boundary:BoundaryStatus},
             Pack0,
             Pack).
annotate_pack_outcome(error(Error), _, _, error(Error)) :- !.
annotate_pack_outcome(Outcome, _, _, error(conversation_runtime_error{
                                              phase:context_pack,
                                              kind:invalid_underlying_outcome,
                                              value:Outcome
                                          })).

annotate_turn_outcome(ok(Turn0), WarmStatus, BoundaryStatus, ok(Turn)) :-
    !,
    (   is_dict(Turn0),
        get_dict(context, Turn0, Context0),
        is_dict(Context0)
    ->  put_dict(_{warm:WarmStatus,
                   cold_history_boundary:BoundaryStatus},
                 Context0,
                 Context),
        put_dict(context, Turn0, Context, Turn)
    ;   Turn = Turn0
    ).
annotate_turn_outcome(error(Error), _, _, error(Error)) :- !.
annotate_turn_outcome(Outcome, _, _, error(conversation_runtime_error{
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

require_boolean(true, _) :- !.
require_boolean(false, _) :- !.
require_boolean(Value, Field) :-
    throw(conversation_runtime_fault(expected_boolean(Field, Value))).

require_nonnegative_integer(Value, _) :-
    integer(Value),
    Value >= 0,
    !.
require_nonnegative_integer(Value, Field) :-
    throw(conversation_runtime_fault(expected_nonnegative_integer(Field,
                                                                  Value))).

require_budget_outcome(ok(Value), Value) :- !.
require_budget_outcome(error(Error), _) :-
    throw(conversation_runtime_fault(context_budget_failed(Error))).
require_budget_outcome(Outcome, _) :-
    throw(conversation_runtime_fault(invalid_context_budget_outcome(Outcome))).

require_conversation_outcome(ok(Value), Value) :- !.
require_conversation_outcome(error(Error), _) :-
    throw(conversation_runtime_fault(conversation_failed(Error))).
require_conversation_outcome(Outcome, _) :-
    throw(conversation_runtime_fault(invalid_conversation_outcome(Outcome))).

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
