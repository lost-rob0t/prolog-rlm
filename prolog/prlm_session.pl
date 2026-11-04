:- module(prlm_session,
          [ prlm_session_ready/0,
            prlm_session_new/2,
            prlm_session_destroy/1,
            prlm_session_engine/2,
            prlm_session_option/3,
            prlm_event_emit/3,
            prlm_event_emit/4,
            prlm_event_type/1,
            prlm_events/3,
            prlm_events_jsonl/2,
            prlm_last_event/2,
            prlm_subscribe/3,
            prlm_unsubscribe/2,
            prlm_budget_check/3,
            prlm_budget_charge/3,
            prlm_budget_left/3,
            prlm_authority_set/2,
            prlm_authority_current/2,
            prlm_authority_allows/2,
            prlm_authority_child/3,
            prlm_cancel_token_new/1,
            prlm_session_token/2,
            prlm_cancel/1,
            prlm_cancelled/1,
            prlm_check_cancelled/1,
            prlm_session_put/3,
            prlm_session_put_new/3,
            prlm_session_append/3,
            prlm_session_get/3,
            prlm_session_delete/2
          ]).

/** <module> prlm_session — RLM runtime session over the stage0 kernel

Why this exists
===============

Everything above the kernel needs one shared substrate per running RLM:

1. *One normalized event stream.* OpenCode, Zara and MCP UIs must all see
   the same ordered, typed facts about a run. Rather than letting every
   layer invent its own logging, a session is the single producer of a
   per-session monotonic event sequence (seq 1,2,3,...) of closed event
   dicts. The only I/O this module performs is prlm_events_jsonl/2, the
   export boundary where the stream becomes JSON Lines for external
   consumers; subscribers (trusted host code) observe events in-memory.

2. *Shared budgets.* Recursive agents spawn nested scopes that would
   otherwise each get a fresh allowance and escape accounting. Budget
   counters (steps, tool_calls, depth, repairs) live on the session, not
   on any caller frame, so a nested call charged through the same session
   draws down the same remaining budget. prlm_budget_check/3 is
   fail-closed: it emits a budget event *before* throwing so the stream
   records the exhaustion even though the goal dies.

3. *Authority tiers.* The canonical tiers are exactly approve_diff <
   allow_once < allow_session < dangerous. Sessions may only *narrow* an
   authority tier, children derive from prlm_authority_child/3 as the
   minimum of parent and request (a child can never widen), and
   allow_once is a consumable: prlm_authority_allows/2 spends one use per
   match and fails once exhausted.

4. *Fail-closed cancellation.* Tokens are fresh atoms; cancellation is
   idempotent and one-directional. prlm_check_cancelled/1 throws
   prlm_error(cancellation,_) on a cancelled session so worker loops
   cannot accidentally continue past a cancel.

5. *One state substrate.* prlm_session_put/get/append/delete is the
   session-scoped key-value store upper layers (tools, actors, providers,
   rlm) build their registries on, instead of each inventing its own
   dynamic predicates keyed by scope.

Session state is kept in module-local dynamic predicates keyed by the
session handle, mirroring the kernel's engine state discipline. Errors
follow the kernel error model: throw(prlm_error(Type, InfoDict)) with
InfoDict a real SWI dict.
*/

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).
:- use_module(library(gensym)).
:- use_module(library(readutil)).
:- use_module(library(http/json)).
:- use_module('./prlm_kernel').

:- meta_predicate prlm_subscribe(+, +, 1).

prlm_session_ready.

% ============================================================
% Session state (module-local dynamic storage, keyed by Session)
% ============================================================

:- dynamic session_opt/3.       % session_opt(Session, Opt, Value)
:- dynamic session_budget/3.    % session_budget(Session, Kind, Remaining)
:- dynamic session_seq/2.       % session_seq(Session, NextSeq)
:- dynamic session_event/3.     % session_event(Session, Seq, EventDict)
:- dynamic session_sub/3.       % session_sub(Session, Name, Goal)
:- dynamic session_kv/3.        % session_kv(Session, Key, Value)
:- dynamic token_session/2.     % token_session(Token, Session)
:- dynamic cancelled_token/1.   % cancelled_token(Token)

