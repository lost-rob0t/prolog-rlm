:- module(prlm_usage,
          [ prlm_usage_ready/0,
            prlm_usage_ingest/1,
            prlm_usage_ingest/2,
            prlm_usage_latest/1,
            prlm_usage_report/2,
            prlm_usage_missing/2,
            prlm_usage_forget/1
          ]).

/** <module> prlm_usage — the language inspects its actual usage

Usage introspection over the ONE normalized event stream.

Why this exists
===============

Usage instrumentation is not a separate telemetry pipeline: every fact this
module reports is aggregated from the session's normalized event stream
(prlm_session:prlm_events/3) after the fact. Nothing that happens in a run
needs extra instrumentation to become visible usage data — the event stream
*is* the instrumentation. Aggregation is deterministic, pure, and idempotent:
a fresh UsageId is minted per ingest, the same event snapshot always yields
the same facts, and separate ingests aggregate independently.

Facts (module-local, keyed by UsageId):

  * usage_fact(UsageId, pred,   Key, Count) — model_call events keyed by
    the provider name (data.provider, else data.model, else `unknown`) and
    tool_call events keyed by the tool name (data.tool).
  * usage_fact(UsageId, error,  Key, Count) — failure events keyed by the
    reason atom (data.reason) when present, else by the event type
    (`failure`). Recurring keys (count >= 2) are the "missing capability"
    signal surfaced by prlm_usage_missing/2.
  * usage_fact(UsageId, op,     Key, Count) — observation events keyed by
    data.status.
  * usage_timing(UsageId, Key, TotalMs, Count) — tool_call->observation
    pairs walked in seq order: each observation carrying data.tool closes
    the nearest open tool_call for that tool and contributes
    data.duration_ms (0 when absent).
  * usage_pattern(UsageId, Key, Status, Count) — verification pass/fail
    pairing (simplified): Key is the goal atom recorded for the spec id by
    a preceding specification event (data.goal under data.id/data.spec_id),
    falling back to the spec id itself, else `unkeyed`; Status is pass/fail
    from data.pass or data.status.

Reports are plain closed data (usage_report{}) built by sorting the facts;
no fact is ever derived from anything but the event stream.
*/

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).
:- use_module(library(gensym)).
:- use_module('./prlm_session').

prlm_usage_ready :-
    prlm_session_ready.

% ============================================================
% Aggregate store (module-local dynamic facts keyed by UsageId)
% ============================================================

:- dynamic usage_fact/4.       % usage_fact(UsageId, Kind, Key, Count)
:- dynamic usage_timing/4.     % usage_timing(UsageId, Key, TotalMs, Count)
:- dynamic usage_pattern/4.    % usage_pattern(UsageId, Key, Status, Count)
:- dynamic usage_latest/1.     % usage_latest(UsageId)

%! prlm_usage_ingest(+Session) is det
%
% Convenience form of prlm_usage_ingest/2: aggregate and discard the
% fresh UsageId (queryable afterwards via prlm_usage_latest/1).
prlm_usage_ingest(Session) :-
    prlm_usage_ingest(Session, _).

%! prlm_usage_ingest(+Session, -UsageId) is det
%
% Scan the full normalized event stream of Session (prlm_events/3 from
% seq 0) and aggregate it into fresh module-local facts keyed by a new
% UsageId. Deterministic and pure: the same event snapshot produces the
% same facts. Ingesting twice creates two UsageIds whose aggregates are
% fully independent.
prlm_usage_ingest(Session, UsageId) :-
    gensym(prlm_usage_id, UsageId),
    prlm_events(Session, 0, Events),
    agg_events(Events, UsageId, spec_map{}, pending{}),
    retractall(usage_latest(_)),
    assertz(usage_latest(UsageId)).

%! prlm_usage_latest(-UsageId) is semidet
%
% The UsageId of the most recent successful ingest.
prlm_usage_latest(UsageId) :-
    usage_latest(UsageId).

