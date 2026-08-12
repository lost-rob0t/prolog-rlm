# prolog-rlm TODO

This backlog is intentionally broader than the first runnable RLM. Work should land in small, testable slices.

## P0 — Minimal RLM runtime

- [ ] Choose and document the initial Prolog implementation target and portability boundary.
- [ ] Define `rlm_completion/4`, result terms, error terms, usage accounting, and trace events.
- [ ] Implement a provider-neutral model client interface.
- [ ] Implement at least one model provider adapter without introducing a Python runtime dependency.
- [ ] Represent input context outside the root model prompt and expose it through an opaque context handle.
- [ ] Implement safe context operations: peek, slice, search, partition, map, reduce, and metadata inspection.
- [ ] Implement a controlled model-generated Prolog goal evaluator with an explicit allow-list.
- [ ] Implement `llm_query/...` sub-calls.
- [ ] Implement depth-1 `rlm_query/...` recursive calls.
- [ ] Support final-answer and final-variable/result semantics analogous to the reference RLM loop.
- [ ] Enforce maximum iterations, recursion depth, concurrent sub-calls, wall time, token usage, and monetary cost budgets.
- [ ] Add cancellation and deterministic cleanup.
- [ ] Persist a structured execution trace for every RLM completion.

## P0 — Safety and execution boundaries

- [ ] Do not expose unrestricted `call/1` to model-produced goals.
- [ ] Deny shell/process execution by default.
- [ ] Deny arbitrary filesystem and network access by default.
- [ ] Separate pure context-analysis predicates from side-effecting tools.
- [ ] Add explicit capability objects/terms for any side effects that are later enabled.
- [ ] Add recursion-cycle detection and runaway-subcall protection.
- [ ] Add bounded output capture for Prolog execution results.
- [ ] Define sandbox options for local development versus untrusted workloads.

## P1 — Embedded `rlm_chain` library

Port/reimplement the useful LangChain abstraction layer as embedded Prolog code under `library/rlm_chain/`.

- [ ] Audit current LangChain public APIs and licensing before copying any implementation details.
- [ ] Define message terms and role/content normalization.
- [ ] Define model/provider behavior and capability predicates.
- [ ] Implement prompt templates and variable binding.
- [ ] Implement tool definitions, schemas, invocation, and result normalization.
- [ ] Implement structured-output parsing/validation.
- [ ] Implement runnable/pipeline composition using Prolog predicates and terms.
- [ ] Implement retry/backoff policy.
- [ ] Implement streaming event protocol.
- [ ] Implement callbacks/hooks and tracing.
- [ ] Implement provider metadata, token usage, and cost accounting.
- [ ] Implement test doubles/fake models for deterministic tests.
- [ ] Document interoperability conventions for ordinary Prolog applications.

## P1 — Embedded `rlm_graph` library

Port/reimplement the useful LangGraph runtime concepts as embedded Prolog code under `library/rlm_graph/`.

- [ ] Audit current LangGraph public APIs and licensing.
- [ ] Define graph state as explicit Prolog terms/dicts with schemas or validation predicates.
- [ ] Define nodes as predicates over state transitions.
- [ ] Define fixed and conditional edges.
- [ ] Define reducers for concurrent/partial state updates.
- [ ] Implement START/END semantics.
- [ ] Implement graph compilation/validation.
- [ ] Implement loops and bounded cycles.
- [ ] Implement subgraphs.
- [ ] Implement checkpointing and resumable durable execution.
- [ ] Implement interrupts / human-in-the-loop continuation points.
- [ ] Implement event streaming.
- [ ] Implement graph execution traces and state-history inspection.
- [ ] Implement parallel branches where semantics permit it.
- [ ] Implement cancellation propagation.
- [ ] Add persistence adapters without making any one database mandatory.

## P1 — RLM-specific Prolog strategies

- [ ] Compare plain text slicing with term-aware context decomposition.
- [ ] Explore DCGs for parsing semi-structured long contexts before model sub-calls.
- [ ] Explore tabling for repeated semantic subproblems.
- [ ] Explore constraint solving for decomposition/selection problems.
- [ ] Explore backtracking as a controlled alternative-strategy generator, not as uncontrolled model recursion.
- [ ] Explore indexed dynamic predicates versus immutable context stores.
- [ ] Explore actor-style supervision for concurrent recursive calls where appropriate.
- [ ] Test adaptive partition strategies chosen by the root model.
- [ ] Test recursive depth > 1 only after depth-1 behavior is measurable and budget-safe.

## P1 — Evaluation

- [ ] Reproduce simple examples from the RLM reference implementation.
- [ ] Add fixtures for peeking and structural discovery.
- [ ] Add fixtures for keyword/regex-style narrowing.
- [ ] Add partition + map semantic-labeling tasks.
- [ ] Add summarization-over-partitions tasks.
- [ ] Add long-input/long-output deterministic transformation tasks.
- [ ] Compare direct LM calls against Prolog RLM calls on the same inputs.
- [ ] Compare RLM with and without recursive sub-calls.
- [ ] Measure accuracy, model calls, tokens, cost, latency, recursion depth, and context bytes inspected.
- [ ] Add regression tests for context-rot-like failures as practical fixtures become available.

## P2 — Developer experience

- [ ] Add a small CLI.
- [ ] Add a Prolog toplevel demo.
- [ ] Add trace visualization/export.
- [ ] Add examples for local models and API models.
- [ ] Add package/module documentation.
- [ ] Add CI for formatting, static checks, unit tests, and integration tests.
- [ ] Add reproducible benchmark commands.

## Research queue

Research records live under `research/` and should be updated before large architectural commitments.

- [ ] RLM execution-loop semantics and termination contracts.
- [ ] Prolog sandboxing and capability-safe meta-call design.
- [ ] LangChain abstraction inventory for a minimal Prolog-native subset.
- [ ] LangGraph state/reducer/checkpoint semantics for a Prolog-native subset.
- [ ] Concurrency model for parallel recursive calls.
- [ ] Persistent context-store options for inputs far larger than process memory.
- [ ] Training/evaluation implications of giving models a Prolog rather than Python environment.