budget_kinds([steps, tool_calls, depth, repairs]).

budget_kind(steps).
budget_kind(tool_calls).
budget_kind(depth).
budget_kind(repairs).

% Defaults for the session budget dict; depth and repairs are fixed by
% the contract, steps/tool_calls get conservative process-scale defaults.
default_budget(steps, 1000000).
default_budget(tool_calls, 10000).
default_budget(depth, 500).
default_budget(repairs, 3).

authority_tier(approve_diff).
authority_tier(allow_once).
authority_tier(allow_session).
authority_tier(dangerous).

tier_rank(approve_diff, 0).
tier_rank(allow_once, 1).
tier_rank(allow_session, 2).
tier_rank(dangerous, 3).

canonical_event_type(session_start).
canonical_event_type(specification).
canonical_event_type(mode_select).
canonical_event_type(plan).
canonical_event_type(model_call).
canonical_event_type(tool_call).
canonical_event_type(actor_spawn).
canonical_event_type(actor_message).
canonical_event_type(observation).
canonical_event_type(verification).
canonical_event_type(repair).
canonical_event_type(learning).
canonical_event_type(failure).
canonical_event_type(cancellation).
canonical_event_type(completion).
canonical_event_type(budget).
canonical_event_type(context_compiled).

%! prlm_event_type(?Type) is semidet
%
% True when Type is a canonical session event type.
prlm_event_type(Type) :-
    canonical_event_type(Type).

% ============================================================
% Error helpers
% ============================================================

require_session(Session) :-
    (   session_opt(Session, provider, _)
    ->  true
    ;   throw(prlm_error(existence_error, _{session: Session}))
    ).

require_budget_kind(Kind) :-
    (   budget_kind(Kind)
    ->  true
    ;   throw(prlm_error(type_error, _{budget_kind: Kind}))
    ).

require_cost(Cost) :-
    (   var(Cost)
    ->  throw(prlm_error(instantiation_error, _{cost: Cost}))
    ;   integer(Cost),
        Cost >= 0
    ->  true
    ;   throw(prlm_error(type_error, _{cost: Cost}))
    ).

require_tier(Tier, Key) :-
    (   authority_tier(Tier)
    ->  true
    ;   dict_create(Info, _, [Key-Tier]),
        throw(prlm_error(type_error, Info))
    ).

require_token(Token) :-
    (   var(Token)
    ->  throw(prlm_error(instantiation_error, _{token: Token}))
    ;   atom(Token)
    ->  true
    ;   throw(prlm_error(type_error, _{token: Token}))
    ).

% closed_term(+Term): Term contains no unbound variables. Unlike ground/1
% this ignores dict tags, so the conventional `_{...}` literals (whose
% tags are anonymous variables) count as closed.
closed_term(T) :-
    (   var(T)
    ->  false
    ;   is_dict(T)
    ->  dict_pairs(T, _, Pairs),
        forall(member(_-V, Pairs), closed_term(V))
    ;   compound(T)
    ->  T =.. [_|Args],
        forall(member(A, Args), closed_term(A))
    ;   true
    ).

% ============================================================
% Session lifecycle
% ============================================================

