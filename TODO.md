# prolog-rlm TODO

This backlog is intentionally broader than the first runnable RLM. Work should land in small, testable slices.

## Status convention

Status reconciled against canonical `main` commit `abfc30ebb9f335d5841c1f7910bd474da905ebcf` on 2026-08-18, with the post-merge issue-state audit completed after PR #89.

- `[x]` means the implementation/documentation/test surface represented by that checkbox is present on `main` and sufficiently verified.
- `[ ]` means meaningful work remains, the surface is only partially covered, or a known open defect prevents treating the aggregate contract as complete.
- GitHub issue state, merged source/tests, this TODO, and the PrologAgent roadmap must be reconciled together. Merged canonical source and tests outrank historical status prose.

### Currently open correctness defects

These remain blockers for the v0.1/manual-validation umbrella in #3:

- #42 — recursive-plan fingerprints can falsely report a cycle for anonymous-tag SWI dicts.
- #44 — completion still loses executed provider usage when a later plan operation fails; the issue was reopened during this reconciliation because `completion_after_execution/8` on `main` still returns the execution error before aggregating plan usage.
- #45 — nested completion trajectories can omit model events or report the wrong true depth.
- #46 — the live OpenRouter streaming gate is not router-safe when `openrouter/free` selects a healthy model that ignores the sentinel instruction.

### Open feature and architecture work

