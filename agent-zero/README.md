# Prolog-RLM Auto-RAGE feature-freeze workers

This tree owns the two active Auto-RAGE development worker profiles for the Prolog-RLM / AgentProlog program.

The previous Hackmode Auto-RAGE development lanes are retired. Do not select Hackmode product work from these profiles.

## Feature freeze

`prolog-rlm` is under a development feature freeze for these workers.

Allowed Prolog-RLM work is deliberately narrow:

- the current expert-system issue set and the reusable expert-system APIs it already requires;
- API/runtime hardening of already-landed public behavior;
- regressions, correctness bugs, load/packaging failures, CI failures, compatibility defects, and documentation/tests needed to make existing behavior truthful;
- direct/symbolic mode hardening needed by the current runtime contract;
- focused generic seams required by the current AgentProlog integration;
- Auto-Dig integration defects discovered while dogfooding the Prolog-RLM runtime.

During the freeze, workers MUST NOT autonomously start broad new feature epics such as new retrieval stacks, skill-evolution programs, unrelated tool catalogs, new persistence subsystems, or speculative architecture. An open issue is not sufficient reason to start it. If it is not current expert-system/API-hardening/integration work, leave it alone unless the operator explicitly lifts the freeze for that issue.

Current merged code/tests outrank stale issue prose. Every slice starts from current `main`, follows `AGENTS.md`, and uses one focused issue/PR.

## Worker split

### `prolog-rlm-rage-hardening`

Owns the Prolog-RLM repository during the freeze.

Primary queue:

1. correctness regressions and load/API hardening;
2. current expert-system API issue set;
3. direct/symbolic runtime hardening required by those public APIs;
4. Auto-Dig integration failures and missing generic read-only/runtime seams.

This worker launches the Auto-Dig runner as a real downstream/dogfood integration check when relevant. If Auto-Dig exposes a Prolog-RLM defect, the worker fixes the generic Prolog-RLM defect with a regression test as part of its loop. It does not absorb Auto-Dig product policy or turn Prolog-RLM into an Auto-Dig application.

### `agentprolog-rage-integration`

Owns the AgentProlog product lane and may also make focused upstream Prolog-RLM changes when AgentProlog proves a generic public runtime seam is missing or incorrect.

The dependency direction is strict:

```text
AgentProlog -> public Prolog-RLM APIs
```

Product priorities during the freeze are:

1. finish the official DeepSeek Harness out-of-tree AgentProlog plugin path (`agentProlog#7` / current PR track);
2. make the DeepSeek Harness integration the primary AgentProlog product shell, without giving DSH a second provider/runtime/history/planner/authority/verifier implementation;
3. build a first-class, high-quality TUI plugin over the same canonical AgentProlog/Prolog-RLM protocol and state;
4. expose the canonical reasoning-mode commands below consistently in headless, DSH, and TUI surfaces;
5. dogfood AgentProlog against both AgentProlog and Prolog-RLM and upstream only reusable runtime fixes.

Broad AgentProlog skill-refinery/evolution research remains frozen unless explicitly re-enabled by the operator.

## Canonical reasoning modes

The two workers must preserve one runtime and one authority/effect system. These commands select reasoning strategy; they do not create alternate executors or permission systems.

- `/direct` — use native direct-mode model/tool execution through the canonical Prolog-RLM capability, authority, budget, trace, and effect boundaries.
- `/symbolic` — use the symbolic/typed Prolog-RLM path: explicit facts/rules/constraints/specs/plans and trusted verification where applicable. Symbolic mode may still use registered tools through the normal runtime boundary.
- `/symbolic-recursive` — symbolic mode with bounded recursive RLM/subagent decomposition enabled. Recursion remains globally budgeted, capability-narrowing, cancellable, and traceable.
- `/auto` — select `direct`, `symbolic`, or `symbolic-recursive` from the task shape and current evidence. The selection must be inspectable/traceable and must never widen capabilities, authority, tool availability, budgets, or verifier requirements.

A user command explicitly overrides `/auto` strategy selection until changed again. Switching strategy must preserve canonical conversation/run identity and must not fork provider history or execution state into a second runtime.

## DeepSeek Harness and TUI boundary

AgentProlog is the product. DeepSeek Harness and the TUI are adapters/presentation shells over AgentProlog's canonical Prolog-RLM-backed execution state.

They MUST NOT become independent owners of:

- model/provider execution;
- tool execution or capability grants;
- conversation truth/history;
- prompt/context compilation;
- planning or symbolic semantics;
- authority or durable effects;
- verification/acceptance state;
- subagent scheduling.

The DSH plugin and TUI plugin may project input, mode commands, progress, diffs, approvals, traces, evidence, and results. The same headless runtime contract remains authoritative.

## Worker hygiene

Both workers:

- inspect current open PRs before claiming work;
- use dedicated branches/worktrees;
- prefer RED-first regressions for behavioral defects;
- run the repository's focused and complete deterministic gates before declaring a slice complete;
- do not weaken tests or CI to obtain green;
- keep PRs issue-scoped and report exact head/evidence;
- hand cross-repository dependencies across through public typed contracts rather than copying internals;
- preserve feature freeze unless the operator explicitly changes it.