%! prlm_session_new(+Options, -Session) is det
%
% Create a session (atom handle) with an owned kernel engine, default
% budgets, authority approve_diff, provider prolog, and a fresh default
% cancellation token. Options:
%
%   * budgets(Dict): _{steps,tool_calls,depth,repairs} limits; omitted
%     keys keep the defaults (steps 1000000, tool_calls 10000,
%     depth 500, repairs 3).
%   * authority(Tier): one of approve_diff, allow_once, allow_session,
%     dangerous.
%   * provider(Name): provider atom.
%
% Emits the session_start event (seq 1).
prlm_session_new(Options, Session) :-
    gensym(prlm_session, Session),
    init_budgets(Session),
    assertz(session_opt(Session, authority, approve_diff)),
    assertz(session_opt(Session, allow_once_left, 0)),
    assertz(session_opt(Session, provider, prolog)),
    apply_session_options(Options, Session),
    session_opt(Session, limit(steps), StepsLimit),
    prlm_engine_new([max_steps(StepsLimit)], Engine),
    assertz(session_opt(Session, engine, Engine)),
    gensym(prlm_token, Token),
    assertz(session_opt(Session, token, Token)),
    assertz(token_session(Token, Session)),
    session_opt(Session, authority, Authority),
    session_opt(Session, provider, Provider),
    session_limits(Session, Limits),
    prlm_event_emit(Session, session_start,
                    _{authority: Authority,
                      provider: Provider,
                      budgets: Limits,
                      token: Token}).

init_budgets(Session) :-
    budget_kinds(Kinds),
    forall(member(Kind, Kinds),
           (   default_budget(Kind, Def),
               assertz(session_budget(Session, Kind, Def)),
               assertz(session_opt(Session, limit(Kind), Def))
           )).

apply_session_options([], _).
apply_session_options([Opt|Rest], Session) :-
    apply_session_option(Opt, Session),
    apply_session_options(Rest, Session).

apply_session_option(budgets(Budgets), Session) :-
    !,
    (   is_dict(Budgets)
    ->  true
    ;   throw(prlm_error(type_error, _{budgets: Budgets}))
    ),
    dict_pairs(Budgets, budgets, Pairs),
    forall(member(Kind-Cost, Pairs),
           set_budget(Session, Kind, Cost)).
apply_session_option(authority(Tier), Session) :-
    !,
    require_tier(Tier, authority),
    set_authority(Session, Tier).
apply_session_option(provider(Provider), Session) :-
    !,
    (   atom(Provider)
    ->  true
    ;   throw(prlm_error(type_error, _{provider: Provider}))
    ),
    retractall(session_opt(Session, provider, _)),
    assertz(session_opt(Session, provider, Provider)).
apply_session_option(Opt, _) :-
    throw(prlm_error(type_error, _{session_option: Opt})).

set_budget(Session, Kind, Cost) :-
    require_budget_kind(Kind),
    (   var(Cost) ; \+ integer(Cost) ; Cost =< 0
    ->  throw(prlm_error(type_error, _{budget: _{kind: Kind, limit: Cost}}))
    ;   true
    ),
    retractall(session_budget(Session, Kind, _)),
    assertz(session_budget(Session, Kind, Cost)),
    retractall(session_opt(Session, limit(Kind), _)),
    assertz(session_opt(Session, limit(Kind), Cost)).

set_authority(Session, Tier) :-
    retractall(session_opt(Session, authority, _)),
    assertz(session_opt(Session, authority, Tier)),
    (   Tier == allow_once
    ->  Uses = 1
    ;   Uses = 0
    ),
    retractall(session_opt(Session, allow_once_left, _)),
    assertz(session_opt(Session, allow_once_left, Uses)).

session_limits(Session, limits{steps:S, tool_calls:T, depth:D, repairs:R}) :-
    session_opt(Session, limit(steps), S),
    session_opt(Session, limit(tool_calls), T),
    session_opt(Session, limit(depth), D),
    session_opt(Session, limit(repairs), R).

%! prlm_session_destroy(+Session) is det
%
% Tear down the session: destroy the owned kernel engine and drop all
% session state (events, budgets, subscribers, KVS, token mapping).
% Idempotent.
prlm_session_destroy(Session) :-
    (   session_opt(Session, engine, Engine)
    ->  prlm_engine_destroy(Engine)
    ;   true
    ),
    retractall(session_opt(Session, _, _)),
    retractall(session_budget(Session, _, _)),
    retractall(session_seq(Session, _)),
    retractall(session_event(Session, _, _)),
    retractall(session_sub(Session, _, _)),
    retractall(session_kv(Session, _, _)),
    retractall(token_session(_, Session)).

