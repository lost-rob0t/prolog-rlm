# prolog-rlm TODO

This backlog is intentionally broader than the first runnable RLM. Work should land in small, testable slices.

## P0 — First real agentic RLM slice

- [ ] Establish SWI-Prolog as the initial implementation target and document the portability boundary.
- [ ] Add project/module skeleton and PlUnit test harness.
- [ ] Define `rlm_completion/4`, result terms, structured error/outcome terms, usage accounting, and trace events.
- [ ] Define provider-neutral model behavior in `library/rlm_chain/model.pl`.
- [ ] Implement one **real OpenAI-compatible provider** directly with SWI HTTP/JSON libraries; support configurable base URL so OpenAI-compatible local/router endpoints can work.
- [ ] Keep fake/model test doubles under tests only for deterministic CI.
- [ ] Represent input context outside the root model prompt using an opaque context handle.
- [ ] Implement bounded context `peek`, `slice`, `search`, metadata, and partition operations.
- [ ] Define a typed/allow-listed executable plan term language.
- [ ] Implement `plan_validate/4` and reject undeclared operations before execution.
- [ ] Implement the first model -> plan -> execute -> observation -> model loop.
- [ ] Implement `llm_query/...` real subcalls.
- [ ] Implement depth-1 `rlm_query/...`.
- [ ] Implement at least one capability-gated local tool so the first loop is genuinely agentic.
- [ ] Implement final-answer/result semantics.
- [ ] Enforce iteration, recursion, inference-step, concurrent-call, wall-time, token, cost, tool-call, and output-byte budgets.
- [ ] Add cancellation and deterministic cleanup.
- [ ] Persist or export a structured trajectory for every completion.
- [ ] Add integration test gated on explicit provider credentials and deterministic tests using a fake provider.

## P0 — Capability and execution boundary

- [ ] Do not expose unrestricted `call/1` to model-produced plans.
- [ ] Do not parse arbitrary model-generated source code as the default control path.
- [ ] Define capability terms for context, model, recursive model, tools, graph actions, persistence, network, filesystem, process, and MCP access.
- [ ] Make capability inheritance narrowing-by-default for child agents.
- [ ] Separate pure context operations from side-effecting tools.
- [ ] Deny shell/process execution by default.
- [ ] Deny arbitrary filesystem/network access by default outside declared providers/tools.
- [ ] Add cycle/runaway recursion detection.
- [ ] Add bounded output capture and structured exceptions.
- [ ] Add an optional stronger isolation boundary for workloads that truly require generated Prolog source.

## P1 — `rlm_agent`

- [ ] Add `library/rlm_agent/`.
- [ ] Define `agent_spec/..`, agent state, lifecycle, and structured outcomes.
- [ ] Represent logical agents using engines/state machines rather than one OS thread per agent.
- [ ] Define typed term messages: request/result/spawn/cancel/checkpoint/budget events.
- [ ] Use bounded worker pools for blocking HTTP/tool work.
- [ ] Add mailbox backpressure.
- [ ] Add parent/child supervision and cancellation propagation.
- [ ] Add capability inheritance and explicit delegation.
- [ ] Add recursive subagents.
- [ ] Add critic/reviewer role support without hardcoding particular personas.
- [ ] Add structured inspect/trace/repair loop for failed symbolic plans.

## P1 — Embedded `rlm_chain`

Reimplement the useful abstraction layer as embedded Prolog code under `library/rlm_chain/`.

- [ ] Audit current LangChain public semantics/licensing before copying implementation details.
- [ ] Define message terms and role/content normalization.
- [ ] Define model/provider behavior and capability predicates.
- [ ] Implement prompt templates and variable binding.
- [ ] Implement tool definitions, JSON schemas, invocation, and result normalization.
- [ ] Implement structured-output parsing/validation.
- [ ] Implement middleware/hooks around model/tool/agent calls.
- [ ] Implement runnable/pipeline composition only where it adds value beyond ordinary predicates.
- [ ] Implement retry/backoff policy.
- [ ] Implement streaming event protocol.
- [ ] Implement token usage and cost accounting.
- [ ] Document interoperability conventions for ordinary Prolog applications.

## P1 — Embedded `rlm_graph`

Reimplement the useful durable orchestration semantics under `library/rlm_graph/`.

- [ ] Define graph state as explicit Prolog terms/dicts with validation predicates.
- [ ] Define nodes as predicates over state transitions.
- [ ] Define fixed and conditional edges.
- [ ] Define reducers for concurrent/partial state updates.
- [ ] Implement START/END semantics.
- [ ] Implement graph compilation/validation.
- [ ] Implement loops and bounded cycles.
- [ ] Implement subgraphs.
- [ ] Implement checkpointing and resumable durable execution.
- [ ] Implement interrupts / human-in-the-loop continuation points.
- [ ] Implement event streaming and state history inspection.
- [ ] Implement parallel branches where semantics permit it.
- [ ] Implement cancellation propagation.
- [ ] Add backend-neutral persistence interface.
- [ ] Use `library(persistency)` only as an initial/local adapter, not as the permanent storage contract.

