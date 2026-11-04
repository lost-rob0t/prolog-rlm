:- dynamic sub_seen/1.

:- begin_tests(prlm_session).

:- use_module('../prolog/prlm_session').
:- use_module('../prolog/prlm_kernel').
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(yall)).
:- use_module(library(http/json)).
:- use_module(library(readutil)).

% ============================================================
% Helpers
% ============================================================

catch_prlm(Goal, Type, Info) :-
    catch(Goal, prlm_error(Type, Info), true).

as_atom(Value, Atom) :-
    (   atom(Value)
    ->  Atom = Value
    ;   string(Value)
    ->  atom_string(Atom, Value)
    ).

all_tiers([approve_diff, allow_once, allow_session, dangerous]).

tier_index(Tier, Index) :-
    all_tiers(Tiers),
    nth0(Index, Tiers, Tier).

read_lines(Stream, Lines) :-
    read_line_to_string(Stream, Line),
    (   Line == end_of_file
    ->  Lines = []
    ;   Lines = [Line|Rest],
        read_lines(Stream, Rest)
    ).

parse_json_line(Line, Dict) :-
    open_string(Line, Stream),
    json_read_dict(Stream, Dict).

% Note: no yall lambdas with free (shared) variables inside the test
% unit — plunit's unit expansion anonymizes them; use a plain helper.
events_of_type(Session, Type, Selected) :-
    prlm_events(Session, 0, All),
    include(is_event_type(Type), All, Selected).

is_event_type(Type, Event) :-
    get_dict(type, Event, T),
    T == Type.

% ============================================================
% Lifecycle
% ============================================================

test(session_ready_and_lifecycle) :-
    prlm_session_ready,
    prlm_session_new([authority(allow_session), provider(zara)], Session),
    atom(Session),
    prlm_session_engine(Session, Engine),
    atom(Engine),
    prlm_session_token(Session, Token),
    atom(Token),
    Token \== Session,
    prlm_session_option(Session, authority, allow_session),
    prlm_session_option(Session, provider, zara),
    prlm_session_option(Session, max_depth, 500),
    prlm_session_option(Session, repairs, 3),
    prlm_session_option(Session, budgets, Budgets),
    get_dict(steps, Budgets, 1000000),
    get_dict(tool_calls, Budgets, 10000),
    get_dict(depth, Budgets, 500),
    get_dict(repairs, Budgets, 3),
    prlm_session_destroy(Session).

test(session_start_event_is_first) :-
    prlm_session_new([], Session),
    prlm_last_event(Session, Event),
    get_dict(seq, Event, 1),
    get_dict(type, Event, session_start),
    get_dict(session, Event, Session),
    get_dict(data, Event, Data),
    get_dict(authority, Data, approve_diff),
    get_dict(provider, Data, prolog),
    prlm_session_destroy(Session).

test(session_engine_runs_kernel_queries) :-
    prlm_session_new([], Session),
    prlm_session_engine(Session, Engine),
    prlm_query_solutions(Engine, "X = 1.", 10, Rows),
    Rows == [row{'X':1}],
    prlm_session_destroy(Session).

test(unknown_option_throws) :-
    catch_prlm(prlm_session_new([bogus(1)], _), type_error, Info),
    get_dict(session_option, Info, bogus(1)).

test(destroy_cleans_state) :-
    prlm_session_new([], Session),
    prlm_session_put(Session, k, v),
    prlm_session_destroy(Session),
    catch_prlm(prlm_session_option(Session, authority, _), existence_error, Info1),
    get_dict(session, Info1, Session),
    catch_prlm(prlm_event_emit(Session, plan, _{}), existence_error, _),
    catch_prlm(prlm_session_get(Session, k, _), existence_error, _),
    prlm_session_destroy(Session).      % idempotent

% ============================================================
% Event stream
% ============================================================

test(event_seq_ordering_and_after_seq) :-
    prlm_session_new([], Session),
    prlm_event_emit(Session, plan, _{step: 1}),
    prlm_event_emit(Session, plan, _{step: 2}),
    prlm_event_emit(Session, observation, _{text: hello}),
    prlm_events(Session, 0, All),
    maplist([E, Seq]>>(get_dict(seq, E, Seq)), All, Seqs),
    Seqs == [1, 2, 3, 4],
    prlm_events(Session, 2, After2),
    maplist([E, T]>>(get_dict(type, E, T)), After2, Types),
    Types == [plan, observation],
    prlm_events(Session, 4, []),
    prlm_last_event(Session, Last),
    get_dict(seq, Last, 4),
    get_dict(type, Last, observation),
    prlm_session_destroy(Session).

test(unknown_event_type_throws) :-
    prlm_session_new([], Session),
    catch_prlm(prlm_event_emit(Session, totally_bogus, _{}), type_error, Info),
    get_dict(event_type, Info, totally_bogus),
    prlm_event_type(session_start),
    prlm_event_type(context_compiled),
    \+ prlm_event_type(totally_bogus),
    prlm_session_destroy(Session).