%! prlm_session_engine(+Session, -Engine) is det
%
% Expose the kernel engine owned by the session.
prlm_session_engine(Session, Engine) :-
    require_session(Session),
    session_opt(Session, engine, Engine).

%! prlm_session_option(+Session, +Key, -Value) is det
%
% Read-only view of session configuration. budgets reads the CURRENT
% remaining values via prlm_budget_left/3; max_depth and repairs read the
% configured limits; authority and provider read the live settings.
prlm_session_option(Session, budgets, Value) :-
    !,
    require_session(Session),
    budget_left_all(Session, Value).
prlm_session_option(Session, authority, Value) :-
    !,
    require_session(Session),
    session_opt(Session, authority, Value).
prlm_session_option(Session, provider, Value) :-
    !,
    require_session(Session),
    session_opt(Session, provider, Value).
prlm_session_option(Session, max_depth, Value) :-
    !,
    require_session(Session),
    session_opt(Session, limit(depth), Value).
prlm_session_option(Session, repairs, Value) :-
    !,
    require_session(Session),
    session_opt(Session, limit(repairs), Value).
prlm_session_option(_, Key, _) :-
    throw(prlm_error(type_error, _{session_option: Key})).

budget_left_all(Session, budgets{steps:S, tool_calls:T, depth:D, repairs:R}) :-
    prlm_budget_left(Session, steps, S),
    prlm_budget_left(Session, tool_calls, T),
    prlm_budget_left(Session, depth, D),
    prlm_budget_left(Session, repairs, R).

% ============================================================
% Event stream
% ============================================================

session_next_seq(Session, Seq) :-
    (   retract(session_seq(Session, N0))
    ->  true
    ;   N0 = 0
    ),
    Seq is N0 + 1,
    assertz(session_seq(Session, Seq)).

%! prlm_event_emit(+Session, +Type, +Data) is det
%! prlm_event_emit(+Session, +Type, +Data, -Event) is det
%
% Append one event to the session's normalized stream. Type must be a
% canonical event type; Data must be a closed term/dict. Event is
% event{seq, time, type, session, data}. Registered subscribers are
% called with the Event after it is stored; subscriber exceptions
% propagate to the caller.
prlm_event_emit(Session, Type, Data) :-
    prlm_event_emit(Session, Type, Data, _).

prlm_event_emit(Session, Type, Data, Event) :-
    require_session(Session),
    (   canonical_event_type(Type)
    ->  true
    ;   throw(prlm_error(type_error, _{event_type: Type}))
    ),
    (   closed_term(Data)
    ->  true
    ;   throw(prlm_error(instantiation_error, _{event_data: Data}))
    ),
    session_next_seq(Session, Seq),
    get_time(Time),
    Event = event{seq: Seq, time: Time, type: Type, session: Session, data: Data},
    assertz(session_event(Session, Seq, Event)),
    forall(session_sub(Session, _, Pred),
           call(Pred, Event)).

%! prlm_events(+Session, +AfterSeq, -Events) is det
%
% All events with Seq > AfterSeq, in ascending seq order.
prlm_events(Session, AfterSeq, Events) :-
    require_session(Session),
    (   integer(AfterSeq)
    ->  true
    ;   throw(prlm_error(type_error, _{after_seq: AfterSeq}))
    ),
    findall(Seq-Event,
            (   session_event(Session, Seq, Event),
                Seq > AfterSeq
            ),
            Pairs0),
    sort(Pairs0, Pairs),
    pairs_values(Pairs, Events).

%! prlm_last_event(+Session, -Event) is semidet
%
% The most recent event of the session.
prlm_last_event(Session, Event) :-
    require_session(Session),
    prlm_events(Session, -1, Events),
    Events \== [],
    last(Events, Event).

