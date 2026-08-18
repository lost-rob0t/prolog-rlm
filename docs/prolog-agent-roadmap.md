# PrologAgent roadmap

`PrologAgent` is the downstream coding-agent application built on `prolog-rlm`. The goal is an OpenCode-like terminal experience with project inspection, file editing, tools, approvals, tests, traces, and supervised model work while keeping the reusable runtime domain-neutral.

This roadmap tracks the shortest path from the current runtime to a useful coding agent. It is not a second `TODO.md`, and it should not duplicate every core issue. When implementation changes the dependency picture, update this file in the same PR.

## How far are we?

The hard runtime substrate is mostly here. The product layer is not.

Already available in core:

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
- a project-KB observation boundary that lets future planners and verifiers consume the same semantic project state without teaching either layer to parse source code.

Still missing for a useful coding agent:

- canonical #57 effect-boundary adoption across the effectful paths tracked by #79;
- a standard project tool pack with search, write/edit, git, and test/process tools;
- durable project-scoped settings and remembered bounded approvals;
- the actual project parser/indexer and canonical project-KB implementation consumed by the new semantic observation boundary;
- TaskIR/context/result-acceptance integration around the Frozen Spec substrate from #56 and #68-#71;
- a headless coding loop that wires project inspection, edits, re-indexing, verification, and repair to those shared runtime concepts;
- nonblocking approval/diff handling suitable for an interactive terminal;
- project instructions/context discovery for coding work;
- the actual `agentProlog/` terminal application.

A reasonable description is: **the runtime foundation is roughly three quarters built, but the end-user coding agent is closer to halfway than finished.** The remaining work is smaller than building another agent framework, but larger than writing a terminal renderer.

## Product boundary

Keep the layers boring and explicit:

```text
agentProlog/
  TUI + coding workflow + project UX
        |
        v
external tool pack + project parser/indexer
  filesystem + git + process/test tools + canonical project KB
        |
        v
prolog-rlm core
  Spec + Verify + plan + graph + authority + async + effects + MCP
```

Core must not gain ambient repository write access just because `PrologAgent` needs it. Coding tools remain separately loadable and capability-gated. The TUI never becomes a second execution engine. The project parser/indexer also remains a semantic observation producer, not a hidden executor.

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

In parallel, implement the project parser/indexer behind the semantic project-state boundary established by `rlm_spec`/`rlm_verify`. Source, build metadata, package metadata, and configuration should be parsed once into canonical project knowledge. Planner and verifier consumers query that knowledge through trusted semantic providers. Do not add a planner-only parser and a verifier-only parser.

The project KB remains distinct from artifacts, graph checkpoints, authority, effect journals, and runtime observations. After a write, invalidate/re-index affected project state and verify the unchanged Frozen Spec against the new snapshot plus runtime evidence.

## Phase 3: headless coding agent

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

The workflow should expose events that a future TUI can consume:

```prolog
agent_event(run_started, Meta).
agent_event(model_delta, Text).
agent_event(tool_started, Tool).
agent_event(tool_finished, Tool, Outcome).
agent_event(diff_pending, ApprovalId, Diff).
agent_event(verification, Name, Outcome).
agent_event(run_finished, Outcome).
```

Exact terms may differ. The important part is one structured event stream rather than the UI scraping log text.

### Headless example

A supported command should eventually feel like:

```sh
swipl -q -s agentProlog/bin/agent-prolog.pl -- \
  "Add a timeout to the MCP request path and run the relevant tests"
```

The command should finish only when the exact Frozen Spec's configured acceptance checks pass or the run ends with a structured blocked/failed outcome.

## Phase 4: OpenCode-style TUI

Once the headless loop is stable, add the interactive terminal client under `agentProlog/`.

The first TUI only needs five useful surfaces:

1. conversation/model stream;
2. current task and active tool state;
3. diff/file preview;
4. approval prompt with allow-once/session/project choices where supported;
5. compact usage, verification, and error status.

The TUI must consume async runtime events so model, tool, and test work never freezes navigation or approval handling.

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
- the TUI remains responsive while provider, tool, and test operations are active;
- final output shows changed files, verification results, usage, and trace reference.

## Milestone definition

`PrologAgent v0.1` is reached when a user can open a repository, give a coding task, watch the model inspect and edit files, approve mutations, run tests, review the final diff, and receive a structured completion result without granting ambient shell/filesystem authority.

The first release does not need IDE parity, a plugin marketplace, background daemons, arbitrary shell access, or every OpenCode feature. It needs a trustworthy inspect/edit/re-index/verify loop with a terminal interface.

## Dependency map

Current core issues that materially affect the roadmap:

- #79: canonical external-effect adoption; blocks normal repository mutation. The #57 generic substrate is merged, but adoption is not.
- #49 / #50: companion project/coding tool pack.
- #54: async contract; core migrations are largely complete, while external process/test/network and downstream approval/TUI integration remain.
- #56: result acceptance should build on the shared evidence/provenance/verifier substrate now used by Spec Verify; the broader result-envelope/delegation work remains open.
- #68: verified workflow epic remains open; first-class Spec/Verify and graph composition are substrate, not the whole product workflow.
- #69: TaskIR should reference the exact Frozen Spec and carry task/execution metadata rather than own a competing acceptance contract.
- #70: project context should incorporate canonical project-KB snapshot references and provenance; the parser/indexer itself still needs to be built.
- #71: workflow execution/resume must remain bound to the exact Frozen Spec; the Spec-bound graph foundation now demonstrates that invariant, while full TaskIR/continuation integration remains open.
- #74-#77: durable project state, instructions, and bounded persistent authorization.

Do not wait for every P1 research idea before starting `agentProlog/`. Build against stable public contracts, keep optional integrations optional, and let the first usable coding loop drive the remaining abstractions.