## P1 — Dual-version MCP runtime

Add `library/rlm_mcp/` with a canonical internal representation and separate protocol codecs.

### 2025-11-25 compatibility

- [ ] Implement sessionful initialization using `initialize` and `notifications/initialized`.
- [ ] Negotiate and persist the selected protocol version/capabilities for the session.
- [ ] Support `MCP-Protocol-Version` on subsequent HTTP requests.
- [ ] Support optional `MCP-Session-Id` lifecycle and reinitialization after session invalidation.
- [ ] Implement tools/resources/prompts and other baseline surfaces needed by the agent runtime.
- [ ] Preserve support for sampling/elicitation only as protocol compatibility features; do not make Sampling the core model backend.

### 2026-07-28 compatibility

- [ ] Implement stateless self-describing requests.
- [ ] Implement `server/discover`.
- [ ] Include required per-request protocol/client/capability metadata.
- [ ] Implement `MCP-Protocol-Version` plus method/name routing headers where transport requires them.
- [ ] Handle unsupported-version responses and retry with a mutually supported version.
- [ ] Model extensions independently from the core; add Tasks support after baseline tools/resources/prompts.
- [ ] Treat deprecated Sampling/Roots/logging surfaces as compatibility-only where required.

### Shared compatibility layer

- [ ] Define canonical internal terms for request/result/tool/resource/prompt/error/capabilities.
- [ ] Isolate `2025-11-25` and `2026-07-28` encode/decode/lifecycle logic in version modules.
- [ ] Prefer `2026-07-28` when explicitly supported; fallback to `2025-11-25`.
- [ ] Add conformance fixtures for both versions.
- [ ] Add client matrix tests against old-only, new-only, and dual-version servers.
- [ ] Add server matrix tests against old-only, new-only, and dual-version clients.
- [ ] Do not infer version from behavior when explicit negotiation/discovery can resolve it.
- [ ] Record negotiated protocol version in every MCP trace event.

## P1 — RLM-specific Prolog strategies

- [ ] Compare text slicing with term-aware context decomposition.
- [ ] Explore DCGs for semi-structured long contexts.
- [ ] Explore tabling for repeated semantic subproblems.
- [ ] Explore constraints for decomposition/selection.
- [ ] Use backtracking as a bounded strategy generator, not uncontrolled recursion.
- [ ] Test model-generated plans against a small symbolic combinator vocabulary inspired by lambda-RLM.
- [ ] Preserve model-selected decomposition rather than hardcoding one MapReduce strategy.

## P1 — Adaptive recursion

- [ ] Default to depth 1 until deeper recursion demonstrates value.
- [ ] Define recursion policy separate from `max_depth`.
- [ ] Record a reason/utility estimate for every recursive call.
- [ ] Add cost/latency-aware routing between direct LM, LM subcall, RLM subcall, and subagent.
- [ ] Add recursion-cycle detection and duplicate-subproblem suppression.
- [ ] Compare depth 0/1/2 under fixed budgets.
- [ ] Cancel low-value branches when budget pressure rises.

## P1 — Durable artifact context

- [ ] Separate persistent task state/artifacts from transient model conversation history.
- [ ] Allow fresh reasoning roots to load selected facts/summaries/artifacts instead of inherited full transcripts.
- [ ] Add blackboard/artifact terms with provenance and versioning.
- [ ] Add bounded context-pack construction from durable state.
- [ ] Make checkpoints replayable without requiring model transcript replay.

## P1 — Evaluation

- [ ] Reproduce simple examples from the RLM reference implementation.
- [ ] Add fixtures for peeking/structural discovery, search narrowing, partition+map, summarization, and long transformations.
- [ ] Compare direct LM, agent-only, RLM-only, and agentic-RLM modes.
- [ ] Compare unrestricted-development prototype plans against typed-plan execution only in isolated tests.
- [ ] Measure accuracy, model calls, tokens, cost, latency, recursion depth, context bytes inspected, tool calls, plan rejections, and repair iterations.
- [ ] Add regression tests for context-rot and runaway-recursion failures.

## P2 — Developer experience

- [ ] Add CLI and Prolog toplevel demo.
- [ ] Add trace visualization/export.
- [ ] Add examples for remote and local OpenAI-compatible models.
- [ ] Add MCP client/server examples for both supported protocol versions.
- [ ] Add package/module docs.
- [ ] Add CI for formatting, static checks, unit tests, integration fixtures, and dual-version MCP conformance.
- [ ] Add reproducible benchmark commands.