%! prlm_events_jsonl(+Session, +Path) is det
%
% Export boundary: write the full event stream as JSON Lines (one
% json_write_dict line per event). This is the only I/O in this module.
prlm_events_jsonl(Session, Path) :-
    require_session(Session),
    prlm_events(Session, -1, Events),
    setup_call_cleanup(
        open(Path, write, Stream),
        write_jsonl(Stream, Events),
        close(Stream)).

write_jsonl(_, []).
write_jsonl(Stream, [Event|Events]) :-
    json_write_dict(Stream, Event, [width(0), nl(false)]),
    write(Stream, '\n'),
    write_jsonl(Stream, Events).

%! prlm_subscribe(+Session, +Name, :Pred/1) is det
%
% Register a trusted host subscriber called with each Event dict as it
% is emitted. Re-registering the same Name replaces the previous one.
prlm_subscribe(Session, Name, Pred) :-
    require_session(Session),
    retractall(session_sub(Session, Name, _)),
    assertz(session_sub(Session, Name, Pred)).

%! prlm_unsubscribe(+Session, +Name) is det
prlm_unsubscribe(Session, Name) :-
    require_session(Session),
    retractall(session_sub(Session, Name, _)).

% ============================================================
% Budgets (shared across recursion)
% ============================================================

%! prlm_budget_left(+Session, +Kind, -Left) is det
%
% Remaining budget for Kind (steps|tool_calls|depth|repairs).
prlm_budget_left(Session, Kind, Left) :-
    require_session(Session),
    require_budget_kind(Kind),
    session_budget(Session, Kind, Left).

%! prlm_budget_check(+Session, +Kind, +Cost) is det
%
% Fail closed: if remaining < Cost, emit a budget event FIRST and then
% throw prlm_error(budget_exceeded, _{kind,cost,remaining}). Checking
% does not charge; callers charge via prlm_budget_charge/3.
prlm_budget_check(Session, Kind, Cost) :-
    require_session(Session),
    require_budget_kind(Kind),
    require_cost(Cost),
    session_budget(Session, Kind, Remaining),
    (   Remaining >= Cost
    ->  true
    ;   prlm_event_emit(Session, budget,
                        _{kind: Kind, cost: Cost, remaining: Remaining}),
        throw(prlm_error(budget_exceeded,
                         _{kind: Kind, cost: Cost, remaining: Remaining}))
    ).

%! prlm_budget_charge(+Session, +Kind, +Cost) is det
%
% Draw Cost from the session-shared remaining counter for Kind.
prlm_budget_charge(Session, Kind, Cost) :-
    require_session(Session),
    require_budget_kind(Kind),
    require_cost(Cost),
    (   retract(session_budget(Session, Kind, Remaining0))
    ->  true
    ;   throw(prlm_error(internal_error, _{budget_missing: Kind}))
    ),
    Remaining is Remaining0 - Cost,
    assertz(session_budget(Session, Kind, Remaining)).

% ============================================================
% Authority
% ============================================================

%! prlm_authority_set(+Session, +Tier) is det
%
% Set the session authority tier. May only narrow (tier_rank(Tier) =<
% tier_rank(Current)); widening throws prlm_error(type_error, _{...}).
% Setting allow_once (re)arms it with one use.
prlm_authority_set(Session, Tier) :-
    require_session(Session),
    require_tier(Tier, authority),
    session_opt(Session, authority, Current),
    tier_rank(Tier, TR),
    tier_rank(Current, CR),
    (   TR =< CR
    ->  set_authority(Session, Tier)
    ;   throw(prlm_error(type_error,
                         _{authority: Tier, current: Current}))
    ).

%! prlm_authority_current(+Session, -Tier) is det
prlm_authority_current(Session, Tier) :-
    require_session(Session),
    session_opt(Session, authority, Tier).

