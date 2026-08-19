# PrologAgent roadmap

`PrologAgent` is the downstream coding-agent application built on `prolog-rlm`. The goal is an OpenCode-like terminal experience with project inspection, file editing, tools, approvals, tests, traces, and supervised model work while keeping the reusable runtime domain-neutral.

This roadmap tracks the shortest path from the current runtime to a useful coding agent. It is not a second `TODO.md`, and it should not duplicate every core issue. When implementation changes the dependency picture, update this file in the same PR.

## How far are we?

The hard runtime substrate is mostly here. The product layer is not.

Already available in core and the downstream application boundary:

- real OpenAI-compatible providers and streaming;
- typed model-selected plans;
- capability-gated tools and a confined `project_read` tool;
- supervised logical agents and recursive subagents;
- bounded async Futures, cancellation, and worker pools;
- durable graphs, checkpoints, interrupts, and traces;
- MCP client/server integration;
- host-controlled authority and pending approvals;
- durable artifacts;
- the generic #57 durable effect identity/observation substrate, including the #83 hardening and #85 explicit migration path;
- first-class domain-neutral Specs with immutable content identity;
- a trusted assertion/evidence boundary with standalone pure verification;
- optional Spec-bound Plan execution and a bounded Verify/repair composition over `rlm_graph`;
- a project-KB observation boundary that lets future planners and verifiers consume the same semantic project state without teaching either layer to parse source code;
- the #94 direct generic SWI-Prolog <-> Tree-sitter C FFI, with owned native handles, generic grammar loading, and multi-grammar parsing mechanics;
- `prolog_agent_ui_v1`, a renderer-independent application boundary with bounded snapshots, ordered semantic events, explicit correlated commands, capability negotiation, deterministic replay, reconnect semantics, NDJSON framing, a child-process fixture server, and polyglot golden fixtures;
- the first fixture-backed OpenTUI + SolidJS reference client, isolated behind the same protocol and NDJSON transport boundary rather than importing runtime semantics.

Still missing for a useful coding agent:

- canonical #57 effect-boundary adoption across the effectful paths tracked by #79;
- a standard project tool pack with search, write/edit, git, and test/process tools;
- durable project-scoped settings and remembered bounded approvals;
- the Prolog-side Project/File/Language/grammar registry and CST/query/semantic/freshness layers from #95-#99 that turn the landed #94 parser mechanics into the actual project parser/indexer and canonical project KB;
- TaskIR/context/result-acceptance integration around the Frozen Spec substrate from #56 and #68-#71;
- a headless coding loop that wires project inspection, edits, re-indexing, verification, and repair to those shared runtime concepts;
- nonblocking approval/diff handling wired from the real coding workflow into the UI facade;
- project instructions/context discovery for coding work;
- wiring the OpenTUI reference client to real AgentProlog sessions plus the native editor clients.

A reasonable description is: **the runtime foundation is roughly three quarters built, but the end-user coding agent is closer to halfway than finished.** The remaining work is smaller than building another agent framework, but larger than writing a terminal renderer.

## Product boundary

Keep the layers boring and explicit:

```text
JS TUI / CL TUI / Nim / Emacs / Lem
              |
              v
       prolog_agent_ui_v1
 snapshots + ordered events + commands
              |
              v
      AgentProlog UI facade
              |
              v
coding workflow + external tool pack + project parser/indexer
  filesystem + git + process/test tools + canonical project KB
              |
              v
         prolog-rlm core
  Spec + Verify + plan + graph + authority + async + effects + MCP
```

Core must not gain ambient repository write access just because `PrologAgent` needs it. Coding tools remain separately loadable and capability-gated. A frontend never becomes a second execution engine. The project parser/indexer also remains a semantic observation producer, not a hidden executor.

## Phase 0: finish the write-safety substrate

The generic durable effect substrate is already on `main` through #78, #83, and #85. Before repository mutation is a normal feature, finish the **canonical adoption** work tracked by #79. Open PR #86 is the first tool-path slice, but it is not merged evidence and does not make the phase complete.

Required outcome:

- effectful tool execution crosses authority and durable effect admission before mutation;
- provider, MCP request, and lifecycle/process effects use the same boundary where applicable;
- retries, repeated waits, backtracking, and restart do not accidentally replay a write;
- uncertainty after dispatch is represented honestly instead of silently executing again.

This is the dependency that keeps “edit this file” from becoming “edit this file twice because a callback sneezed.”

## Phase 1: standard coding tools

Implement the companion tool-pack direction from #49 and #50. The first useful set is deliberately small:

### Filesystem

- `project_read`
- `project_search`
- `project_write`
- `project_patch`

Writes must be confined to the selected project root. `project_patch` should use structured replacements or unified patches with preimage checks so a stale edit fails instead of corrupting a newer file.

### Git

- `git_status`
- `git_diff`
- `git_show`
- `git_apply` or an equivalent bounded mutation primitive

Do not expose arbitrary shell text as “git support.”

### Process and verification

- `run_tests`
- a bounded configured `process_run`

Commands come from trusted profiles or closed tool arguments, with cwd confinement, environment filtering, timeout, output limits, and authority checks.

