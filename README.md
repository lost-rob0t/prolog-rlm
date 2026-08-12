# prolog-rlm

A **Prolog-native language-model harness and agent runtime built around Recursive Language Models (RLMs)**.

This repository is not a StarIntel component. The goal is to implement RLM-style context computation, model/tool orchestration, durable agent state, and recursive subagents directly in SWI-Prolog. Python is not a runtime requirement.

## Project thesis

RLMs treat a potentially huge input context as an object in a programmable environment instead of stuffing the entire object into one prompt. A root model can inspect, search, partition, transform, and recursively query selected sub-contexts before returning a final result.

`prolog-rlm` extends that idea into a general agent harness:

> **The language model chooses semantic strategy; Prolog owns execution semantics.**

The model may propose plans, decomposition strategies, tool calls, recursive model calls, subagents, and graph transitions. Prolog validates those operations against capabilities and budgets, executes them, records structured traces, checkpoints durable state, and decides whether execution may continue.

Primary references:

- RLM overview: https://alexzhang13.github.io/blog/2025/rlm/
- RLM paper: https://arxiv.org/abs/2512.24601
- Reference implementation: https://github.com/alexzhang13/rlm
- Minimal implementation: https://github.com/alexzhang13/rlm-minimal
- Harnesses are Compositional Generalizers: https://alexzhang13.github.io/blog/2026/harness/
- lambda-RLM: https://arxiv.org/abs/2603.20105
- PrologMCP: https://arxiv.org/abs/2606.14935

## Executable bootstrap

The supported baseline is **SWI-Prolog 9.0 or newer**.

The production entrypoint is:

```prolog
:- use_module('prolog/rlm').
```

From a clean checkout, verify the runtime and module graph with:

```sh
swipl -q -s test/check_runtime.pl
swipl -q -s test/load_all.pl
```

Run deterministic tests with:

```sh
swipl -q -s test/run_tests.pl
```

The bootstrap exposes:

```prolog
?- use_module('prolog/rlm').
?- rlm:rlm_version(Version).
?- rlm:rlm_ready.
```

Production namespaces live under `prolog/`:

- `rlm` — public runtime entrypoint;
- `rlm_chain` — provider/model abstraction;
- `rlm_agent` — supervised logical agents;
- `rlm_graph` — durable graph execution;
- `rlm_mcp` — canonical MCP interoperability.

Deterministic model doubles live only under `test/support/`. They are test fixtures, not runtime backends.

GitHub Actions runs static module loading and PlUnit without network access or credentials. Real provider integration is a separate CI class added by the provider milestone; fake providers never count as live integration.

## Why Prolog?

Prolog is not just replacing the Python REPL syntax. It is the control substrate.

- contexts can be facts, terms, streams, files, indexes, or opaque handles;
- inspection and filtering are queries;
- recursive model calls map naturally to predicates;
- graph traversal, constraints, search, decomposition, and rule evaluation are native;
- backtracking can propose alternate strategies under explicit limits;
- meta-programming can expose a small capability-safe executable language;
- proof/execution traces can be represented as structured terms;
- SWI-Prolog engines and queues provide a native substrate for many logical agents without one OS thread per agent.

## Target architecture

```text
                        query + external context
                                  |
                                  v
                      +-----------------------+
                      | Prolog RLM supervisor |
                      +-----------+-----------+
                                  |
             +--------------------+--------------------+
             |                    |                    |
             v                    v                    v
       context runtime       agent runtime        graph runtime
       handles/search        engines/mailboxes    state/checkpoints
       slice/partition       capabilities         interrupts/replay
             |                    |                    |
             +--------------------+--------------------+
                                  |
                   validated symbolic plan/runtime
                                  |
               +------------------+------------------+
               |                  |                  |
               v                  v                  v
         model providers       MCP tools         local tools
         OpenAI-compatible    old + new MCP      capability gated
               |
               +--> llm_query/...
               +--> rlm_query/...      recursive, budgeted
               +--> spawn_agent/...    supervised, capability scoped
                                  |
                                  v
                       trace + durable artifacts
                                  |
                                  v
                              final result
```

