# prolog-rlm

A **Prolog-native language-model harness and agent runtime built around Recursive Language Models (RLMs)**.

This repository is not a StarIntel component. The goal is to implement RLM-style context computation, model/tool orchestration, durable agent state, and recursive subagents directly in Prolog. Python is not a runtime requirement.

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

Instead it should emit or select from a small executable plan language whose operations can be validated before execution. Initial forms should include concepts such as:

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

## Core libraries

### `library/rlm_chain/`

A Prolog-native model/tool abstraction layer inspired by useful LangChain concepts:

- messages and prompts;
- provider-neutral model interface;
- direct OpenAI-compatible HTTP providers;
- structured output;
- tool schemas and invocation;
- middleware/hooks;
- streaming;
- retries/backoff;
- token/cost accounting;
- deterministic fake/test providers under tests only.

### `library/rlm_graph/`

A Prolog-native durable graph runtime inspired by useful LangGraph concepts:

- explicit graph state;
- nodes and fixed/conditional edges;
- reducers;
- loops and bounded cycles;
- subgraphs;
- checkpoints and replay;
- interrupts / human-in-the-loop continuation;
- event streaming;
- parallel branches;
- cancellation propagation;
- backend-neutral persistence.

### `library/rlm_agent/`

First-class agent runtime:

- logical agents represented by SWI-Prolog engines/state machines;
- bounded worker pools for blocking model/tool work;
- typed term messages and mailboxes;
- supervision and cancellation;
- capability inheritance;
- recursive subagents;
- structured outcomes and repair loops;
- blackboard/durable artifact access without carrying entire chat histories forward.

### `library/rlm_mcp/`

MCP interoperability as both client and server.

The initial compatibility target is **two protocol generations**:

- `2025-11-25` — sessionful lifecycle with `initialize` / `notifications/initialized`, negotiated protocol version/capabilities, and optional `MCP-Session-Id`;
- `2026-07-28` — stateless core, self-describing requests, `server/discover`, per-request protocol/client/capability metadata, and header-based routing.

Do not smear version checks through agent code. Both wire protocols must normalize into one internal Prolog representation such as:

```prolog
mcp_request(Method, Params, Meta).
mcp_result(Result, Meta).
mcp_tool(Name, Description, InputSchema, OutputSchema, Meta).
mcp_resource(Uri, Name, MimeType, Meta).
mcp_prompt(Name, Description, Arguments, Meta).
```

Protocol-specific modules encode/decode the canonical terms.

For maximum interoperability the client should prefer `2026-07-28` when explicitly supported, then negotiate/fallback to `2025-11-25`. A server should advertise/accept both when its transport permits it. MCP must not be the model-provider abstraction: model APIs remain direct provider integrations.

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

The first runnable slice is **not** a fake agent.

It must include:

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

Current records:

- `RLM-RESEARCH-000-foundations.org`
- `RLM-RESEARCH-001-prolog-runtime-design.org`
- `RLM-RESEARCH-002-agentic-harness.org`
- `RLM-RESEARCH-003-typed-symbolic-execution.org`
- `RLM-RESEARCH-004-prologmcp-repair-loop.org`
- `RLM-RESEARCH-005-swi-agent-runtime.org`
- `RLM-RESEARCH-006-mcp-dual-version-runtime.org`
- `RLM-RESEARCH-007-langchain-langgraph-port.org`
- `RLM-RESEARCH-008-adaptive-recursion.org`
- `RLM-RESEARCH-009-durable-artifact-context.org`

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

**Research and architecture bootstrap.** The next implementation slice is the real-provider typed-plan RLM loop described above.
