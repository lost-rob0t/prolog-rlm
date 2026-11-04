:- module(prlm_rsi,
          [ prlm_rsi_ready/0,
            prlm_rsi_observe/2,
            prlm_rsi_propose/3,
            prlm_rsi_propose_break/2,
            prlm_rsi_run/3,
            prlm_rsi_rollback_check/3,
            prlm_rsi_facts/2
          ]).

/** <module> prlm_rsi — bounded recursive self-improvement

Why this exists
===============

Recursive self-improvement is only safe when it is BOUNDED and OBSERVABLE.
This module implements the full loop as an experiment protocol:

    OBSERVE -> PROPOSE -> IMPLEMENT -> TEST -> BENCHMARK -> VERIFY
    -> ACCEPT / REJECT

Experiments are facts (queryable via prlm_rsi_facts/2). The accepted runtime
is never mutated in place: candidates are implemented in an ISOLATED
workspace, tested and benchmarked there, and only a verified candidate is
PROMOTED into the session engine's tuning module. Rejected experiments leave
the runtime identical to its pre-run state (the rollback guarantee, checked
by prlm_rsi_rollback_check/3) and remain in the KB as negative knowledge.
Everything here is deterministic: no model calls, no randomness.

Git-worktree mapping (isolation contract)
=========================================

The deterministic core models the isolated worktree as a DIRECTORY:
`<TmpRoot>/<ExpId>/`. Production maps that directory to `git worktree add`
through a process/shell tool at the tool boundary — the boundary where the
host plugs in real git. Out of scope here, by design: no `git` binary is
required and no process is spawned. The isolation RULE is what matters: a
candidate is written to its own copy of the runtime fact file
(`<Dir>/rsi_tuning.pl`), never to the accepted runtime.

Demonstration domain
====================

One runtime TUNING FACT stored in the session engine module `rsi_tuning`:

    batch_size(N).

prlm_rsi_propose/3 is the deterministic proposal: bump the current value by
+16. prlm_rsi_propose_break/2 is a second deterministic proposal (-2000
regression) that exercises the two rejection paths:

  * default tuning (16) -> candidate batch_size(-1984) fails the TEST probe
    (batch_size must be an integer > 0);
  * pre-set high tuning (e.g. batch_size(10000)) -> candidate batch_size(8000)
    passes the probe but FAILS the benchmark (metric_not_improved).

Metrics (documented deterministic pseudo-metric)
================================================

The BENCHMARK tool runs a fixed workload of N=200 machine iterations (a
recursive loop executed by a kernel engine; the run charges engine steps)
and reports, for the baseline value Old and candidate value New:

  * baseline throughput B = Old (the current accepted tuning value)
  * candidate throughput C = 1000 / (abs(New - Old) + 1) + New

VERIFY accepts iff the candidate passes the correctness probe AND C > B.
Under this formula any positive bump improves C, and regressions of
|delta| >= 32 fail the metric. (The task sketch expected 10000 -> 10016 to
LOWER throughput; arithmetically it does not — C = 1000/17 + 10016 > 10000 —
so the metric-rejection path is exercised by the -2000 regression proposal
at the high preset, and the probe-rejection path by the same proposal at
the default tuning.)

Tools (every mutating operation goes through prlm_tools)
========================================================

Tools are registered lazily once per session and executed via
prlm_tool_call/5 with caller caps [rsi]; the session must hold authority
>= allow_session to run (an approve_diff session cannot run experiments —
the gate throws prlm_error(forbidden,_)):

  * rsi_patch     — authority allow_session, effects [write]: writes the
    isolated candidate fact file <Dir>/rsi_tuning.pl.
  * rsi_test      — authority allow_session, effects [read]: loads the
    candidate into a FRESH kernel engine (prlm_engine_new + prlm_consult)
    and runs the correctness probe.
  * rsi_benchmark — authority allow_session, effects [read]: runs the fixed
    N=200 workload on a scratch engine and returns the metric pair.

The workspace root is REQUIRED: prlm_rsi_run/3 reads the session KVS key
`rsi_workspace_root` and throws prlm_error(existence_error,
_{workspace:...}) without it — the module never writes outside that root.

Events
======

`experiment` is not a canonical session event type, so lifecycle events are
emitted on canonical types: observation (observe/proposed), verification
(the verify verdict) and completion (accept) or failure (reject). Every tool
call additionally produces the standard tool_call/observation events.

Fact shapes (module-local, keyed by Session; exported via prlm_rsi_facts/2):

  * experiment(ExpId, Desc)
  * experiment_metric(ExpId, Phase, Metric, Value)  % Phase: pre|baseline|candidate
  * experiment_change(ExpId, Change)
  * experiment_result(ExpId, accepted|rejected)
  * experiment_failure(ExpId, Reason)
*/