test(events_jsonl_roundtrip) :-
    prlm_session_new([], Session),
    prlm_event_emit(Session, observation, _{text: "hello", n: 1}),
    prlm_event_emit(Session, tool_call, _{name: grep}),
    Path = '/tmp/opencode/prlm_test_events.jsonl',
    prlm_events_jsonl(Session, Path),
    setup_call_cleanup(
        open(Path, read, Stream),
        read_lines(Stream, Lines),
        close(Stream)),
    length(Lines, 3),
    maplist(parse_json_line, Lines, Dicts),
    [D1, D2, D3] = Dicts,
    get_dict(seq, D1, 1),
    get_dict(type, D1, T1),
    as_atom(T1, session_start),
    get_dict('data', D1, Data1),
    is_dict(Data1),
    get_dict(authority, Data1, A1),
    as_atom(A1, approve_diff),
    get_dict(seq, D2, 2),
    get_dict(type, D2, T2),
    as_atom(T2, observation),
    get_dict(n, D2.'data', 1),
    get_dict(seq, D3, 3),
    get_dict(type, D3, T3),
    as_atom(T3, tool_call),
    get_dict(name, D3.'data', N3),
    as_atom(N3, grep),
    get_dict(session, D3, S3),
    as_atom(S3, Session),
    prlm_session_destroy(Session).

test(subscriber_receives_events_and_unsubscribes) :-
    retractall(sub_seen(_)),
    prlm_session_new([], Session),
    prlm_subscribe(Session, probe,
                   [E]>>(get_dict(seq, E, Seq), assertz(sub_seen(Seq)))),
    prlm_event_emit(Session, plan, _{step: 1}),
    sub_seen(2),
    prlm_unsubscribe(Session, probe),
    prlm_event_emit(Session, plan, _{step: 2}),
    findall(N, sub_seen(N), Seen),
    Seen == [2],
    prlm_session_destroy(Session).

% ============================================================
% Budgets
% ============================================================

test(budget_exhaustion_emits_budget_event_and_throws) :-
    prlm_session_new([budgets(_{steps: 3})], Session),
    prlm_budget_left(Session, steps, 3),
    prlm_budget_charge(Session, steps, 2),
    prlm_budget_left(Session, steps, 1),
    prlm_budget_check(Session, steps, 1),
    prlm_budget_left(Session, steps, 1),    % check does not charge
    catch_prlm(prlm_budget_check(Session, steps, 2), budget_exceeded, Info),
    get_dict(kind, Info, steps),
    get_dict(cost, Info, 2),
    get_dict(remaining, Info, 1),
    prlm_budget_left(Session, steps, 1),
    prlm_last_event(Session, Event),
    get_dict(type, Event, budget),
    get_dict(data, Event, Data),
    get_dict(kind, Data, steps),
    get_dict(remaining, Data, 1),
    catch_prlm(prlm_budget_check(Session, steps, 999), budget_exceeded, _),
    prlm_session_option(Session, budgets, B),
    get_dict(steps, B, 1),
    prlm_session_destroy(Session).

test(budget_unknown_kind_throws) :-
    prlm_session_new([], Session),
    catch_prlm(prlm_budget_check(Session, banana, 1), type_error, Info),
    get_dict(budget_kind, Info, banana),
    catch_prlm(prlm_budget_charge(Session, banana, 1), type_error, _),
    catch_prlm(prlm_budget_left(Session, banana, _), type_error, _),
    prlm_session_destroy(Session).

test(shared_budget_across_nested_calls) :-
    prlm_session_new([budgets(_{steps: 5})], Session),
    prlm_budget_charge(Session, steps, 2),
    catch(
        (   % simulated nested scope: same session, same counters
            prlm_budget_charge(Session, steps, 2),
            prlm_budget_left(Session, steps, 1),
            prlm_budget_check(Session, steps, 2)
        ),
        prlm_error(budget_exceeded, Info),
        true),
    get_dict(remaining, Info, 1),
    get_dict(kind, Info, steps),
    prlm_budget_left(Session, steps, 1),
    events_of_type(Session, budget, Budgets),
    length(Budgets, 1),
    prlm_session_destroy(Session).

% ============================================================
% Authority
% ============================================================

test(authority_set_may_only_narrow) :-
    prlm_session_new([authority(allow_session)], Session),
    prlm_authority_current(Session, allow_session),
    catch_prlm(prlm_authority_set(Session, dangerous), type_error, Info),
    get_dict(authority, Info, dangerous),
    prlm_authority_current(Session, allow_session),
    prlm_authority_set(Session, allow_once),
    prlm_authority_current(Session, allow_once),
    prlm_authority_set(Session, allow_once),        % equal: allowed
    prlm_authority_current(Session, allow_once),
    catch_prlm(prlm_authority_set(Session, allow_session), type_error, _),
    prlm_authority_current(Session, allow_once),
    prlm_session_destroy(Session).