The main active architecture tracks are the companion/standard tool pack (#49/#50), the downstream expert-system example (#51), remaining cross-library async/TUI integration (#54), proof/evidence acceptance (#56), canonical adoption of the durable effect boundary (#57/#79), the verified workflow pipeline (#68-#71), and durable scoped project policy/configuration (#74-#77).

The generic #57 effect substrate is already merged through #78, #83, and #85. That does **not** complete #57: canonical provider/tool/MCP/process adoption remains in #79, and open PR #86 is only the first tool-path slice until it is actually merged.

### Documentation and hygiene work

- #67 — registry destruction still does not automatically clear loader idempotency bookkeeping.

### Completed historical foundations

The external loader boundary (#48), declarative MCP policy/config boundary (#52), host authority and pending-operation boundary (#53/#63/#64), generic durable effect substrate/hardening/migration (#78/#83/#85), and external-tool documentation refresh (#73) are complete. The PrologAgent product roadmap itself landed in #87.

GitHub Actions remains the authoritative executable gate. Do not encode a transient “latest CI run” result here as durable project state; preserve open CI-contract defects such as #46 until their acceptance criteria actually land.

## P0 — First real agentic RLM slice

- [x] Establish SWI-Prolog as the initial implementation target and document the portability boundary.
- [x] Add project/module skeleton and PlUnit test harness.
- [ ] Define `rlm_completion/4`, result terms, structured error/outcome terms, usage accounting, and trace events. *(Implemented broadly, but #44 and #45 keep the aggregate contract open.)*
- [x] Define provider-neutral model behavior in the production `prolog/rlm_chain*.pl` modules.
- [x] Implement one **real OpenAI-compatible provider** directly with SWI HTTP/JSON libraries; support configurable base URL so OpenAI-compatible local/router endpoints can work.
- [x] Keep fake/model test doubles under tests only for deterministic CI.
- [x] Represent input context outside the root model prompt using an opaque context handle.
- [x] Implement bounded context `peek`, `slice`, `search`, metadata, and partition operations.
- [x] Define a typed/allow-listed executable plan term language.
- [x] Implement `plan_validate/4` and reject undeclared operations before execution.
- [x] Implement the first model -> plan -> execute -> observation -> model loop.
- [x] Implement `llm_query/...` real subcalls.
- [x] Implement depth-1 `rlm_query/...`.
- [x] Implement at least one capability-gated local tool so the first loop is genuinely agentic.
- [x] Implement final-answer/result semantics.
- [x] Enforce iteration, recursion, inference-step, concurrent-call, wall-time, token, cost, tool-call, and output-byte budgets.
- [x] Add cancellation and deterministic cleanup.
- [ ] Persist or export a structured trajectory for every completion. *(Export exists; #45 keeps nested trajectory fidelity open.)*
- [ ] Add integration test gated on explicit provider credentials and deterministic tests using a fake provider. *(Both exist; #46 keeps the live streaming gate contract open until it is router-safe.)*

## P0 — Capability and execution boundary

- [x] Do not expose unrestricted `call/1` to model-produced plans.
- [x] Do not parse arbitrary model-generated source code as the default control path.
- [x] Define capability terms for context, model, recursive model, tools, graph actions, persistence, network, filesystem, process, and MCP access.
- [x] Make capability inheritance narrowing-by-default for child agents.
- [x] Separate pure context operations from side-effecting tools.
- [x] Deny shell/process execution by default.
- [x] Deny arbitrary filesystem/network access by default outside declared providers/tools.
- [ ] Add cycle/runaway recursion detection. *(Implemented, but #42 keeps the fingerprint/cycle contract open.)*
- [x] Add bounded output capture and structured exceptions.
- [ ] Add an optional stronger isolation boundary for workloads that truly require generated Prolog source.

## P1 — Runtime authority, async, and external effects

- [x] Add one bounded reusable Future/task substrate shared by latency-bearing runtime APIs.
- [x] Make completion/provider/chain, tool/MCP, agent, and graph core operations follow the canonical execute -> Future -> sync-await direction where migrated.
- [x] Add the four host-controlled authority tiers and non-blocking pending approval lifecycle from #53.
- [x] Add first-class MCP configuration references plus closed host-controlled installer/stdio execution policy from #52/#72.
- [x] Add the generic durable effect identity/observation substrate, hardening, and explicit legacy migration from #78/#83/#85.
- [ ] Finish async process/test/network tool support and downstream approval/TUI responsiveness. *(Tracked by #54 with concrete tool work in #49/#50.)*
- [ ] Route every in-scope canonical effectful tool/provider/MCP/process path through the durable effect boundary. *(Tracked by #79; PR #86 is open and therefore is not counted as merged adoption.)*

## P1 — `rlm_agent`

- [x] Add the production `prolog/rlm_agent.pl` runtime.
- [x] Define `agent_spec/..`, agent state, lifecycle, and structured outcomes.
- [x] Represent logical agents using engines/state machines rather than one OS thread per agent.
- [x] Define typed term messages: request/result/spawn/cancel/checkpoint/budget events.
- [x] Use bounded worker pools for blocking HTTP/tool work.
- [x] Add mailbox backpressure.
- [x] Add parent/child supervision and cancellation propagation.
- [x] Add capability inheritance and explicit delegation.
- [x] Add recursive subagents.
- [ ] Add critic/reviewer role support without hardcoding particular personas.
- [x] Add structured inspect/trace/repair loop for failed symbolic plans.

## P1 — Embedded `rlm_chain`

Reimplement the useful abstraction layer as embedded Prolog code under the production `prolog/rlm_chain*.pl` modules.

- [x] Audit current LangChain public semantics/licensing before copying implementation details.
- [x] Define message terms and role/content normalization.
- [x] Define model/provider behavior and capability predicates.
- [x] Implement prompt templates and variable binding.
- [x] Implement tool definitions, JSON schemas, invocation, and result normalization.
- [x] Implement structured-output parsing/validation.
- [x] Implement middleware/hooks around model/tool/agent calls.
- [x] Implement runnable/pipeline composition only where it adds value beyond ordinary predicates. *(Reviewed; the runtime deliberately keeps ordinary Prolog predicates instead of cloning a Runnable object hierarchy.)*
- [x] Implement retry/backoff policy.
- [x] Implement streaming event protocol.
- [x] Implement token usage and cost accounting.
- [x] Document interoperability conventions for ordinary Prolog applications.

## P1 — Embedded `rlm_graph`

Reimplement the useful durable orchestration semantics under the production `prolog/rlm_graph*.pl` modules.

- [x] Define graph state as explicit Prolog terms/dicts with validation predicates.
- [x] Define nodes as predicates over state transitions.
- [x] Define fixed and conditional edges.
- [x] Define reducers for concurrent/partial state updates.
- [x] Implement START/END semantics.
- [x] Implement graph compilation/validation.
- [x] Implement loops and bounded cycles.
- [x] Implement subgraphs.
- [x] Implement checkpointing and resumable durable execution.
- [x] Implement interrupts / human-in-the-loop continuation points.
- [x] Implement event streaming and state history inspection.
- [ ] Implement parallel branches where semantics permit it.
- [x] Implement cancellation propagation.
- [x] Add backend-neutral persistence interface.
- [x] Use `library(persistency)` only as an initial/local adapter, not as the permanent storage contract.

## P1 — Dual-version MCP runtime

The production `prolog/rlm_mcp*.pl` modules provide a canonical internal representation and separate protocol codecs.

### 2025-11-25 compatibility

- [x] Implement sessionful initialization using `initialize` and `notifications/initialized`.
- [x] Negotiate and persist the selected protocol version/capabilities for the session.
- [x] Support `MCP-Protocol-Version` on subsequent HTTP requests.
- [x] Support optional `MCP-Session-Id` lifecycle and reinitialization after session invalidation.
- [x] Implement tools/resources/prompts and other baseline surfaces needed by the agent runtime.
- [ ] Preserve support for sampling/elicitation only as protocol compatibility features; do not make Sampling the core model backend. *(Legacy sampling/roots compatibility data is modeled; elicitation coverage is not yet demonstrated as complete.)*

### 2026-07-28 compatibility

- [x] Implement stateless self-describing requests.
- [x] Implement `server/discover`.
- [x] Include required per-request protocol/client/capability metadata.
- [x] Implement `MCP-Protocol-Version` plus method/name routing headers where transport requires them.
- [x] Handle unsupported-version responses and retry with a mutually supported version.
- [ ] Model extensions independently from the core; add Tasks support after baseline tools/resources/prompts. *(Extension capability is isolated; Tasks support is not yet demonstrated.)*
- [ ] Treat deprecated Sampling/Roots/logging surfaces as compatibility-only where required. *(Sampling/Roots compatibility is modeled; full logging compatibility is not yet demonstrated.)*

### Shared compatibility layer

- [x] Define canonical internal terms for request/result/tool/resource/prompt/error/capabilities.
- [x] Isolate `2025-11-25` and `2026-07-28` encode/decode/lifecycle logic in version modules.
- [x] Prefer `2026-07-28` when explicitly supported; fallback to `2025-11-25`.
- [x] Add conformance fixtures for both versions.
- [x] Add client matrix tests against old-only, new-only, and dual-version servers.
- [x] Add server matrix tests against old-only, new-only, and dual-version clients.
- [x] Do not infer version from behavior when explicit negotiation/discovery can resolve it.
- [x] Record negotiated protocol version in every MCP trace event.

## P1 — RLM-specific Prolog strategies

- [ ] Compare text slicing with term-aware context decomposition.
- [ ] Explore DCGs for semi-structured long contexts.
- [ ] Explore tabling for repeated semantic subproblems.
- [ ] Explore constraints for decomposition/selection.
- [ ] Use backtracking as a bounded strategy generator, not uncontrolled recursion.
- [x] Test model-generated plans against a small symbolic combinator vocabulary inspired by lambda-RLM.
- [x] Preserve model-selected decomposition rather than hardcoding one MapReduce strategy.

## P1 — Adaptive recursion

- [x] Default to depth 1 until deeper recursion demonstrates value.
- [x] Define recursion policy separate from `max_depth`.
- [x] Record a reason/utility estimate for every recursive call.
- [ ] Add cost/latency-aware routing between direct LM, LM subcall, RLM subcall, and subagent. *(Cost-aware expected-value routing exists; an explicit latency-aware policy signal is still absent.)*
- [ ] Add recursion-cycle detection and duplicate-subproblem suppression. *(Implemented, but #42 keeps the cycle-fingerprint contract open.)*
- [x] Compare depth 0/1/2 under fixed budgets.
- [ ] Cancel low-value branches when budget pressure rises.

## P1 — Durable artifact context

- [x] Separate persistent task state/artifacts from transient model conversation history.
- [x] Allow fresh reasoning roots to load selected facts/summaries/artifacts instead of inherited full transcripts.
- [x] Add blackboard/artifact terms with provenance and versioning.
- [x] Add bounded context-pack construction from durable state.
- [x] Make checkpoints replayable without requiring model transcript replay.

## P1 — Evaluation

- [ ] Reproduce simple examples from the RLM reference implementation.
- [ ] Add fixtures for peeking/structural discovery, search narrowing, partition+map, summarization, and long transformations. *(Peek/search/partition/map/reduce fixtures exist; the full requested set is broader.)*
- [ ] Compare direct LM, agent-only, RLM-only, and agentic-RLM modes on equivalent tasks.
- [ ] Compare unrestricted-development prototype plans against typed-plan execution only in isolated tests.
- [ ] Measure accuracy, model calls, tokens, cost, latency, recursion depth, context bytes inspected, tool calls, plan rejections, and repair iterations. *(Most runtime metrics exist; plan-rejection and repair-iteration comparison is not yet complete as one benchmark contract.)*
- [ ] Add regression tests for context-rot and runaway-recursion failures. *(Runaway recursion has coverage; context-rot regression coverage is still outstanding.)*

## P2 — Developer experience

- [x] Add CLI and Prolog toplevel demo.
- [x] Add trace visualization/export.
- [x] Add examples for remote and local OpenAI-compatible models.
- [ ] Add MCP client/server examples for both supported protocol versions. *(Conformance tests and runtime docs exist; dedicated runnable old/new client/server examples are still missing.)*
- [x] Add package/module docs.
- [x] Add CI for formatting, static checks, unit tests, integration fixtures, and dual-version MCP conformance.
- [x] Add reproducible benchmark commands.