:- use_module(library(gensym)).
:- use_module('./prlm_kernel').
:- use_module('./prlm_session').
:- use_module('./prlm_tools').

prlm_rsi_ready :-
    prlm_kernel_ready,
    prlm_session_ready,
    prlm_tools_ready.

% Module-local experiment KB, keyed by the session handle.
:- dynamic rsi_experiment/3.    % rsi_experiment(Session, ExpId, Desc)
:- dynamic rsi_metric/5.        % rsi_metric(Session, ExpId, Phase, Metric, Value)
:- dynamic rsi_change/3.        % rsi_change(Session, ExpId, Change)
:- dynamic rsi_result/3.        % rsi_result(Session, ExpId, accepted|rejected)
:- dynamic rsi_failure/3.       % rsi_failure(Session, ExpId, Reason)
:- dynamic rsi_fact/2.          % rsi_fact(Session, Fact) — observed knowledge
:- dynamic rsi_tools_done/1.    % rsi_tools_done(Session) — lazy registration

% ============================================================
% Helpers
% ============================================================

require_session(Session) :-
    prlm_session_engine(Session, _).

% ============================================================
% Tuning fact access (the accepted runtime)
% ============================================================

default_tuning(16).

% ensure_tuning(+Session, -Old): read the accepted tuning value; seed the
% demonstration fact batch_size(16) when the runtime has none.
ensure_tuning(Session, Old) :-
    prlm_session_engine(Session, Engine),
    (   prlm_current_predicate(Engine, rsi_tuning, batch_size/1)
    ->  read_tuning(Engine, Old)
    ;   default_tuning(Seed),
        prlm_assertz(Engine, rsi_tuning, batch_size(Seed)),
        Old = Seed
    ).

% read_tuning(+Engine, -Value): the single sanctioned read path. The value
% comes from the result dict of prlm_call_first/5; NOTE the goal variable
% and the outspec variable must be the SAME host variable — the kernel
% bridge converts it once in the goal and recognizes it in the outspec.
read_tuning(Engine, Value) :-
    (   catch(prlm_call_first(Engine, rsi_tuning, batch_size(V), [value-V], R),
              prlm_error(_, _), fail)
    ->  get_dict(value, R, Value)
    ;   throw(prlm_error(existence_error, _{tuning: batch_size/1}))
    ).

% drain_tuning(+Engine): remove the current tuning fact (promotion path only).
drain_tuning(Engine) :-
    (   prlm_retract_first(Engine, rsi_tuning, batch_size, 1)
    ->  drain_tuning(Engine)
    ;   true
    ).

% ============================================================
% OBSERVE
% ============================================================