test(authority_default_narrows_nothing) :-
    prlm_session_new([], Session),
    prlm_authority_current(Session, approve_diff),
    catch_prlm(prlm_authority_set(Session, allow_once), type_error, _),
    prlm_authority_current(Session, approve_diff),
    prlm_session_destroy(Session).

test(authority_narrow_from_dangerous) :-
    prlm_session_new([authority(dangerous)], Session),
    prlm_authority_current(Session, dangerous),
    prlm_authority_set(Session, allow_session),
    prlm_authority_current(Session, allow_session),
    prlm_session_destroy(Session).

test(authority_child_never_widens_4x4_property) :-
    all_tiers(Tiers),
    forall((   member(Parent, Tiers),
               member(Requested, Tiers)
           ),
           (   prlm_authority_child(Parent, Requested, Child),
               tier_index(Parent, PI),
               tier_index(Requested, RI),
               tier_index(Child, CI),
               CI =< PI,
               CI =:= min(PI, RI)
           )).

test(authority_child_identity_cases) :-
    prlm_authority_child(dangerous, allow_once, allow_once),
    prlm_authority_child(approve_diff, dangerous, approve_diff),
    prlm_authority_child(allow_session, allow_session, allow_session),
    catch_prlm(prlm_authority_child(approve_diff, banana, _), type_error, Info),
    get_dict(authority, Info, banana),
    catch_prlm(prlm_authority_child(approve_diff, _, _), type_error, _),
    catch_prlm(prlm_authority_child(_, approve_diff, _), type_error, _).

test(allow_once_consumed_once_then_fails) :-
    prlm_session_new([authority(allow_once)], Session),
    prlm_authority_allows(Session, approve_diff),   % no consumption
    prlm_authority_allows(Session, allow_once),     % consumes the one use
    \+ prlm_authority_allows(Session, allow_once),
    \+ prlm_authority_allows(Session, allow_session),
    \+ prlm_authority_allows(Session, dangerous),
    prlm_authority_set(Session, allow_once),        % re-arm (equal rank)
    prlm_authority_allows(Session, allow_once),
    \+ prlm_authority_allows(Session, allow_once),
    prlm_session_destroy(Session).

test(allow_session_allows_without_consumption) :-
    prlm_session_new([authority(allow_session)], Session),
    forall(member(Required, [approve_diff, allow_once, allow_session]),
           prlm_authority_allows(Session, Required)),
    \+ prlm_authority_allows(Session, dangerous),
    forall(member(Required, [approve_diff, allow_once, allow_session]),
           prlm_authority_allows(Session, Required)),
    prlm_session_destroy(Session).

% ============================================================
% Cancellation
% ============================================================

test(cancellation_fails_closed_and_is_idempotent) :-
    prlm_session_new([], Session),
    prlm_session_token(Session, Token),
    \+ prlm_cancelled(Token),
    prlm_check_cancelled(Session),
    prlm_cancel(Token),
    prlm_cancelled(Token),
    catch_prlm(prlm_check_cancelled(Session), cancellation, Info),
    is_dict(Info),
    get_dict(token, Info, Token),
    prlm_cancel(Token),                             % idempotent
    prlm_cancelled(Token),
    events_of_type(Session, cancellation, Cancels),
    length(Cancels, 1),
    prlm_session_destroy(Session).

test(standalone_tokens_cancel_without_events) :-
    prlm_cancel_token_new(T1),
    prlm_cancel_token_new(T2),
    T1 \== T2,
    \+ prlm_cancelled(T1),
    prlm_cancel(T1),
    prlm_cancel(T1),
    prlm_cancelled(T1),
    \+ prlm_cancelled(T2).

% ============================================================
% Key-value state store
% ============================================================

test(kvs_put_get_append_delete) :-
    prlm_session_new([], Session),
    prlm_session_put(Session, k, v1),
    prlm_session_get(Session, k, v1),
    prlm_session_put(Session, k, v2),               % replaces
    prlm_session_get(Session, k, v2),
    \+ prlm_session_put_new(Session, k, v3),        % fails silently
    prlm_session_get(Session, k, v2),
    prlm_session_put_new(Session, fresh, [a]),      % ok on fresh key
    prlm_session_append(Session, fresh, b),
    prlm_session_get(Session, fresh, [a, b]),
    prlm_session_append(Session, grown, x),         % creates if missing
    prlm_session_get(Session, grown, [x]),
    prlm_session_delete(Session, k),
    \+ prlm_session_get(Session, k, _),
    prlm_session_destroy(Session).

:- end_tests(prlm_session).
