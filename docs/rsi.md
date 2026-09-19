# RSI: Bounded Recursive Self-Improvement in Prolog-RLM

`prolog/prlm_rsi.pl` is the language's bounded self-improvement harness.
It exists so the runtime can tune *itself* (e.g. engine tuning facts like
`batch_size/1`) under the same rules everything else obeys: proposals are
data, changes happen in isolation, benchmarks are recorded as facts, and
acceptance requires verification — with a rollback guarantee and a memory
of every rejection.

The CLI surface is deliberately minimal:

```sh
swipl -q -s bin/prlm.pl -- rsi --dry
# {"note":"experiments run in isolated workspaces","rsi":"dry"}
```

Bare `rsi` is a usage error (exit 2): experiments are never started
accidentally. They additionally require session authority of at least
`allow_session` — an `approve_diff` session cannot run experiments, because
self-modification is exactly what the authority ladder exists to gate.

## 1. The loop

`prlm_rsi_run/3` executes one experiment for a proposed `Change`:

```
OBSERVE → PROPOSE → IMPLEMENT → TEST → BENCHMARK → VERIFY → ACCEPT / REJECT
```

1. **OBSERVE** (`prlm_rsi_observe/2`). Read the live tuning state and
   usage aggregates from the session engine and the event stream. No
   experiment starts from vibes; the baseline is a fact, not an
   impression.
2. **PROPOSE** (`prlm_rsi_propose/3`, `prlm_rsi_propose_break/2`). A
   proposal is a closed term (`Change`) — inert data. Proposals are
   deterministic and, in tests, include deliberate regression drivers so
   both rejection paths are exercised end-to-end.
3. **IMPLEMENT** (tool `rsi_patch`). The candidate tuning fact is written
   to the **isolated workspace** `<rsi_workspace_root>/<ExpId>/rsi_tuning.pl`.
   The accepted runtime is never touched in this phase. The workspace root
   is a *required* session KVS key (`rsi_workspace_root`); if it is absent
   the harness throws `existence_error` rather than improvising a path.
4. **TEST** (tool `rsi_test`). A fresh kernel engine consults the
   candidate and runs the probe (e.g. `batch_size` must be an integer > 0).
   A candidate that does not even parse into the engine cannot proceed.
5. **BENCHMARK** (tool `rsi_benchmark`). A fixed, deterministic machine
   workload (N=200 kernel steps) measures baseline and candidate
   throughput. Both values — and the pre-run tuning value recorded before
   any phase — become `experiment_metric` facts. Deterministic workload,
   deterministic machine: the comparison is reproducible.
6. **VERIFY.** Two conditions, both required: probe ok **and** candidate
   throughput > baseline throughput. Fail either and the experiment is
   rejected *with a recorded reason*
   (`probe_failed(Why)` or `metric_not_improved`).
7. **ACCEPT / REJECT.**
   * **ACCEPT (promotion):** drain the old fact from the session engine's
     tuning module and `prlm_assertz` the candidate value. This is the
     *only* code path that mutates the accepted runtime, and it runs only
     after VERIFY passed.
   * **REJECT:** record `experiment_result(ExpId, rejected)` plus the
     failure fact; the runtime is untouched.

Every phase emits session events with `_{kind: rsi, …}` data on the one
normalized stream (`experiment` is intentionally not a new event type).

## 2. Isolated workspaces

Experiments map onto isolated workspaces — one directory per experiment id,
rooted at the session-declared `rsi_workspace_root`:

```
<rsi_workspace_root>/<ExpId>/rsi_tuning.pl
```

Why isolation is non-negotiable:

* a broken candidate must be unable to corrupt the accepted runtime — the
  worst outcome of a bad experiment is a rejected experiment;
* testing loads the candidate into a *fresh* engine, so state leakage
  between candidate and baseline is structurally impossible;
* the workspace path doubles as the audit trail: every accepted or
  rejected change has a file whose content is exactly what was tested.

## 3. Facts (the experiment record)

All lifecycle knowledge is closed facts (surfaced by `prlm_rsi_facts/2` as
dicts, grouped by kind in insertion order):

| Fact | Meaning |
|---|---|
| `experiment(ExpId, Desc)` | an experiment happened; what was attempted |
| `experiment_metric(ExpId, Phase, Metric, Value)` | measured numbers; `Phase ∈ pre | baseline | candidate` |
| `experiment_change(ExpId, Change)` | the exact inert proposal |
| `experiment_result(ExpId, accepted | rejected)` | the verdict |
| `experiment_failure(ExpId, Reason)` | why a rejection happened (`probe_failed(Why)`, `metric_not_improved`, …) |

Because the facts are ground and ordered, the *entire history* of
self-improvement is queryable: which changes were tried, what they
measured, why they were rejected. This is the substrate for future
meta-experiments (e.g. "which proposal families keep getting rejected and
why") — evidence, not anecdotes.

## 4. Promotion path

Promotion is the single mutation gate:

```
VERIFY passed
  → drain previous tuning fact(s) from the session engine module
  → prlm_assertz the candidate fact
  → experiment_result(ExpId, accepted)
```

Notes on the design:

* the promoted value is bit-identical to the value that was benchmarked —
  the workspace file is the source, not a re-derivation;
* draining then asserting keeps the tuning module's state closed: no stale
  duplicate facts can coexist with the promoted one;
* the accepted runtime is never edited in place, so a crash between
  benchmark and promotion leaves it untouched (the experiment simply never
  gets an `accepted` fact).

## 5. Rollback guarantee

Rollback is an *observable invariant*, not a procedure:
`prlm_rsi_rollback_check/3` verifies that for every **rejected**
experiment, the live tuning value still equals the pre-run snapshot
recorded as `experiment_metric(ExpId, pre, tuning, V)`.

Why checked this way: rejections must never have moved the runtime, so
"pre-run snapshot == live value" is a directly observable property. For
accepted experiments (or unknown ids) the check reports `false` — it is a
rollback guarantee, not an undo button. Undo of an *accepted* experiment is
itself just another experiment: propose the inverse change, let it run the
same gated loop.

## 6. Rejection memory

Rejections are first-class: `experiment_result(rejected)` and
`experiment_failure(Reason)` persist for the session, and the harness's
deterministic proposal set includes deliberate regressions (e.g. a
throughput-regressing proposal and a probe-violating proposal) so both
rejection paths stay tested by construction.

Why remember rejections: a self-improving system that forgets its failures
is doomed to resubmit them. The rejection memory, joined with the metric
facts, gives the next PROPOSE round evidence about what does not work and
why — the cheapest possible brake on oscillation. And because rejections
carry *recorded reasons* rather than silent failures, reviewers (human or
agent) can audit the brake itself.

## 7. Boundaries

* Authority: experiments need ≥ `allow_session`; child/agent experiments
  inherit the usual narrowing rules, so delegated RSI can only ever be
  weaker, never wider.
* Determinism: the benchmark is a fixed kernel workload on a fixed machine
  — no wall-clock roulette, no provider variance; the numbers in
  `experiment_metric` are reproducible.
* No ambient effects: IMPLEMENT writes only inside the declared workspace
  root; the tools are ordinary capability-gated tools, subject to the same
  effects/authority/budget gates as any other tool in the language.
