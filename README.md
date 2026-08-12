# prolog-rlm

A **Prolog-native implementation of Recursive Language Models (RLMs)**.

This repository is not a StarIntel component. Its goal is to explore RLMs as a general inference/runtime architecture implemented in Prolog, using Prolog itself as the programmable environment in which a root language model can inspect context, transform it, and recursively invoke language models over selected sub-contexts.

RLMs were introduced by Alex L. Zhang et al. as an inference strategy where a language model treats a potentially huge input context as an object stored in a programmable environment rather than stuffing that entire context directly into the model prompt. The root model can peek at, search, partition, transform, and recursively query subsets of that context before producing a final result.

- RLM overview: https://alexzhang13.github.io/blog/2025/rlm/
- Reference implementation: https://github.com/alexzhang13/rlm
- Minimal implementation: https://github.com/alexzhang13/rlm-minimal

## Why Prolog?

The original RLM implementation uses a Python REPL. Prolog gives us a different and potentially very interesting execution substrate:

- context can be represented as facts, terms, streams, files, indexes, or opaque handles;
- inspection and filtering can be expressed as queries rather than ad-hoc prompt operations;
- recursive model calls map naturally to predicates;
- graph traversal, search, decomposition, and symbolic constraints are native operations;
- backtracking can represent alternative decomposition strategies;
- meta-programming can expose a controlled goal language to the model;
- inference traces can be persisted as structured terms instead of loose text logs.

The core bet is that an RLM does not require Python specifically. It requires a programmable environment that lets the model operate over context and recursively call models. Prolog can be that environment.

## Target Architecture

Conceptually:

```text
query + context
      |
      v
+-----------------------+
| Prolog RLM supervisor |
+-----------------------+
      |
      +--> root LM sees the query and context metadata/handles
      |
      +--> controlled Prolog goal execution
      |      - peek
      |      - search / grep
      |      - partition
      |      - map / reduce
      |      - transform
      |      - inspect structured terms
      |
      +--> llm_query/...
      |
      +--> rlm_query/...  (recursive, budgeted)
      |
      +--> trace + usage + provenance
      |
      v
 final answer
```

A first implementation should keep the RLM interface model-like: callers provide a query and context and receive a result, while the recursive decomposition remains internal to the runtime.

## Planned Core Predicates

Names are provisional, but the initial API should converge on something close to:

```prolog
rlm_completion(+Query, +Context, +Options, -Result).
llm_query(+Prompt, +Options, -Result).
rlm_query(+Query, +SubContext, +Options, -Result).
context_peek(+Context, +Selector, -View).
context_search(+Context, +Pattern, -Matches).
context_partition(+Context, +Strategy, -Partitions).
```

The runtime must enforce recursion depth, iteration, token/cost, wall-clock, concurrency, and environment-execution budgets rather than allowing unbounded model-controlled recursion.

## Embedded Prolog Agent Libraries

A major secondary goal is to build the framework pieces needed by `prolog-rlm` **inside this repository as Prolog libraries**, rather than requiring a Python LangChain/LangGraph process.

Planned libraries:

- `library/rlm_chain/` — Prolog-native model/provider abstractions, messages, tools, prompts, structured output, runnable composition, callbacks/tracing, retries, and streaming. This is the LangChain-equivalent layer.
- `library/rlm_graph/` — Prolog-native state graphs, nodes, edges, conditional transitions, reducers, checkpoints, interrupts, streaming events, subgraphs, and durable execution. This is the LangGraph-equivalent layer.

The intent is not to make Prolog call Python wrappers. The useful abstractions should exist as embedded Prolog code with a Prolog API. Any direct source port must receive a license/API compatibility review first; otherwise behavior should be reimplemented cleanly from public interfaces and documentation.

## Research

`research/` contains durable research records modeled after the useful research-record discipline in `starintel-auto-research`, but without StarIntel-specific naming or architecture.

Research notes should be numbered, source-backed, and explicit about:

- research question;
- evidence and citations;
- findings;
- implementation implications;
- rejected alternatives;
- open questions;
- acceptance tests or experiments needed to resolve them.

Start with:

- `research/RLM-RESEARCH-000-foundations.org`
- `research/RLM-RESEARCH-001-prolog-runtime-design.org`

## Roadmap

See [`TODO.md`](TODO.md) for the working backlog.

Initial milestones:

1. Define a minimal RLM execution contract in Prolog.
2. Implement provider-neutral `llm_query/...`.
3. Implement a bounded Prolog execution environment for model-produced goals.
4. Store large context outside the root model prompt and expose controlled inspection predicates.
5. Implement depth-1 recursive calls compatible with the basic RLM design.
6. Add tracing, usage accounting, cancellation, and hard budgets.
7. Add benchmarks for peeking, grep/search, partition+map, summarization, and long-output tasks.
8. Build embedded `rlm_chain` and `rlm_graph` libraries.
9. Explore deeper recursive RLM calls and Prolog-specific decomposition strategies.

## Non-goals

For the initial implementation:

- no StarIntel dependency;
- no requirement for Python at runtime;
- no attempt to clone every LangChain integration before the RLM core works;
- no unbounded `call/1`, shell execution, filesystem access, or network access from model-generated Prolog goals;
- no claim that ordinary Prolog backtracking alone is equivalent to RLM recursion.

## Status

**Research / architecture bootstrap.** The repository currently defines the direction and research backlog; the executable Prolog runtime is the next milestone.