%! prlm_rsi_observe(+Session, -Obs) is det
%
% Obs = observation{engine_steps: N, knowledge_count: C, timestamp: T}
% where engine_steps is the session engine's charged machine-step count and
% knowledge_count the number of rsi knowledge facts recorded so far. Each
% observation itself becomes a knowledge fact
% rsi_fact(Session, observed(T, N, C)) — usage becomes queryable knowledge —
% and emits an observation event.
prlm_rsi_observe(Session, Obs) :-
    require_session(Session),
    prlm_session_engine(Session, Engine),
    (   prlm_engine_stats(Engine, steps(N)) -> true ; N = 0 ),
    findall(F, rsi_fact(Session, F), Facts),
    length(Facts, Count),
    get_time(TS),
    Obs = observation{engine_steps: N, knowledge_count: Count, timestamp: TS},
    assertz(rsi_fact(Session, observed(TS, N, Count))),
    prlm_event_emit(Session, observation,
                    _{kind: rsi, phase: observe,
                      engine_steps: N, knowledge_count: Count}).

% ============================================================
% PROPOSE
% ============================================================

%! prlm_rsi_propose(+Session, +Obs, -Change) is det
%
% Deterministic proposal from the observation (no model): bump the accepted
% tuning fact by +16.
%
%   Change = change{id: ExpId, target: benchmark_target, kind: tuning,
%                   patch: patch(batch_size, Old, Old + 16)}
%
% ExpId is a fresh atom. Records experiment/2 + experiment_change/2, marks
% the proposal as knowledge and emits an observation event. Obs must be the
% observation dict from prlm_rsi_observe/2 (interface symmetry: the pipeline
% is observe -> propose; the deterministic proposal depends only on the
% current tuning fact).
prlm_rsi_propose(Session, Obs, Change) :-
    require_session(Session),
    (   is_dict(Obs, observation)
    ->  true
    ;   throw(prlm_error(type_error, _{observation: Obs}))
    ),
    ensure_tuning(Session, Old),
    New is Old + 16,
    gensym(rsi_exp, ExpId),
    record_change(Session, ExpId,
                  'deterministic tuning: batch_size += 16',
                  Old, New, proposed, Change).

%! prlm_rsi_propose_break(+Session, -Change) is det
%
% The second deterministic proposal (rejection-path driver): regress the
% tuning fact by -2000. At the default tuning the candidate value is
% negative and fails the correctness probe; at a high pre-set tuning the
% candidate passes the probe but loses the benchmark.
prlm_rsi_propose_break(Session, Change) :-
    require_session(Session),
    ensure_tuning(Session, Old),
    New is Old - 2000,
    gensym(rsi_exp, ExpId),
    record_change(Session, ExpId,
                  'deterministic regression probe: batch_size -= 2000',
                  Old, New, proposed_break, Change).

record_change(Session, ExpId, Desc, Old, New, Phase, Change) :-
    Change = change{id: ExpId,
                    target: benchmark_target,
                    kind: tuning,
                    patch: patch(batch_size, Old, New)},
    assertz(rsi_experiment(Session, ExpId, Desc)),
    assertz(rsi_change(Session, ExpId, Change)),
    assertz(rsi_fact(Session, proposed(ExpId, Old, New))),
    prlm_event_emit(Session, observation,
                    _{kind: rsi, phase: Phase, experiment: ExpId,
                      old: Old, new: New}).

% ============================================================
% IMPLEMENT -> TEST -> BENCHMARK -> VERIFY -> ACCEPT/REJECT
% ============================================================

