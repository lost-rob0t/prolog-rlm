# PrologAgent roadmap

`PrologAgent` is the downstream coding-agent application built on `prolog-rlm`. The goal is an OpenCode-like terminal experience with project inspection, file editing, tools, approvals, tests, traces, and supervised model work while keeping the reusable runtime domain-neutral.

This roadmap tracks the shortest path from the current runtime to a useful coding agent. It is not a second `TODO.md`, and it should not duplicate every core issue. When implementation changes the dependency picture, update this file in the same PR.

**Repository boundary:** the AgentProlog product lives in the standalone `lost-rob0t/agentProlog` repository. There is no current nested `agentProlog/` product harness in `prolog-rlm`. This repository owns reusable runtime contracts and conformance evidence only.

## How far are we?

The hard runtime substrate is mostly here. The product layer is not.

Already available in core and the downstream application boundary:

- real OpenAI-compatible providers and streaming;
- typed model-selected plans;
- capability-gated tools and a confined `project_read` tool;
- confined Prolog-owned `SKILL.md` package discovery, inert resource indexing, and canonical skill prompt-unit normalization;
- supervised logical agents and recursive subagents, including child-owned
  bounded completion, typed parent result propagation, and cancellation;
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
- the #95 declarative Project/File/Language and Tree-sitter grammar registry, with explicit language evidence, parser selection, versioned grammar identity/provenance, and separate trusted native activation over #94;
- `prolog_agent_ui_v1`, a renderer-independent application boundary with bounded snapshots, ordered semantic events, explicit correlated commands, capability negotiation, deterministic replay, reconnect semantics, NDJSON framing, a child-process fixture server, and polyglot golden fixtures;
- on the #176/#216 candidate path, root-planner tool-schema visibility is compiled by the canonical `rlm_prompt_compiler` while trusted executable bindings remain separate for capability, authority, and effect enforcement.

Still missing for a useful coding agent:

- remaining canonical #57 effect-boundary adoption after the merged #86 tool-path slice, especially provider, MCP, and process/lifecycle paths tracked by #79;
- a standard project tool pack with search, write/edit, git, and test/process tools;
- durable project-scoped settings and remembered bounded approvals;
- the versioned CST/query/semantic/freshness layers from #96-#99 that turn the landed #94/#95 parser and registry substrate into the actual project parser/indexer and canonical project KB;
- TaskIR/context/result-acceptance integration around the Frozen Spec substrate from #56 and #68-#71;
- a headless coding loop that wires project inspection, edits, re-indexing, verification, and repair to those shared runtime concepts;
- nonblocking approval/diff handling wired from the real coding workflow into the UI facade;
- remaining provider-bound prompt-compiler adoption beyond the #216 root-planner local-tool slice, especially MCP metadata, project instructions, managed-context composition, and projection observability tracked by #176/#183;
- project instructions/context discovery for coding work;
- downstream product clients and editor integrations over the stable frontend boundary.

A reasonable description is: **the runtime foundation is roughly three quarters built, but the end-user coding agent is closer to halfway than finished.** The remaining work is smaller than building another agent framework, but larger than writing a terminal renderer.

## Product boundary

Keep the layers boring and explicit:

```text
standalone AgentProlog / DSH plugin / JS / CL / Nim / Emacs / Lem
              |
              v
       prolog_agent_ui_v1
 snapshots + ordered events + commands
              |
              v
     prolog-rlm frontend facade
              |
              v
 downstream coding workflow + external tool pack + project parser/indexer
  filesystem + git + process/test tools + canonical project KB
              |
              v
         prolog-rlm core
  Spec + Verify + plan + graph + authority + async + effects + MCP
```

Core must not gain ambient repository write access just because `PrologAgent` needs it. Coding tools remain separately loadable and capability-gated. A frontend never becomes a second execution engine. The project parser/indexer also remains a semantic observation producer, not a hidden executor.

## Phase 0: finish the write-safety substrate

The generic durable effect substrate is already on `main` through #78, #83, and #85, and #86 has landed the first canonical effectful-tool adoption slice. Before repository mutation is a normal feature, finish the remaining **canonical adoption** work tracked by #79.

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

## Phase 2: project state, project knowledge, instructions, and prompt compilation

Land the scoped-state work in #74 through #77 far enough for a coding frontend to remember project-local operator choices without inventing product-specific persistence in the TUI.

`PrologAgent` should be able to remember things such as:

- selected model/provider;
- test profile;
- project instructions;
- explicitly granted bounded project permissions;
- UI preferences that are safe to persist.

It must not persist `allow_session`, silently promote permissions to `dangerous`, or auto-execute arbitrary project Prolog files.

The symbolic prompt compiler is the sole owner of skill, instruction, tool, and MCP provider-context selection and bounded packing. The `SKILL.md` layer only discovers and normalizes inert packages into prompt units. The #216 slice wires compiler-active local tool schemas into the exact root-planner request without changing trusted executable bindings; #176/#183 retain the broader MCP, project-instruction, managed-context, observability, and permanent-context acceptance work.