%! prlm_usage_forget(+UsageId) is det
%
% Drop every aggregate fact for UsageId. Idempotent.
prlm_usage_forget(UsageId) :-
    retractall(usage_fact(UsageId, _, _, _)),
    retractall(usage_timing(UsageId, _, _, _)),
    retractall(usage_pattern(UsageId, _, _, _)),
    retractall(usage_latest(UsageId)).

% ============================================================
% The aggregation walk (one pass over the event stream)
% ============================================================

agg_events([], _, _, _).
agg_events([E|Es], UsageId, SpecMap0, Pending0) :-
    agg_event(E, UsageId, SpecMap0, SpecMap1, Pending0, Pending1),
    agg_events(Es, UsageId, SpecMap1, Pending1).

agg_event(Event, UsageId, SpecMap0, SpecMap, Pending0, Pending) :-
    get_dict(type, Event, Type),
    get_dict(data, Event, Data),
    agg_by_type(Type, Data, UsageId, SpecMap0, SpecMap, Pending0, Pending).

% model_call: provider name (prlm_providers emits data.provider); be
% tolerant of data.model-only payloads; else the atom unknown.
agg_by_type(model_call, Data, UsageId, M, M, P, P) :-
    (   get_dict(provider, Data, P0), atom(P0) -> Key = P0
    ;   get_dict(model, Data, M0), atom(M0) -> Key = M0
    ;   Key = unknown
    ),
    bump(UsageId, pred, Key),
    !.

% tool_call: tool name; opens one pending call for the timing pairing.
agg_by_type(tool_call, Data, UsageId, M, M, P0, P) :-
    get_dict(tool, Data, Tool),
    bump(UsageId, pred, Tool),
    open_pending(P0, Tool, P),
    !.

% failure: reason atom when present, else the event type itself.
agg_by_type(failure, Data, UsageId, M, M, P, P) :-
    (   get_dict(reason, Data, R), atom(R) -> Key = R
    ;   Key = failure
    ),
    bump(UsageId, error, Key),
    !.

% observation: op count by status; closes a pending tool_call pair and
% accumulates its duration (data.duration_ms, else 0).
agg_by_type(observation, Data, UsageId, M, M, P0, P) :-
    (   get_dict(status, Data, Status)
    ->  bump(UsageId, op, Status)
    ;   true
    ),
    (   get_dict(tool, Data, Tool)
    ->  (   get_dict(duration_ms, Data, Ms), integer(Ms) -> true ; Ms = 0 ),
        close_pending(P0, Tool, Ms, UsageId, P)
    ;   P = P0
    ),
    !.

% specification: remember the spec's goal atom per spec id for the
% verification pairing.
agg_by_type(specification, Data, _UsageId, M0, M, P, P) :-
    (   get_dict(id, Data, SpecId) -> true
    ;   get_dict(spec_id, Data, SpecId)
    ),
    !,
    (   get_dict(goal, Data, Goal), atom(Goal)
    ->  put_dict(SpecId, M0, Goal, M)
    ;   M = M0
    ).
agg_by_type(specification, _, _, M, M, P, P).

% verification: pass/fail counted per spec id; Key prefers the goal atom
% recorded by the specification event, else the spec id, else unkeyed.
agg_by_type(verification, Data, UsageId, M, M, P, P) :-
    verification_status(Data, Status),
    !,
    (   (   get_dict(spec_id, Data, SpecId) -> true
        ;   get_dict(id, Data, SpecId) -> true
        ;   get_dict(spec, Data, SpecId) -> true
        )
    ->  (   get_dict(SpecId, M, Goal) -> Key = Goal ; Key = SpecId )
    ;   Key = unkeyed
    ),
    bump_pattern(UsageId, Key, Status).
agg_by_type(verification, _, _, M, M, P, P).

% Any other canonical event type carries no usage aggregate.
agg_by_type(_, _, _, M, M, P, P).

verification_status(Data, pass) :-
    get_dict(pass, Data, true),
    !.
verification_status(Data, fail) :-
    get_dict(pass, Data, false),
    !.
verification_status(Data, Status) :-
    get_dict(status, Data, Status),
    memberchk(Status, [pass, fail]).

% ============================================================
% Counters and pairing state
% ============================================================

