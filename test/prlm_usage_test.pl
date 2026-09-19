:- use_module(library(plunit)).
:- use_module('../prolog/prlm_session.pl').
:- use_module('../prolog/prlm_tools.pl').
:- use_module('../prolog/prlm_usage.pl').

:- begin_tests(prlm_usage).

% ============================================================
% Helpers
% ============================================================

sess_new(S) :-
    prlm_session_new([authority(allow_session)], S).

sess_destroy(S) :-
    catch(prlm_session_destroy(S), _, true).

emit_all(_, []).
emit_all(S, [Type-Data|Rest]) :-
    prlm_event_emit(S, Type, Data),
    emit_all(S, Rest).

% The scripted sequence covers every aggregated fact class: paired and
% unpaired tool_call/observation timings, provider-keyed and
% model-only model_calls, reason-keyed and reason-less failures, and the
% specification -> verification pass/fail pairing.
script([tool_call-_{tool: search, args: _{}, effects: [read]},
        observation-_{tool: search, status: ok, duration_ms: 120},
        tool_call-_{tool: search, args: _{}, effects: [read]},
        observation-_{tool: search, status: error, duration_ms: 30},
        tool_call-_{tool: write, args: _{}, effects: [write]},
        observation-_{tool: write, status: ok},
        observation-_{tool: ghost, status: ok, duration_ms: 999},
        model_call-_{provider: openrouter, model: m1},
        model_call-_{model: m2},
        failure-_{reason: no_auth},
        failure-_{reason: no_auth},
        failure-_{reason: rate_limit},
        failure-_{tool: x, status: error},
        specification-_{id: spec1, goal: find_root},
        verification-_{spec_id: spec1, pass: true},
        verification-_{spec_id: spec1, pass: false},
        verification-_{pass: false}
       ]).

expected_calls([m2-1, openrouter-1, search-2, write-1]).
expected_errors([failure-1, no_auth-2, rate_limit-1]).
expected_ops([error-1, ok-3]).
expected_slow([search-150, write-0]).
expected_patterns([find_root-fail-1,
                   find_root-pass-1,
                   unkeyed-fail-1]).
expected_missing([no_auth]).

% ============================================================
% Readiness and the scripted aggregation
% ============================================================

test(usage_ready, [true]) :-
    prlm_usage_ready.

test(scripted_ingest_report) :-
    sess_new(S),
    script(Script),
    emit_all(S, Script),
    prlm_usage_ingest(S, U1),
    prlm_usage_report(U1, Report),
    expected_calls(C),     get_dict(calls, Report, C),
    expected_errors(Es),   get_dict(errors, Report, Es),
    expected_ops(Ops),     get_dict(ops, Report, Ops),
    expected_slow(Slow),   get_dict(slow, Report, Slow),
    expected_patterns(Ps), get_dict(patterns, Report, Ps),
    sess_destroy(S).

% The tool_call->observation pairing: the observation for ghost has no
% open tool_call, so it contributes an op count but no timing entry.
test(timing_requires_open_tool_call) :-
    sess_new(S),
    script(Script),
    emit_all(S, Script),
    prlm_usage_ingest(S, U),
    prlm_usage_report(U, Report),
    get_dict(slow, Report, [search-150, write-0]),
    get_dict(ops, Report, [error-1, ok-3]),
    sess_destroy(S).

% ============================================================
% Independent ingests (idempotence: separate UsageIds, same snapshot)
% ============================================================

test(two_ingests_aggregate_independently) :-
    sess_new(S),
    script(Script),
    emit_all(S, Script),
    prlm_usage_ingest(S, U1),
    prlm_usage_ingest(S, U2),
    U1 \== U2,
    prlm_usage_report(U1, R1),
    prlm_usage_report(U2, R2),
    get_dict(calls, R1, C), get_dict(calls, R2, C),
    get_dict(errors, R1, E), get_dict(errors, R2, E),
    get_dict(ops, R1, O), get_dict(ops, R2, O),
    get_dict(slow, R1, Sl), get_dict(slow, R2, Sl),
    get_dict(patterns, R1, P), get_dict(patterns, R2, P),
    prlm_usage_latest(U2),
    % forgetting one ingest leaves the other fully intact
    prlm_usage_forget(U1),
    prlm_usage_report(U2, R3),
    get_dict(calls, R3, C),
    get_dict(errors, R3, E),
    prlm_usage_report(U1, R4),
    get_dict(calls, R4, []),
    get_dict(errors, R4, []),
    get_dict(ops, R4, []),
    get_dict(slow, R4, []),
    get_dict(patterns, R4, []),
    sess_destroy(S).

% ============================================================
% Missing-capability signal
% ============================================================

test(missing_signals_recurring_failures_only) :-
    sess_new(S),
    script(Script),
    emit_all(S, Script),
    prlm_usage_ingest(S, U),
    prlm_usage_missing(U, Missing),
    expected_missing(Missing),
    sess_destroy(S).

test(missing_empty_without_recurrence) :-
    sess_new(S),
    emit_all(S, [failure-_{reason: once_only}]),
    prlm_usage_ingest(S, U),
    prlm_usage_missing(U, []),
    sess_destroy(S).

% ============================================================
% Aggregation over real tool-gate events (prlm_tool_call shapes)
% ============================================================

test(real_tool_call_events_aggregate) :-
    sess_new(S),
    prlm_tools_default(S),
    prlm_tool_call(S, [], echo, _{input: hello}, R1),
    get_dict(status, R1, ok),
    prlm_tool_call(S, [], fail_always, _{}, R2),
    get_dict(status, R2, error),
    prlm_usage_ingest(S, U),
    prlm_usage_report(U, Report),
    get_dict(calls, Report, [echo-1, fail_always-1]),
    get_dict(ops, Report, [error-1, ok-1]),
    get_dict(errors, Report, [failure-1]),
    % both gated calls produced paired timings (echo and fail_always);
    % durations are host-measured, so only presence is asserted.
    get_dict(slow, Report, Slow),
    length(Slow, 2),
    memberchk(echo-_, Slow),
    memberchk(fail_always-_, Slow),
    sess_destroy(S).

test(forget_is_idempotent) :-
    sess_new(S),
    prlm_usage_ingest(S, U),
    prlm_usage_forget(U),
    prlm_usage_forget(U),
    prlm_usage_report(U, usage_report{calls: [], errors: [],
                                      ops: [], slow: [], patterns: []}),
    sess_destroy(S).

:- end_tests(prlm_usage).