The consolidated task-first runtime work on the `prolog-rlm-v1` branch improves
the downstream composition boundary without completing this phase: roots may
choose a strict direct answer or typed plan; retrieved structured evidence can
flow into an isolated task-producing model step; hosts can supply a descriptive
`agent_name/1`; delegated children suppress root identity; and managed
conversation packing has deterministic and paid 40,000-message acceptance.
These are reusable runtime contracts, not a coding-agent product. Project
instructions, MCP/managed-context compiler ownership, indexed cold retrieval,
the standard coding tool package, and the headless coding workflow remain open.

The same branch now adds a domain-neutral native direct loop. Standard provider
function tools cover bounded context, compiler-selected registered tools, SPEC
source compilation/observation/verification, and complete typed-plan execution.
Non-context results are retained behind opaque context aliases. A separate
Spec-strategy graph composes either direct or typed execution with
Observe/Verify/bounded Repair under one unchanged Frozen Spec. This is runtime
substrate only; it does not supply AgentProlog project policy, coding tools, or
product UX.

Project instructions should enter the coding context with provenance. Repository instructions, current source/tests, operator requirements, skill instructions, and model inference are not the same kind of evidence.

The direct Tree-sitter mechanics from #94, the declarative Project/File/Language/grammar registry from #95, and the bounded versioned CST observations from #96 are now substrate. The #96 layer handles both code and structured non-code project files, carries exact parse/grammar/source provenance, and keeps stale or partial generations explicit. Implement #97-#99 behind the same semantic project-state boundary established by `rlm_spec`/`rlm_verify`: run structural queries, normalize semantic source relations, and enforce incremental freshness. Source, build metadata, package metadata, and configuration should be parsed once into canonical project knowledge. Planner and verifier consumers query that knowledge through trusted semantic providers. Do not add a planner-only parser and a verifier-only parser.

The project KB remains distinct from artifacts, graph checkpoints, authority, effect journals, and runtime observations. After a write, invalidate/re-index affected project state and verify the unchanged Frozen Spec against the new snapshot plus runtime evidence.

## Phase 3: headless coding agent and frontend protocol

Build the coding workflow before coupling it to any particular renderer. This gives us something testable instead of debugging presentation and autonomous edits at the same time.

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

Reuse `rlm_spec`, `rlm_verify`, `rlm_spec_workflow`, `rlm_agent`, `rlm_graph`, `rlm_async`, `rlm_authority`, traces, effects, artifacts, and the shared prompt-compiler inputs. Do not create a special coding-agent scheduler, a second acceptance language, or a frontend-owned prompt router.

TaskIR work from #69 should carry/reference the exact Frozen Spec rather than becoming a second canonical owner of acceptance criteria. The INTENT -> SPEC -> VALIDATE (hard gate) -> PLAN -> plan-KB -> expert-loop flow, including the closed project-op plan vocabulary (rage/288 BASE + D6 deltas), typed expert dataflow, plan-vs-spec validation via `plan_validate_against_spec/4`, project retrieval/write/validation over the normalized reference grammar, and direct/symbolic/recursive strategy selection, is designed in `docs/research/spec-plan-authority.md` (rewrite of the PR #290 design; the merged `rlm_spec_lang` grammar is canonical and unchanged). Its implementation slices S0-S11 are the dependency graph for the remaining Phase 2/3 substrate, and `scripts/design_gate.pl` is the executable design gate for the record. Result acceptance work from #56 should share the same evidence/verifier substrate instead of growing an incompatible verifier stack. Resume/restart work from #71 must remain bound to the original Spec identity.

### Frontend protocol foundation

Issue #109 establishes the application-facing `prolog_agent_ui_v1` boundary before a renderer is built.

The protocol owns:

- bounded current snapshots for new clients and reconnect;
- ordered per-session semantic events with authoritative sequence numbers;
- explicit commands and results correlated by request IDs;
- capability negotiation;
- optional extension handling that advances sequence without inventing semantics;
- fail-closed handling for unsupported required extensions;
- deterministic replay and duplicate suppression;
- a runtime facade that converts canonical agent events once into frontend-safe values;
- one-record-per-line UTF-8 NDJSON as the first polyglot encoding;
- a child `swipl` stdio fixture/server while leaving transport semantics abstract enough for later Unix/local sockets.

Reconnect is always:

```text
negotiate -> canonical snapshot -> resume events after snapshot.at_seq
```

A frontend never rebuilds domain state from pretty logs or raw trace internals.

The deterministic golden fixture covers model streaming, tools, an unknown tool, approvals, questions, subagents, verification, usage, traces, optional unknown events, reconnect and indeterminate effects. Stress coverage interleaves semantic events with 10,000 text deltas and verifies that order is preserved while snapshots remain bounded.

