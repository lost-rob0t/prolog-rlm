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

### CLI quickstart

A fresh checkout can run a real deterministic runtime walkthrough with **no credentials**:

```sh
swipl -q -s bin/prolog-rlm.pl -- demo
```

That command exercises opaque context operations, a capability-gated local tool, adaptive recursion, supervised agents, graph checkpoint/resume, and the dual-version MCP facade.

Inspect one subsystem:

```sh
swipl -q -s bin/prolog-rlm.pl -- demo recursion --view
swipl -q -s bin/prolog-rlm.pl -- graph --json
swipl -q -s bin/prolog-rlm.pl -- mcp --json
```

Legacy durable-effect journals are never upgraded implicitly. See
`docs/effect-migration.md` for the offline locked migration command, strict
adapter-binding manifest, backup/rollback workflow, and clone semantics.

With an OpenRouter credential, run a direct completion:

```sh
export OPENROUTER_API_KEY='...'

swipl -q -s bin/prolog-rlm.pl -- direct "Reply with DIRECT_OK"
```

Run a bounded **real depth-1 RLM** from one command:

```sh
swipl -q -s bin/prolog-rlm.pl -- rlm \
  "What token is in the external context?" \
  --context "The token is RLM_CONTEXT_42."
```

Export and inspect a portable trace outside the originating runtime process:

```sh
swipl -q -s bin/prolog-rlm.pl -- graph \
  --trace /tmp/graph.json

swipl -q -s bin/prolog-rlm.pl -- trace-view /tmp/graph.json
```

The same CLI supports JSONL traces and custom OpenAI-compatible endpoints. See:

- `docs/cli-demo-traces.md` for commands, provider configuration, budgets, capabilities, failures, and trace format;
- `docs/deep-recursion-experiments.md` for the explicit depth >1 experiment gate, shared-tree safety invariants, deterministic/live benchmark commands, and promotion rule;
- `docs/skills.md` for Prolog-owned skill discovery, automatic activation, budgets, dependency rules, and third-party skill loading;
- `examples/README.md` for reproducible direct, context, tool, recursion, graph, MCP, hosted-provider, and local-provider walkthroughs.

Controlled depth >1 experiments are available separately and remain opt-in:

```sh
swipl -q -s benchmark/run.pl -- deep-experiment
OPENROUTER_API_KEY='...' swipl -q -s benchmark/run.pl -- deep-integration
```

Requesting a recursion budget above depth 1 through the supported public facade also requires `experimental_deep_recursion(true)`. The flag does not grant capabilities or widen budgets.

The bootstrap also exposes the library API:

```prolog
?- use_module('prolog/rlm').
?- rlm:rlm_version(Version).
?- rlm:rlm_ready.
?- rlm:demo_all(Result).
```

Production namespaces live under `prolog/`:

- `rlm` — public runtime entrypoint and depth >1 opt-in boundary;
- `rlm_chain` — provider/model abstraction;
- `rlm_context` — bounded opaque external-context operations;
- `rlm_tool` — capability-gated local tool execution;
- `rlm_skill` — inert skill catalog, deterministic Prolog activation, dependency closure, prompt budgets, and safe resource loading;
- `rlm_skill_completion` — completion bridge that compiles selected skill instructions before planner execution;
- `rlm_completion` — model-to-plan-to-execution RLM loop;
- `rlm_recursion_policy` / `rlm_recursion_runtime` — bounded adaptive recursion selection and execution;
- `rlm_deep_experiment` — explicit depth 0/1/2 comparison, alternative recursive harnesses, and promotion evidence;
- `rlm_agent` — supervised logical agents;
- `rlm_graph` — durable graph execution;
- `rlm_mcp` — canonical MCP interoperability;
- `rlm_trace` — portable JSON/JSONL trace export and hierarchical viewing;
- `rlm_demo` — credential-free deterministic runtime demonstrations;
- `rlm_cli` — thin command facade over the production modules.

Deterministic model doubles live only under `test/support/`. They are test fixtures, not runtime backends.