%! prlm_authority_allows(+Session, +Required) is semidet
%
% True when the current tier covers Required. When the current tier is
% allow_once and Required is allow_once, one use is consumed; once the
% use is exhausted this fails (fail closed).
prlm_authority_allows(Session, Required) :-
    require_session(Session),
    require_tier(Required, authority),
    session_opt(Session, authority, Current),
    tier_rank(Required, RR),
    tier_rank(Current, CR),
    RR =< CR,
    (   Current == allow_once
    ->  (   Required == allow_once
        ->  % exact match: consume one use; fail closed when exhausted
            session_opt(Session, allow_once_left, Left),
            Left > 0,
            Left1 is Left - 1,
            retractall(session_opt(Session, allow_once_left, _)),
            assertz(session_opt(Session, allow_once_left, Left1))
        ;   % stricter tier: covered without consumption
            true
        )
    ;   true
    ).

%! prlm_authority_child(+Parent, +Requested, -Child) is det
%
% Derive a child authority tier: the minimum of Parent and Requested by
% canonical tier order. A child can never widen its parent.
prlm_authority_child(Parent, Requested, Child) :-
    require_tier(Parent, authority),
    require_tier(Requested, authority),
    tier_rank(Parent, PR),
    tier_rank(Requested, RR),
    Min is min(PR, RR),
    tier_rank(Child, Min).

% ============================================================
% Cancellation (fail closed)
% ============================================================

%! prlm_cancel_token_new(-Token) is det
%
% A fresh cancellation token (unique atom).
prlm_cancel_token_new(Token) :-
    gensym(prlm_token, Token).

%! prlm_session_token(+Session, -Token) is det
%
% The session's default cancellation token.
prlm_session_token(Session, Token) :-
    require_session(Session),
    session_opt(Session, token, Token).

%! prlm_cancel(+Token) is det
%
% Cancel Token. Idempotent: the cancelled flag is stored once; the
% cancellation event is emitted only on the first cancel and only when
% the token belongs to a live session.
prlm_cancel(Token) :-
    require_token(Token),
    (   cancelled_token(Token)
    ->  true
    ;   assertz(cancelled_token(Token)),
        (   token_session(Token, Session)
        ->  prlm_event_emit(Session, cancellation, _{token: Token})
        ;   true
        )
    ).

%! prlm_cancelled(+Token) is semidet
prlm_cancelled(Token) :-
    cancelled_token(Token).

%! prlm_check_cancelled(+Session) is det
%
% True unless the session's token is cancelled, in which case throws
% prlm_error(cancellation, _{token: Token}).
prlm_check_cancelled(Session) :-
    require_session(Session),
    session_opt(Session, token, Token),
    (   cancelled_token(Token)
    ->  throw(prlm_error(cancellation, _{token: Token}))
    ;   true
    ).

% ============================================================
% Session key-value state store
% ============================================================

%! prlm_session_put(+Session, +Key, +Value) is det
%
% Store Value under Key, replacing any previous value.
prlm_session_put(Session, Key, Value) :-
    require_session(Session),
    retractall(session_kv(Session, Key, _)),
    assertz(session_kv(Session, Key, Value)).

%! prlm_session_put_new(+Session, +Key, +Value) is semidet
%
% Store Value under Key only if Key is fresh; fails silently otherwise.
prlm_session_put_new(Session, Key, Value) :-
    require_session(Session),
    \+ session_kv(Session, Key, _),
    assertz(session_kv(Session, Key, Value)).

%! prlm_session_append(+Session, +Key, +Value) is det
%
% Append Value to the list stored under Key, creating [Value] if Key is
% missing. Existing values must be lists.
prlm_session_append(Session, Key, Value) :-
    require_session(Session),
    (   retract(session_kv(Session, Key, List0))
    ->  (   is_list(List0)
        ->  append(List0, [Value], List)
        ;   throw(prlm_error(type_error, _{session_value: List0}))
        )
    ;   List = [Value]
    ),
    assertz(session_kv(Session, Key, List)).

%! prlm_session_get(+Session, +Key, -Value) is semidet
prlm_session_get(Session, Key, Value) :-
    require_session(Session),
    session_kv(Session, Key, Value).

%! prlm_session_delete(+Session, +Key) is det
prlm_session_delete(Session, Key) :-
    require_session(Session),
    retractall(session_kv(Session, Key, _)).