## Bounded symbolic execution

The model must not receive unrestricted `call/1`, arbitrary shell execution, or an unbounded source-code execution primitive.

Instead it should emit or select from a small executable plan language whose operations can be validated before execution. Initial forms include concepts such as:

```prolog
context(search(Context, Query, Hits)).
context(partition(Hits, semantic, Parts)).
model(call(Model, Prompt, Result)).
rlm(call(Agent, SubContext, Query, Result)).
tool(call(Tool, Args, Result)).
spawn(AgentSpec, Child).
parallel(Goals).
retry(Policy, Goal).
checkpoint(Label).
final(Result).
```

The exact syntax is provisional. The invariants are not:

1. every executable operation has a declared capability;
2. plans are validated before execution;
3. recursion, concurrency, wall time, tokens, cost, inference steps, output bytes, and tool use are budgeted;
4. child agents inherit a narrowed capability set by default;
5. every execution produces a structured trace;
6. the runtime can cancel and clean up deterministically.

## Runtime libraries

### `rlm_chain`

Provider-neutral model access, messages, prompts, structured output, streaming, retries, middleware, and usage accounting. Direct OpenAI-compatible HTTP providers are implemented here. Deterministic fakes remain test-only.

### `rlm_graph`

Explicit graph state, fixed/conditional edges, reducers, bounded loops, subgraphs, checkpoints, replay, interrupts, event streaming, parallel branches, and cancellation propagation.

### `rlm_agent`

Logical agents using SWI engines/state machines, bounded workers, typed mailboxes, supervision, cancellation, capability inheritance, recursive subagents, structured outcomes, and durable artifact access.

### `rlm_mcp`

MCP client/server interoperability behind one canonical internal representation. The compatibility targets are both `2025-11-25` and `2026-07-28`; version-specific behavior stays inside protocol adapters rather than leaking into agent/graph code.

## Planned core predicates

Names are provisional:

```prolog
rlm_completion(+Query, +Context, +Options, -Result).
llm_query(+Prompt, +Options, -Result).
rlm_query(+Query, +SubContext, +Options, -Result).
agent_run(+AgentSpec, +Input, +Options, -Result).
plan_validate(+Plan, +Capabilities, +Budget, -ValidatedPlan).
plan_execute(+ValidatedPlan, +State0, -State, -Result).
context_peek(+Context, +Selector, -View).
context_search(+Context, +Pattern, -Matches).
context_partition(+Context, +Strategy, -Partitions).
```

## First executable milestone

The first runnable slice is **not** a fake agent. It includes:

1. SWI-Prolog project/module skeleton and PlUnit tests;
2. a real provider-neutral model interface;
3. at least one real OpenAI-compatible provider over SWI HTTP libraries;
4. one opaque external context handle with bounded peek/search/slice operations;
5. a typed/allow-listed plan interpreter;
6. a real model -> plan -> execute -> model loop;
7. depth-1 `rlm_query/...`;
8. one capability-gated local tool;
9. structured outcomes and trajectory tracing;
10. hard iteration, depth, concurrency, time, token/cost, and output budgets.

Fake model providers are required **only for deterministic tests**.

## Research

`research/` contains durable numbered research records. See `research/README.md`.

Current records span `RLM-RESEARCH-000` through `RLM-RESEARCH-009` and cover RLM foundations, Prolog runtime design, agentic harnesses, typed symbolic execution, repair loops, SWI agent runtime, MCP dual-version interoperability, LangChain/LangGraph semantics, adaptive recursion, and durable artifact context.

## Non-goals

- no StarIntel dependency;
- no Python runtime requirement;
- no unrestricted model-generated `call/1`;
- no assumption that ordinary backtracking equals RLM recursion;
- no mandatory database backend;
- no wholesale source-copy port of LangChain/LangGraph;
- no MCP Sampling dependency for core model inference;
- no attempt to maximize recursive depth as a goal in itself.

## Status

**Executable SWI-Prolog bootstrap in progress.** Follow epic #3 for dependency order and acceptance gates.