GitHub Actions runs static module loading, PlUnit, deterministic benchmark/conformance, the deterministic depth >1 experiment, and the credential-free CLI smoke without network credentials. Real provider integration is a separate CI class; fake providers never count as live integration. The credentialed lane also executes the real depth 0/1/2 experiment and the one-command `rlm` CLI path against OpenRouter.

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

Instead it emits or selects from a small executable plan language whose operations are validated before execution. Executable forms include:

```prolog
context(HandleExpr, Action, Bind).
model(ProviderName, PromptExpr, RequestOptions, Bind).
rlm(SubPlan, Bind).
tool(ToolName, ArgsExpr, Bind).
parallel(SubPlans, Bind).
retry(Attempts, SubPlan, Bind).
checkpoint(Label).
final(ValueExpr).
```

The invariants are:

1. every executable operation has a declared capability;
2. plans are validated before execution;
3. recursion, concurrency, wall time, tokens, cost, inference steps, output bytes, and tool use are budgeted;
4. child agents inherit a narrowed capability set by default;
5. every execution produces a structured trace;
6. the runtime can cancel and clean up deterministically;
7. depth >1 is not enabled merely by increasing a numeric budget through the public facade.

## Runtime libraries

### `rlm_chain`

Provider-neutral model access, messages, prompts, structured output, streaming, retries, middleware, and usage accounting. Direct OpenAI-compatible HTTP providers are implemented here. Deterministic fakes remain test-only.

### `rlm_context`

Opaque context handles and bounded `peek`, `search`, `slice`, `partition`, `map`, and `reduce` operations with byte/item/time accounting.

### `rlm_skill`

A trusted skill-catalog and prompt-compilation boundary. `SKILL.md` frontmatter is indexed as inert metadata; Prolog scores request signals, applies trusted aliases/triggers, closes required dependencies, enforces negation/conflicts/count and token ceilings, and only then reads the selected instruction bodies and bounded local resources. The model receives the compiled instructions, never the full catalog or a skill-selection tool. Skill activation changes model-visible context only; it does not grant tool capabilities or authority.

### `rlm_completion`

The high-level RLM execution loop: root model planning, closed-plan validation, capability checks, bounded context/tool/model execution, recursive child calls, structured repair, usage aggregation, and trajectories. Skill compilation occurs before planner execution so injected or real providers observe only the Prolog-selected instruction set.

### `rlm_graph`

Explicit graph state, fixed/conditional edges, reducers, bounded loops, subgraphs, checkpoints, replay, interrupts, event streaming, and cancellation propagation.

### `rlm_agent`

Logical agents using SWI engines/state machines, bounded workers, typed mailboxes, supervision, cancellation, capability inheritance, recursive subagents, structured outcomes, and durable artifact access.

### `rlm_mcp`

MCP client/server interoperability behind one canonical internal representation. The compatibility targets are both `2025-11-25` and `2026-07-28`; version-specific behavior stays inside protocol adapters rather than leaking into agent/graph code.

### `rlm_trace`

Portable `prolog-rlm.trace.v1` JSON and JSONL export plus a minimal hierarchical viewer. Dicts/lists remain structured; Prolog compound terms use explicit `$term`/`args` encoding rather than opaque pretty-printed terms.

### `rlm_deep_experiment`

Controlled depth >1 evaluation over the existing runtimes. It compares nested typed-plan recursion, supervised delegated agents, and fresh-root durable-artifact handoff; proves global tree budgets/capability narrowing/cancellation behavior; records deterministic help/hurt/neutral classifications; and encodes a promotion rule that requires live evidence before deeper recursion can be considered for production.

## Core predicates