%! prlm_rsi_run(+Session, +Change, -Verdict) is det
%
% Run the full bounded loop for Change (from prlm_rsi_propose/3 or
% prlm_rsi_propose_break/2):
%
%   1. IMPLEMENT via tool rsi_patch: the tuned fact is written to the
%      ISOLATED workspace <rsi_workspace_root>/<ExpId>/rsi_tuning.pl. The
%      accepted runtime is never touched in this phase.
%   2. TEST via tool rsi_test: fresh engine, prlm_consult the candidate,
%      probe = batch_size must be an integer > 0.
%   3. BENCHMARK via tool rsi_benchmark: fixed N=200 machine workload;
%      metrics per the documented formula. Both throughput values are
%      recorded as experiment_metric facts (the pre-run tuning value is
%      recorded before any phase as experiment_metric(ExpId, pre, tuning, Old)).
%   4. VERIFY: probe ok AND candidate throughput > baseline throughput.
%   5. ACCEPT: promote — drain the old batch_size/1 from the session engine
%      module rsi_tuning and prlm_assertz the candidate value (the ONLY
%      promotion path). REJECT: record experiment_result(rejected) +
%      experiment_failure(Reason); the runtime was never touched, which IS
%      the rollback.
%
% Verdict = verdict{status, reason, metrics: _{baseline, candidate},
%                   workspace: Dir}.
%
% Tool handler errors (result{status:error}) throw
% prlm_error(internal_error,...) — fail closed. Gate errors (authority /
% capability / budget / cancelled) propagate from prlm_tool_call unchanged.
% One run per experiment: a second run with the same Change id throws.
prlm_rsi_run(Session, Change, Verdict) :-
    require_session(Session),
    (   is_dict(Change, change)
    ->  true
    ;   throw(prlm_error(type_error, _{change: Change}))
    ),
    get_dict(id, Change, ExpId),
    (   get_dict(patch, Change, Patch),
        compound(Patch),
        Patch = patch(FactName, Old, New),
        FactName == batch_size          % demonstration domain guard
    ->  true
    ;   throw(prlm_error(type_error, _{patch: Change}))
    ),
    workspace_root(Session, TmpRoot),
    (   rsi_result(Session, ExpId, _)
    ->  throw(prlm_error(type_error, _{experiment_finished: ExpId}))
    ;   true
    ),
    ensure_rsi_tools(Session),
    directory_file_path(TmpRoot, ExpId, Dir),
    assertz(rsi_metric(Session, ExpId, pre, tuning, Old)),
    prlm_tool_call(Session, [rsi], rsi_patch,
                   _{directory: Dir, value: New}, PatchResult),
    tool_value(rsi_patch, PatchResult, CandidateFile),
    prlm_tool_call(Session, [rsi], rsi_test,
                   _{file: CandidateFile}, TestResult),
    tool_value(rsi_test, TestResult, Probe),
    prlm_tool_call(Session, [rsi], rsi_benchmark,
                   _{baseline: Old, candidate: New}, BenchResult),
    tool_value(rsi_benchmark, BenchResult, Metrics),
    get_dict(baseline, Metrics, B),
    get_dict(candidate, Metrics, C),
    assertz(rsi_metric(Session, ExpId, baseline, throughput, B)),
    assertz(rsi_metric(Session, ExpId, candidate, throughput, C)),
    verify_and_commit(Session, ExpId, New, Probe, B, C, Dir, Verdict).

%! workspace_root(+Session, -Root) is det
%
% GUARD: the session KVS key rsi_workspace_root is REQUIRED. Without it no
% byte is written anywhere.
workspace_root(Session, Root) :-
    (   prlm_session_get(Session, rsi_workspace_root, Root)
    ->  true
    ;   throw(prlm_error(existence_error, _{workspace: rsi_workspace_root}))
    ).

tool_value(Tool, Result, Value) :-
    (   get_dict(status, Result, ok),
        get_dict(value, Result, Value)
    ->  true
    ;   get_dict(value, Result, Err),
        throw(prlm_error(internal_error, _{tool: Tool, result: Err}))
    ).

verify_and_commit(Session, ExpId, New, Probe, B, C, Dir, Verdict) :-
    prlm_session_engine(Session, Engine),
    (   get_dict(status, Probe, ok),
        C > B
    ->  accept_change(Session, Engine, ExpId, New, B, C, Dir, Verdict)
    ;   rejection_reason(Probe, Reason),
        reject_change(Session, ExpId, Reason, B, C, Dir, Verdict)
    ).

rejection_reason(Probe, metric_not_improved) :-
    get_dict(status, Probe, ok),
    !.
rejection_reason(Probe, probe_failed(Why)) :-
    (   get_dict(reason, Probe, Why0)
    ->  Why = Why0
    ;   Why = unknown
    ).