bump(UsageId, Kind, Key) :-
    (   retract(usage_fact(UsageId, Kind, Key, C0)) -> C1 is C0 + 1
    ;   C1 = 1
    ),
    assertz(usage_fact(UsageId, Kind, Key, C1)).

bump_pattern(UsageId, Key, Status) :-
    (   retract(usage_pattern(UsageId, Key, Status, C0)) -> C1 is C0 + 1
    ;   C1 = 1
    ),
    assertz(usage_pattern(UsageId, Key, Status, C1)).

bump_timing(UsageId, Key, Ms) :-
    (   retract(usage_timing(UsageId, Key, T0, C0)) -> T1 is T0 + Ms, C1 is C0 + 1
    ;   T1 = Ms, C1 = 1
    ),
    assertz(usage_timing(UsageId, Key, T1, C1)).

% pending{} maps an open tool name to the number of tool_call events not
% yet closed by an observation. An observation for a tool with no open
% call records no timing (it is not a pair).
open_pending(P0, Tool, P) :-
    (   get_dict(Tool, P0, N0) -> N1 is N0 + 1
    ;   N1 = 1
    ),
    put_dict(Tool, P0, N1, P).

close_pending(P0, Tool, Ms, UsageId, P) :-
    (   get_dict(Tool, P0, N0),
        N0 > 0
    ->  (   N0 =:= 1
        ->  del_dict(Tool, P0, _, P1)
        ;   N1 is N0 - 1,
            put_dict(Tool, P0, N1, P1)
        ),
        bump_timing(UsageId, Tool, Ms)
    ;   P1 = P0
    ),
    P = P1.

% ============================================================
% Reports
% ============================================================

%! prlm_usage_report(+UsageId, -Report) is det
%
% Report = usage_report{calls: [Key-Count sorted asc by Key],
%                       errors: [Key-Count sorted asc by Key],
%                       ops: [Key-Count sorted asc by Key],
%                       slow: [Key-TotalMs sorted desc by TotalMs,
%                              then asc by Key],
%                       patterns: [Key-Status-Count sorted]}.
prlm_usage_report(UsageId,
                  usage_report{calls: Calls,
                               errors: Errors,
                               ops: Ops,
                               slow: Slow,
                               patterns: Patterns}) :-
    facts_sorted(UsageId, pred, Calls),
    facts_sorted(UsageId, error, Errors),
    facts_sorted(UsageId, op, Ops),
    timing_sorted(UsageId, Slow),
    findall(Key-Status-Count,
            usage_pattern(UsageId, Key, Status, Count),
            Patterns0),
    sort(Patterns0, Patterns).

facts_sorted(UsageId, Kind, Pairs) :-
    findall(Key-Count, usage_fact(UsageId, Kind, Key, Count), Pairs0),
    sort(Pairs0, Pairs).

% slow: total accumulated ms per paired tool, heaviest first; ties break
% by key ascending (sort over Rank-Key-Ms with Rank = -TotalMs).
timing_sorted(UsageId, Slow) :-
    findall(Key-TotalMs,
            usage_timing(UsageId, Key, TotalMs, _),
            Pairs0),
    map_list_to_pairs(slow_rank, Pairs0, Tagged),
    keysort(Tagged, Sorted),
    pairs_values(Sorted, Slow).

slow_rank(Key-Ms, Rank-(Key-Ms)) :-
    Rank is -Ms.

%! prlm_usage_missing(+UsageId, -Missing) is det
%
% Missing-capability signal: the failure keys that recurred at least
% twice, as sorted atoms. A recurring failure key means the run kept
% hitting the same wall — a capability, credential or tool the language
% needed but did not have.
prlm_usage_missing(UsageId, Missing) :-
    findall(Key,
            (   usage_fact(UsageId, error, Key0, Count),
                Count >= 2,
                key_atom(Key0, Key)
            ),
            Keys0),
    sort(Keys0, Missing).

key_atom(Key, Key) :-
    atom(Key),
    !.
key_atom(Key, A) :-
    term_to_atom(Key, A).