The exact wire contract is documented in `docs/prolog-agent-ui-v1.md`.

### Headless workflow still required

The protocol does **not** replace the real coding workflow. The downstream workflow still needs to emit canonical events such as run/message/tool/approval/question/subagent/verification/usage/trace/effect/completion transitions through the facade while remaining authoritative for execution and state.

From the standalone AgentProlog product, a supported command should eventually feel like:

```sh
agent-prolog "Add a timeout to the MCP request path and run the relevant tests"
```

The command should finish only when the exact Frozen Spec's configured acceptance checks pass or the run ends with a structured blocked/failed outcome.

## Phase 4: downstream product clients and editor integrations

Rich clients belong downstream and consume the stable runtime protocol rather than living as nested product code in `prolog-rlm`.

The researched renderer directions remain useful as downstream options:

- **DeepSeek Harness:** the approved #184 plugin-only path preserves the official upstream Web/headless surfaces and replaces only the agent factory/control seam needed to route canonical work through Prolog-RLM;
- **JavaScript/TypeScript:** OpenTUI + SolidJS remains a possible standalone TUI path, not a core dependency;
- **Common Lisp:** a shared protocol client, with Tuition as a possible standalone TUI;
- **Nim:** a protocol client regardless of final renderer;
- **Emacs:** native buffers/diffs/compilation UI over async process/socket transport;
- **Lem:** native editor integration over the same renderer-independent protocol.

A downstream terminal client only needs a small set of useful surfaces initially: conversation/model stream, active task/tool state, diff/file preview, approvals, and compact usage/verification/error state.

If a client needs domain logic that is absent from `prolog_agent_ui_v1`, treat that as a protocol/facade defect or an explicitly versioned extension. Do not smuggle runtime semantics into a renderer merely because it is convenient.

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
- clients remain responsive while provider, tool, and test operations are active;
- final output shows changed files, verification results, usage, and trace reference.

## Milestone definition

`PrologAgent v0.1` is reached when a user can open a repository, give a coding task, watch the model inspect and edit files, approve mutations, run tests, review the final diff, and receive a structured completion result without granting ambient shell/filesystem authority.

The first release does not need IDE parity, a plugin marketplace, background daemons, arbitrary shell access, every OpenCode feature, or all researched frontend implementations. It needs a trustworthy inspect/edit/re-index/verify loop, a stable frontend contract, and at least one good downstream client.

## Dependency map

Current core and product issues that materially affect the roadmap:

- #79: canonical external-effect adoption remains open; #86 has landed the first effectful-tool path, while provider, MCP, and process/lifecycle adoption remain.
- #49 / #50: companion project/coding tool pack.
- #54: async contract; core migrations are largely complete, while external process/test/network and downstream approval/TUI integration remain.
- #56: result acceptance should build on the shared evidence/provenance/verifier substrate now used by Spec Verify; the closed #144 path supplies child-owned bounded subagent completion, exact child capability/authority possession, typed parent result propagation, closed KB command selection, and fail-closed recursive subagent registration. Broader evidence/result acceptance remains #56 scope.
- #68: verified workflow epic remains open; first-class Spec/Verify and graph composition are substrate, not the whole product workflow.
- #69: TaskIR should reference the exact Frozen Spec and carry task/execution metadata rather than own a competing acceptance contract.
- #70: project context should incorporate canonical project-KB snapshot references and provenance; #94 supplies direct Tree-sitter parser mechanics and #95 supplies Project/File/Language/grammar selection, while #96-#99 still need the versioned CST, structural-query, semantic, and freshness layers.
- #71: workflow execution/resume must remain bound to the exact Frozen Spec; the Spec-bound graph foundation now demonstrates that invariant, while full TaskIR/continuation integration remains open.
- #74-#77: durable project state, instructions, and bounded persistent authorization.
- #93/#96-#99: #94/#95 are the direct parser and declarative source-registry substrate; the remaining child issues are required before the canonical project parser/indexer and project KB are complete.
- #101/#117/#173/#183: standard skill packages normalize into the one prompt compiler; permanent operating context and exact provider-bound adoption remain explicit follow-up scope.
- #176: #216 supplies the root-planner local-tool schema projection through the canonical compiler while preserving separate trusted execution bindings; MCP/project-instruction/managed-context adoption and projection observability remain open.
- #109: the renderer-independent `prolog_agent_ui_v1` protocol/replay foundation is landed in core; concrete renderer/product work is downstream.
- #184: approved plugin-only DeepSeek Harness architecture; implementation starts from the cleaned runtime boundary rather than reviving PR #125 or a nested harness.
- #186: removes legacy nested harnesses and restores the runtime-only repository boundary before #184 implementation.

Do not wait for every P1 research idea before advancing the standalone `lost-rob0t/agentProlog` product. Build downstream against stable public contracts, keep optional integrations optional, and let the first usable coding loop drive the remaining abstractions.
