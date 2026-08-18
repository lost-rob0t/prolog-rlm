# PrologAgent

`PrologAgent` is the planned downstream coding-agent application built on `prolog-rlm`.

It is intentionally separate from the reusable runtime. Core owns model execution, agents, graphs, authority, async work, effects, MCP, traces, and durable state. `agentProlog/` owns the coding workflow and terminal UX that combine those pieces into an OpenCode-style tool.

The implementation roadmap lives in [`docs/prolog-agent-roadmap.md`](../docs/prolog-agent-roadmap.md).

## Target experience

A user opens a repository and gives the agent a normal coding task:

```sh
swipl -q -s agentProlog/bin/agent-prolog.pl -- \
  "Fix the failing authority tests and show me the final diff"
```

The coding workflow should then:

1. inspect project instructions and relevant source/tests;
2. search and read files through bounded project tools;
3. propose or perform capability-gated edits;
4. surface mutations through the existing authority boundary;
5. run configured verification;
6. repair failures when allowed;
7. return changed files, verification results, usage, and a trace reference.

The later full-screen terminal client should expose the same workflow rather than implementing a second execution path.

```text
> add a timeout to the MCP request path

Reading project instructions...
Searching MCP transport...
Editing 2 files

Diff ready: +24 -7
[a] allow once  [s] allow session  [p] allow project  [d] deny

Focused tests       PASS
Deterministic gate  PASS

Done. Trace: run_42
```

## Architecture

```text
agentProlog TUI / CLI
        |
        v
coding workflow
        |
        +--> project tool pack
        +--> authority / approvals
        +--> verification profiles
        |
        v
prolog-rlm runtime
```

The coding frontend should consume structured runtime events for model streaming, tool lifecycle, pending diffs, verification, cancellation, usage, and completion. It must not scrape pretty-printed logs to infer state.

## Security boundary

Loading coding tools does not grant their capabilities. Repository writes, process execution, network access, and MCP effects remain explicit bounded operations.

No ambient shell is required for the first release. File edits should use confined write/patch tools, and test commands should come from trusted configured profiles rather than arbitrary model-generated shell strings.

Persistent project approval, when implemented, is a bounded remembered operator decision. It is not persistent `allow_session`, not `dangerous`, and never bypasses capability, confinement, budget, cancellation, or effect accounting.

## Status

The core agent/runtime substrate exists. `agentProlog/` is not yet a runnable coding agent. The immediate dependencies and milestone sequence are tracked in the roadmap; update that document in the same PR whenever implementation materially changes readiness or dependencies.