# CLI, demos, and portable traces

`prolog-rlm` now has a thin command-line facade over the same runtime modules used by the library and tests. The CLI does not own a separate provider, tool, agent, graph, or MCP implementation.

From the repository root, use:

```sh
swipl -q -s bin/prolog-rlm.pl -- help
```

The examples below use this full invocation so they work without installing a wrapper script.

## Zero-credential demo

A new checkout can exercise the production runtime without API credentials:

```sh
swipl -q -s bin/prolog-rlm.pl -- demo
```

`demo` runs six deterministic families:

- opaque external-context `peek` and `search`;
- capability-gated `project_read` tool invocation;
- adaptive recursion with measured execution metadata;
- supervised parent/child agents and cancellation propagation;
- graph interrupt, checkpoint, resume, and history;
- the version-neutral MCP facade over the 2025 and 2026 adapters.

Run one family:

```sh
swipl -q -s bin/prolog-rlm.pl -- demo context
swipl -q -s bin/prolog-rlm.pl -- demo tool
swipl -q -s bin/prolog-rlm.pl -- demo recursion
swipl -q -s bin/prolog-rlm.pl -- agent
swipl -q -s bin/prolog-rlm.pl -- graph
swipl -q -s bin/prolog-rlm.pl -- mcp
```

The same predicates are available interactively:

```prolog
?- use_module(prolog/rlm).
?- demo_all(Result).
?- demo_graph(Result).
?- demo_mcp(Result).
```

## Hosted direct completion

Set the normal OpenRouter credential:

```sh
export OPENROUTER_API_KEY='...'
```

Then run one direct provider request:

```sh
swipl -q -s bin/prolog-rlm.pl -- direct "Reply with DIRECT_OK"
```

The model defaults to `OPENROUTER_TEST_MODEL` when set and otherwise follows the existing runtime default. Select one explicitly with:

```sh
swipl -q -s bin/prolog-rlm.pl -- direct "Reply with DIRECT_OK" \
  --model openrouter/free
```

There is no fake-provider fallback. Provider errors produce a failed CLI session and nonzero exit status.

## One-command RLM completion

The `rlm` command executes a bounded real depth-1 RLM path rather than aliasing direct completion. Its CLI orchestration skeleton is constructed locally and then executed by the production `rlm_completion/4` runtime:

```text
trusted CLI plan
  -> opaque context slice
  -> recursive child plan
       -> real provider model call
       -> child final
  -> root final
```

This is intentionally different from asking a root model to reproduce a fixed JSON plan. The CLI already knows the operability skeleton, so spending provider tokens to echo it adds latency, cost, and nondeterminism without adding semantic value. The library-level `rlm_completion/4` API still supports model-selected root plans for applications that want dynamic strategy selection.

Production recursion is capped at depth 1 for this command. The runtime admits one context operation and one recursive child model call; the injected trusted planner is represented in completion accounting but consumes zero provider tokens and makes no network request.

Example with inline external context:

```sh
swipl -q -s bin/prolog-rlm.pl -- rlm \
  "What secret token is in the context?" \
  --context "The secret token is RLM_CONTEXT_42."
```

Example with a file:

```sh
swipl -q -s bin/prolog-rlm.pl -- rlm \
  "Summarize the supplied context." \
  --context-file ./notes.txt
```

Useful bounds:

```text
--context-bytes N
--max-tokens N
--max-cost USD
--time-limit SECONDS
```

These become runtime limits; they do not grant extra capabilities.

## Local OpenAI-compatible endpoints

Point direct or RLM commands at a local or self-hosted OpenAI-compatible chat-completions endpoint:

```sh
swipl -q -s bin/prolog-rlm.pl -- direct "hello" \
  --endpoint http://127.0.0.1:8000/v1/chat/completions \
  --model local-model \
  --no-credential
```

For an endpoint whose key is stored in an environment variable:

```sh
export LOCAL_LLM_KEY='...'

swipl -q -s bin/prolog-rlm.pl -- direct "hello" \
  --endpoint https://llm.example/v1/chat/completions \
  --model hosted-model \
  --credential-env LOCAL_LLM_KEY
```

A custom endpoint requires an explicit model name. This prevents accidentally sending an OpenRouter alias to an unrelated endpoint.

The same provider options work with `rlm`; only the recursive child inference is sent to that endpoint.

## Capabilities

The CLI preserves the runtime's authority boundaries.

The deterministic tool demo grants only:

```prolog
[tool(project_read)]
```

The RLM command grants the root:

```prolog
[rlm, context(slice), model(ProviderName)]
```

and narrows the recursive child to:

```prolog
[model(ProviderName)]
```

The model cannot widen these capabilities or turn arbitrary model text into `call/1`, shell execution, filesystem access, or another unrestricted evaluator.

Applications that need a different authority set should call the library APIs directly and pass explicit `capabilities(...)` and `child_capabilities(...)` options rather than using the opinionated CLI skeleton.

## JSON output

Any command can emit a portable trace envelope:

```sh
swipl -q -s bin/prolog-rlm.pl -- demo graph --json
```

The envelope schema is:

```json
{
  "schema": "prolog-rlm.trace.v1",
  "name": "demo(graph)",
  "generated_at": "...",
  "payload": {}
}
```

Lists and dicts remain structured. Prolog compound terms are represented explicitly:

```json
{
  "$term": "cancelled",
  "args": ["demo_complete"]
}
```

This is intentional: external consumers can inspect trajectories without parsing SWI-Prolog pretty-printed terms.

## Trace export

Export a JSON trace:

```sh
swipl -q -s bin/prolog-rlm.pl -- demo graph \
  --trace /tmp/graph-trace.json
```

Export JSONL:

```sh
swipl -q -s bin/prolog-rlm.pl -- demo agent \
  --trace /tmp/agent-trace.jsonl \
  --trace-format jsonl
```

For a top-level list payload, JSONL emits one sequence-numbered record per item. Other payloads emit one record.

Trace files do not serialize provider credentials or HTTP Authorization headers. They contain the structured result/trajectory terms already returned by the runtime.

## Minimal trajectory viewer

Inspect a trace without reconstructing the original SWI process:

```sh
swipl -q -s bin/prolog-rlm.pl -- trace-view /tmp/graph-trace.json
```

For JSONL:

```sh
swipl -q -s bin/prolog-rlm.pl -- trace-view /tmp/agent-trace.jsonl \
  --trace-format jsonl
```

You can also request a hierarchical view directly:

```sh
swipl -q -s bin/prolog-rlm.pl -- demo recursion --view
```

The viewer is deliberately minimal. The portable JSON/JSONL format is the visualization boundary for richer external tooling.

## Failure inspection

CLI process status is intentionally simple:

```text
0  command completed with status=pass
1  command ran but runtime/demo status=fail
2  invalid CLI request or command-level exception
```

For machine inspection, add `--json` or `--trace` and inspect structured `phase`, `kind`, `detail`, `trace`, usage, recursion, and trajectory fields supplied by the underlying subsystem.

Examples:

```sh
swipl -q -s bin/prolog-rlm.pl -- demo recursion --json
swipl -q -s bin/prolog-rlm.pl -- rlm "question" --context "data" \
  --trace /tmp/rlm.json
swipl -q -s bin/prolog-rlm.pl -- trace-view /tmp/rlm.json
```

A budget failure remains data. For example, the JSON envelope can contain `phase:"budget"`, `kind:"token_budget_exceeded"`, `used`, and `limit` without losing the provider/runtime evidence that led to the rejection.

## MCP interoperability

The deterministic MCP demo exercises the public version-neutral command model while confirming both supported adapters are loadable:

```sh
swipl -q -s bin/prolog-rlm.pl -- mcp --json
```

The detailed wire/conformance matrices remain in the existing MCP PlUnit suites. The CLI demo is an operability surface, not a second MCP implementation.