### Example

A model should be able to execute a flow equivalent to:

```text
project_search("rlm_authority")
project_read("prolog/rlm_authority.pl")
project_patch("prolog/rlm_authority.pl", Patch)
run_tests("authority")
git_diff()
```

Every step remains a normal traced tool operation. File mutation does not bypass authority simply because it came from a coding workflow.

## Phase 2: project state, project knowledge, and instructions

Land the scoped-state work in #74 through #77 far enough for a coding frontend to remember project-local operator choices without inventing product-specific persistence in the TUI.

`PrologAgent` should be able to remember things such as:

- selected model/provider;
- test profile;
- project instructions;
- explicitly granted bounded project permissions;
- UI preferences that are safe to persist.

It must not persist `allow_session`, silently promote permissions to `dangerous`, or auto-execute arbitrary project Prolog files.

Project instructions should enter the coding context with provenance. Repository instructions, current source/tests, operator requirements, and model inference are not the same kind of evidence.

The direct Tree-sitter mechanics from #94 are now substrate. Implement #95-#99 behind the semantic project-state boundary established by `rlm_spec`/`rlm_verify`: register Project/File/Language/grammar relationships, project concrete syntax into versioned observations, run structural queries, normalize semantic source relations, and enforce incremental freshness. Source, build metadata, package metadata, and configuration should be parsed once into canonical project knowledge. Planner and verifier consumers query that knowledge through trusted semantic providers. Do not add a planner-only parser and a verifier-only parser.

The project KB remains distinct from artifacts, graph checkpoints, authority, effect journals, and runtime observations. After a write, invalidate/re-index affected project state and verify the unchanged Frozen Spec against the new snapshot plus runtime evidence.

## Phase 3: headless coding agent and frontend protocol

Build the coding workflow before the full-screen UI. This gives us something testable instead of debugging terminal escape codes and autonomous edits at the same time, a classic human hobby.

The minimum workflow is:

```text
operator requirements
-> normalize/validate/freeze Spec S1
-> inspect project snapshot K1 + instructions
-> produce or accept Plan P1 bound to S1
-> execute bounded edits/tools
-> refresh/re-index project state to K2
-> collect runtime/project observations
-> Verify S1
-> repair/replan on failure without weakening S1
-> finish with structured evidence
```

Reuse `rlm_spec`, `rlm_verify`, `rlm_spec_workflow`, `rlm_agent`, `rlm_graph`, `rlm_async`, `rlm_authority`, traces, effects, and artifacts. Do not create a special coding-agent scheduler or a second acceptance language.

TaskIR work from #69 should carry/reference the exact Frozen Spec rather than becoming a second canonical owner of acceptance criteria. Result acceptance work from #56 should share the same evidence/verifier substrate instead of growing an incompatible verifier stack. Resume/restart work from #71 must remain bound to the original Spec identity.

### Frontend protocol foundation

Issue #109 established the application-facing `prolog_agent_ui_v1` boundary before a renderer was built and is merged on `main` through PR #110.

The protocol owns:

- bounded current snapshots for new clients and reconnect;
- ordered per-session semantic events with authoritative sequence numbers;
- explicit commands and results correlated by request IDs;
- capability negotiation;
- optional extension handling that advances sequence without inventing semantics;
- fail-closed handling for unsupported required extensions;
- deterministic replay and duplicate suppression;
- a runtime facade that converts canonical AgentProlog events once into frontend-safe values;
- one-record-per-line UTF-8 NDJSON as the first polyglot encoding;
- a child `swipl` stdio fixture/server while leaving transport semantics abstract enough for later Unix/local sockets.

Reconnect is always:

```text
negotiate -> canonical snapshot -> resume events after snapshot.at_seq
```

A frontend never rebuilds domain state from pretty logs or raw trace internals.

The first deterministic golden fixture covers model streaming, tools, an unknown tool, approvals, questions, subagents, verification, usage, traces, optional unknown events, reconnect and indeterminate effects. Stress coverage interleaves semantic events with 10,000 text deltas and verifies that order is preserved while snapshots remain bounded.

The exact wire contract is documented in `docs/prolog-agent-ui-v1.md`.

### Headless workflow still required

The protocol does **not** replace the real coding workflow. The workflow still needs to emit canonical events such as run/message/tool/approval/question/subagent/verification/usage/trace/effect/completion transitions through the facade while remaining authoritative for execution and state.

A supported command should eventually feel like:

```sh
swipl -q -s agentProlog/bin/agent-prolog.pl -- \
  "Add a timeout to the MCP request path and run the relevant tests"
```

The command should finish only when the exact Frozen Spec's configured acceptance checks pass or the run ends with a structured blocked/failed outcome.

## Phase 4: OpenCode-style reference TUI and native editor clients

The renderer work now starts from the stable protocol/replay boundary rather than inventing frontend semantics independently.

The current renderer direction is:

- **JavaScript/TypeScript:** OpenTUI + SolidJS as the reference standalone TUI path;
- **Common Lisp:** a shared `prolog-agent-client`, with Tuition as the first standalone TUI spike;
- **Nim:** a protocol client regardless of whether the final renderer is pure Illwill or an OpenTUI C ABI;
- **Emacs:** native buffers/diffs/compilation UI over async process/socket transport, with Sweep optional for bounded direct calls;
- **Lem:** native editor integration over the same Common Lisp client.

Issue #112 is the first JS renderer slice. It adds a self-contained Bun/OpenTUI/Solid package under `agentProlog/ui/opentui/`, pinned frontend dependencies, a typed v1 decoder/reducer, an abstract NDJSON transport, a child-`swipl` fixture transport, correlated request handling, keyboard command dispatch, and a path-filtered deterministic UI CI job. Its tests replay the canonical golden fixture and exercise a real fixture command without giving TypeScript any tool or authority implementation.

The first standalone TUI only needs five useful surfaces:

1. conversation/model stream;
2. current task and active tool state;
3. diff/file preview;
4. approval prompt with allow-once/session/project choices where supported;
5. compact usage, verification, and error status.

The client must consume asynchronous protocol events so model, tool, and test work never freezes navigation or approval handling.

Example interaction:

```text
> fix the failing authority tests

Searching project...
Reading prolog/rlm_authority.pl
Editing test/rlm_authority_test.pl

Diff ready: 2 files, +31 -8
[a] allow once  [s] allow session  [p] allow project  [d] deny

Running authority tests... PASS
Running deterministic gate... PASS

Done. 2 files changed. Trace: run_42
```

The UI should display structured outcomes, not translate every error into cheerful prose and hope nobody notices.

If the reference JS client needs domain logic that is absent from `prolog_agent_ui_v1`, treat that as a protocol/facade defect. Do not smuggle runtime semantics into TypeScript merely because it is convenient.

The remaining JS work after the fixture-backed slice is integration, not a second renderer architecture: replace the fixture transport endpoint with the real AgentProlog session transport, feed the same protocol from the headless coding workflow, then deepen navigation/diff/composer UX only where protocol data supports it.

## Phase 5: coding-agent quality bar

Before calling the first release useful, cover these behaviors end to end:

- cancelled edits do not execute later;
- stale patches fail cleanly;
- project-root traversal and symlink escapes are rejected;
- an approval applies to the exact normalized operation it reviewed;
- restart does not duplicate an admitted write;
- restart remains bound to the exact Frozen Spec it started with;
- test failure enters repair rather than being reported as success;
- repair may change Plan but cannot weaken Frozen Spec acceptance requirements;
- static project observations and runtime evidence from incompatible revisions cannot silently pass as one coherent state;
- project A permissions never leak into project B;
- reconnecting a frontend obtains canonical state instead of guessing from partial local history;
- unknown tools remain renderable through a generic safe representation;
- unsupported required protocol extensions fail closed;
- the TUI remains responsive while provider, tool, and test operations are active;
- final output shows changed files, verification results, usage, and trace reference.

## Milestone definition

`PrologAgent v0.1` is reached when a user can open a repository, give a coding task, watch the model inspect and edit files, approve mutations, run tests, review the final diff, and receive a structured completion result without granting ambient shell/filesystem authority.

The first release does not need IDE parity, a plugin marketplace, background daemons, arbitrary shell access, every OpenCode feature, or all researched frontend implementations. It needs a trustworthy inspect/edit/re-index/verify loop, a stable frontend contract, and at least one good terminal client.

## Dependency map

Current core and product issues that materially affect the roadmap:

- #79: canonical external-effect adoption; blocks normal repository mutation. The #57 generic substrate is merged, but adoption is not.
- #49 / #50: companion project/coding tool pack.
- #54: async contract; core migrations are largely complete, while external process/test/network and downstream approval/TUI integration remain.
- #56: result acceptance should build on the shared evidence/provenance/verifier substrate now used by Spec Verify; the broader result-envelope/delegation work remains open.
- #68: verified workflow epic remains open; first-class Spec/Verify and graph composition are substrate, not the whole product workflow.
- #69: TaskIR should reference the exact Frozen Spec and carry task/execution metadata rather than own a competing acceptance contract.
- #70: project context should incorporate canonical project-KB snapshot references and provenance; #94 now supplies direct Tree-sitter parser mechanics, while #95-#99 still need to build the Project/file/grammar registry, versioned CST, structural query, semantic, and freshness layers.
- #71: workflow execution/resume must remain bound to the exact Frozen Spec; the Spec-bound graph foundation now demonstrates that invariant, while full TaskIR/continuation integration remains open.
- #74-#77: durable project state, instructions, and bounded persistent authorization.
- #93/#95-#99: #94 is the direct Tree-sitter FFI substrate; the remaining child issues are required before the canonical project parser/indexer and project KB are complete.
- #109 / PR #110: merged renderer-independent `prolog_agent_ui_v1` protocol/replay foundation.
- #112: fixture-backed OpenTUI + SolidJS reference client; once this slice is green, the next UI work is wiring real AgentProlog sessions into the same client rather than adding frontend domain logic.

Do not wait for every P1 research idea before starting `agentProlog/`. Build against stable public contracts, keep optional integrations optional, and let the first usable coding loop drive the remaining abstractions.