accept_change(Session, Engine, ExpId, New, B, C, Dir, Verdict) :-
    drain_tuning(Engine),
    prlm_assertz(Engine, rsi_tuning, batch_size(New)),
    assertz(rsi_result(Session, ExpId, accepted)),
    prlm_event_emit(Session, verification,
                    _{experiment: ExpId, status: passed}),
    prlm_event_emit(Session, completion,
                    _{experiment: ExpId, status: accepted}),
    Verdict = verdict{status: accepted,
                      reason: probe_ok_metric_improved,
                      metrics: _{baseline: B, candidate: C},
                      workspace: Dir}.

reject_change(Session, ExpId, Reason, B, C, Dir, Verdict) :-
    assertz(rsi_result(Session, ExpId, rejected)),
    assertz(rsi_failure(Session, ExpId, Reason)),
    reason_atom(Reason, RAtom),
    prlm_event_emit(Session, verification,
                    _{experiment: ExpId, status: failed, reason: RAtom}),
    prlm_event_emit(Session, failure,
                    _{experiment: ExpId, reason: RAtom}),
    Verdict = verdict{status: rejected,
                      reason: Reason,
                      metrics: _{baseline: B, candidate: C},
                      workspace: Dir}.

reason_atom(Reason, RAtom) :-
    (   atom(Reason)
    ->  RAtom = Reason
    ;   term_to_atom(Reason, RAtom)
    ).

% ============================================================
% Rollback guarantee
% ============================================================

%! prlm_rsi_rollback_check(+Session, +ExpId, -Ok) is det
%
% Ok = true iff ExpId is a REJECTED experiment and the session engine's
% tuning fact equals the pre-run value recorded as
% experiment_metric(ExpId, pre, tuning, V). For accepted experiments (or
% unknown ids, or a missing tuning fact) Ok = false: a rejection must never
% have moved the runtime, so equality of the pre-run snapshot with the live
% value is the observable rollback guarantee.
prlm_rsi_rollback_check(Session, ExpId, Ok) :-
    require_session(Session),
    prlm_session_engine(Session, Engine),
    (   rsi_result(Session, ExpId, rejected),
        rsi_metric(Session, ExpId, pre, tuning, Pre),
        catch(read_tuning(Engine, Current), _, fail),
        Current == Pre
    ->  Ok = true
    ;   Ok = false
    ).

% ============================================================
% Experiment KB as queryable knowledge
% ============================================================

%! prlm_rsi_facts(+Session, -Facts) is det
%
% All experiment facts for Session as dicts, in insertion order grouped by
% kind (experiments, changes, metrics, results, failures):
%
%   experiment{id, desc}
%   experiment_change{id, change}
%   experiment_metric{id, phase, metric, value}
%   experiment_result{id, status}
%   experiment_failure{id, reason}
prlm_rsi_facts(Session, Facts) :-
    require_session(Session),
    findall(F,
            (   rsi_experiment(Session, ExpId, Desc),
                F = experiment{id: ExpId, desc: Desc}
            ;   rsi_change(Session, ExpId, Change),
                F = experiment_change{id: ExpId, change: Change}
            ;   rsi_metric(Session, ExpId, Phase, Metric, Value),
                F = experiment_metric{id: ExpId, phase: Phase,
                                      metric: Metric, value: Value}
            ;   rsi_result(Session, ExpId, Status),
                F = experiment_result{id: ExpId, status: Status}
            ;   rsi_failure(Session, ExpId, Reason),
                F = experiment_failure{id: ExpId, reason: Reason}
            ),
            Facts).

% ============================================================
% Lazy tool registration (once per session)
% ============================================================

ensure_rsi_tools(Session) :-
    (   rsi_tools_done(Session)
    ->  true
    ;   register_rsi_tools(Session),
        assertz(rsi_tools_done(Session))
    ).