```prolog
rlm_completion(+Query, +Context, +Options, -Result).
llm_query(+Prompt, +Options, -Result).
rlm_query(+Query, +SubContext, +Options, -Result).
skill_catalog_load(+Roots, +Options, -Outcome).
skill_compile(+Catalog, +Input, +Options, -Outcome).
skill_prompt_fragment(+Compiled, -Prompt).
deep_experiment_run(+Options, -Outcome).
deep_experiment_promotion(+Evidence, -Decision).
agent_spawn(+Runtime, +Parent, +Spec, +Capabilities, -Outcome).
plan_validate(+Plan, +Capabilities, +Budget, -ValidatedPlan).
plan_execute(+ValidatedPlan, +RuntimeOptions, +Inputs, -Outcome).
context_peek(+Context, +Selector, +Options, -Outcome).
context_search(+Context, +Pattern, +Options, -Outcome).
context_partition(+Context, +Strategy, +Options, -Outcome).
trace_write(+Path, +Format, +Name, +Payload, -Outcome).
demo(+Name, -Result).
```

## Executable core milestone

The runnable core includes:

1. SWI-Prolog project/module skeleton and PlUnit tests;
2. a real provider-neutral model interface;
3. real OpenAI-compatible providers over SWI HTTP libraries;
4. opaque external context handles with bounded context operations;
5. a typed/allow-listed plan interpreter;
6. a real model -> plan -> execute -> model loop;
7. bounded recursive RLM execution;
8. capability-gated local tools;
9. structured outcomes, trajectories, and durable artifacts;
10. hard iteration, depth, concurrency, time, token/cost, and output budgets;
11. supervised logical agents and durable graph execution;
12. dual-version MCP interoperability;
13. deterministic benchmark/conformance plus live provider gates;
14. a CLI/demo/trace surface over the same production runtime;
15. controlled depth 0/1/2 experiments with explicit opt-in, alternative recursive harness comparisons, and non-automatic promotion criteria;
16. Prolog-owned automatic skill activation with lazy instruction loading, trusted dependency overlays, deterministic explanations, and bounded prompt cost.

Fake model providers are required **only for deterministic tests**.

## Research

`research/` contains durable numbered research records. See `research/README.md`.

Current records span `RLM-RESEARCH-000` through `RLM-RESEARCH-010` and cover RLM foundations, Prolog runtime design, agentic harnesses, typed symbolic execution, repair loops, SWI agent runtime, MCP dual-version interoperability, LangChain/LangGraph semantics, adaptive recursion, durable artifact context, and the symbolic prompt/capability compiler.

## Third-party skills

The default catalog includes a pinned, selected stable set from Matt Pocock's [`mattpocock/skills`](https://github.com/mattpocock/skills) collection. **Thanks to Matt Pocock for publishing the skill collection under the MIT License.** The upstream material is pinned at revision `9c9f36ccd3995266cd675468af71639c8dde1ec5`; its copyright and MIT license are preserved under `third_party/mattpocock-skills/`.

Vendored skill documents are kept byte-for-byte upstream. Runtime-specific relationships live in trusted Prolog overlay rules rather than edits to third-party Markdown. In particular, legacy instructions that tell a model to call a `Skill` tool are inert in `prolog-rlm`: Prolog owns skill activation and the model never receives a skill router. See `third_party/mattpocock-skills/UPSTREAM.md` and `docs/skills.md`.

## Non-goals

- no StarIntel dependency;
- no Python runtime requirement;
- no unrestricted model-generated `call/1`;
- no model-selected or model-loaded skill routing;
- no assumption that ordinary backtracking equals RLM recursion;
- no mandatory database backend;
- no wholesale source-copy port of LangChain/LangGraph;
- no MCP Sampling dependency for core model inference;
- no attempt to maximize recursive depth as a goal in itself.

## Status

The P1 executable core, adaptive recursion, benchmark/conformance, CLI/demo/trace surface, controlled depth >1 experiment harness, and Prolog-owned skill compiler are implemented. The generic durable effect identity/observation substrate is also merged and hardened, but canonical effectful provider/tool/MCP/process adoption remains incomplete under #79. The v0.1/manual-validation umbrella in #3 still has open correctness work in #42, #44, #45, and #46. Production recursion defaults to depth 1; deeper recursion remains explicitly experimental until the encoded live-evidence promotion rule is satisfied.
