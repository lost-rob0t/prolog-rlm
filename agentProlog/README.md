# PrologAgent

`PrologAgent` is the planned downstream coding-agent application built on `prolog-rlm`.

It is intentionally separate from the reusable runtime. Core owns model execution, agents, graphs, authority, async work, effects, MCP, traces, and durable state. `agentProlog/` owns the coding workflow, application-facing UI protocol, and terminal/editor UX that combine those pieces into an OpenCode-style tool.

The implementation roadmap lives in [`docs/prolog-agent-roadmap.md`](../docs/prolog-agent-roadmap.md). The renderer-independent frontend contract is documented in [`docs/prolog-agent-ui-v1.md`](../docs/prolog-agent-ui-v1.md).

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

The full-screen terminal client exposes that workflow through `prolog_agent_ui_v1` rather than implementing a second execution path.

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
JS TUI / CL / Nim / Emacs / Lem
              |
              v
       prolog_agent_ui_v1
 snapshots + ordered events + commands
              |
              v
      AgentProlog UI facade
              |
              v
         coding workflow
              |
        +-----+-----------------------+
        |                             |
 project tool pack            authority / verify
              |
              v
        prolog-rlm runtime
```

Prolog remains authoritative. Frontends render bounded canonical snapshots, consume ordered semantic events, negotiate presentation capabilities, and issue correlated commands. They do not execute tools, implement permissions, reconstruct domain state from raw traces, or become alternate agent runtimes.

The first reference transport is one-record-per-line UTF-8 NDJSON over a child `swipl` process. Transport is intentionally abstract from protocol semantics so a Unix/local socket can be added without changing the records.

The deterministic fixture server can be exercised with:

```sh
swipl -q -s agentProlog/bin/prolog-agent-ui-fixture.pl
```

The golden polyglot session is `agentProlog/fixtures/prolog_agent_ui_v1_session.ndjson`.

## OpenTUI reference client

The first standalone renderer lives in `agentProlog/ui/opentui/`. It is a Bun + OpenTUI + SolidJS client that deliberately targets the deterministic fixture before the real coding workflow is wired in.

```sh
cd agentProlog/ui/opentui
bun install
bun run dev
```

The client:

- spawns the child `swipl` fixture behind an NDJSON transport interface;
- negotiates `prolog_agent_ui_v1` and applies only canonical snapshots/events;
- keeps request correlation separate from event sequence numbers;
- renders streaming conversation, tools, approvals/questions, subagents, verification, usage, traces, indeterminate effects, and optional unknown events;
- renders unknown tools generically rather than requiring a TypeScript tool catalog;
- sends approval/question/cancel commands using values advertised by protocol state rather than implementing authority policy locally;
- fails visibly on sequence gaps, malformed records, required unknown extensions, unexpected server frames, and transport exit.

It is a reference client, not an alternate runtime. The real coding loop, project tools, project-KB refresh, and verification remain authoritative downstream work.

## Security boundary

Loading coding tools does not grant their capabilities. Repository writes, process execution, network access, and MCP effects remain explicit bounded operations.

No ambient shell is required for the first release. File edits should use confined write/patch tools, and test commands should come from trusted configured profiles rather than arbitrary model-generated shell strings.

Persistent project approval, when implemented, is a bounded remembered operator decision. It is not persistent `allow_session`, not `dangerous`, and never bypasses capability, confinement, budget, cancellation, or effect accounting.

The UI protocol does not weaken this boundary. A client command is a request to the authoritative runtime, not permission to invoke a mutation handler directly.

## Status

The core agent/runtime substrate exists. `agentProlog/` is not yet a runnable coding agent, but it now has both the renderer-independent frontend protocol and the first fixture-backed standalone TUI client.

`prolog_agent_ui_v1` defines the snapshot/event/command boundary, deterministic replay semantics, request correlation, reconnect behavior, NDJSON encoding, a child-process fixture server, golden fixtures, and 10,000-delta stress coverage. Issue #112 adds the small OpenTUI + SolidJS reference client against that contract with its own deterministic typecheck/protocol/transport/render CI lane.

The next product dependency is not more renderer-side domain logic. It is wiring the real headless coding workflow, concrete project tool pack, approvals, project state, and verification into the existing UI facade so this same client can consume live sessions unchanged. Native Emacs/Lem/CL/Nim clients remain later protocol consumers.

Update the roadmap in the same PR whenever implementation materially changes readiness or dependencies.