register_rsi_tools(Session) :-
    prlm_tool_register(Session,
                       tool{name: rsi_patch,
                            description: 'Write the isolated candidate tuning fact file rsi_tuning.pl into the experiment workspace directory.',
                            args_schema: [arg(directory, atom), arg(value, integer)],
                            capability: [rsi],
                            authority: allow_session,
                            effects: [write],
                            result_schema: atom,
                            handler: host(prlm_rsi:rsi_patch_handler(Session))},
                       _),
    prlm_tool_register(Session,
                       tool{name: rsi_test,
                            description: 'Load a candidate rsi_tuning.pl into a fresh engine and probe that batch_size is an integer > 0.',
                            args_schema: [arg(file, atom)],
                            capability: [rsi],
                            authority: allow_session,
                            effects: [read],
                            result_schema: term,
                            handler: host(prlm_rsi:rsi_test_handler(Session))},
                       _),
    prlm_tool_register(Session,
                       tool{name: rsi_benchmark,
                            description: 'Run the fixed 200-iteration machine workload and report the documented baseline/candidate throughput pseudo-metric.',
                            args_schema: [arg(baseline, integer), arg(candidate, integer)],
                            capability: [rsi],
                            authority: allow_session,
                            effects: [read],
                            result_schema: dict,
                            handler: host(prlm_rsi:rsi_benchmark_handler(Session))},
                       _).

% ============================================================
% Tool handlers (host side; executed only through the gated
% prlm_tool_call path — never called directly by the loop)
% ============================================================

% rsi_patch: create <Dir> and write the isolated candidate copy of the
% runtime fact file. Never touches the accepted runtime.
rsi_patch_handler(_Session, Args, Path) :-
    get_dict(directory, Args, Dir),
    get_dict(value, Args, New),
    make_directory_path(Dir),
    directory_file_path(Dir, 'rsi_tuning.pl', Path),
    format(atom(Content),
           ":- module(rsi_tuning, [batch_size/1]).~nbatch_size(~w).~n",
           [New]),
    setup_call_cleanup(
        open(Path, write, Stream),
        write(Stream, Content),
        close(Stream)).

% rsi_test: FRESH engine, consult the candidate file, correctness probe.
rsi_test_handler(_Session, Args, Probe) :-
    get_dict(file, Args, File),
    setup_call_cleanup(
        prlm_engine_new([], Engine),
        probe_engine(Engine, File, Probe),
        prlm_engine_destroy(Engine)).

probe_engine(Engine, File, Probe) :-
    catch(probe_engine_(Engine, File, Probe),
          prlm_error(Type, _),
          Probe = probe{status: failed, reason: Type}).

probe_engine_(Engine, File, Probe) :-
    (   prlm_consult(Engine, File)
    ->  (   prlm_call_first(Engine, rsi_tuning, batch_size(V), [value-V], R),
            get_dict(value, R, Value),
            integer(Value),
            Value > 0
        ->  Probe = probe{status: ok, value: Value}
        ;   Probe = probe{status: failed, reason: not_positive_integer}
        )
    ;   Probe = probe{status: failed, reason: consult_failed}
    ).

% rsi_benchmark: run the fixed N=200 machine workload on a scratch engine
% (both phases execute the identical deterministic loop; the recorded metric
% is the documented closed-form pseudo-metric).
rsi_benchmark_handler(_Session, Args, Metrics) :-
    get_dict(baseline, Args, Old),
    get_dict(candidate, Args, New),
    run_workload(Steps),
    Baseline is Old,
    Candidate is 1000 / (abs(New - Old) + 1) + New,
    Metrics = metrics{baseline: Baseline,
                      candidate: Candidate,
                      iterations: 200,
                      workload_steps: Steps}.

run_workload(Steps) :-
    setup_call_cleanup(
        prlm_engine_new([], Engine),
        (   prlm_consult_source(Engine, rsi_workload,
                                ":- module(rsi_workload, [loop/1]).\nloop(0).\nloop(N) :- N > 0, M is N - 1, loop(M).\n"),
            prlm_query_first(Engine, rsi_workload, loop(200), _),
            prlm_engine_stats(Engine, steps(Steps))
        ),
        prlm_engine_destroy(Engine)).
