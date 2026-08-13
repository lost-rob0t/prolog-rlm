# Benchmark and conformance suite

The benchmark layer turns existing runtime traces into comparable, machine-readable cases. It does **not** add a parallel telemetry system.

## Commands

Deterministic conformance uses no paid APIs:

```sh
swipl -q -s benchmark/run.pl -- deterministic
```

Write the JSON report to a file:

```sh
swipl -q -s benchmark/run.pl -- deterministic benchmark-report.json
```

Optional real-provider integration requires `OPENROUTER_API_KEY`:

```sh
swipl -q -s benchmark/run.pl -- integration
```

`OPENROUTER_TEST_MODEL` continues to control the configured OpenRouter test model through the existing provider runtime.

The human summary is written to stderr. JSON is written to stdout unless an output path is supplied. Exit status is `0` for a passing report, `1` for a completed report containing failures, and `2` for invalid invocation or an integration setup error such as a missing credential.

## Canonical case schema

Each case is normalized as:

```prolog
benchmark_case{
    name:Name,
    category:Category,
    status:pass|fail|skipped,
    quality:Quality,
    metrics:benchmark_metrics{
        model_calls:ModelCalls,
        tool_calls:ToolCalls,
        context_ops:ContextOps,
        prompt_tokens:PromptTokens,
        completion_tokens:CompletionTokens,
        total_tokens:TotalTokens,
        cost_usd:CostUsd,
        latency_ms:LatencyMs,
        recursion_depth:RecursionDepth,
        context_bytes_inspected:ContextBytes,
        context_items_inspected:ContextItems
    },
    details:Details
}
```

Missing numeric metrics normalize to zero. Case details are canonicalized into JSON-safe values; compound Prolog terms become strings rather than leaking implementation-specific term encodings into the report.

## Report schema

A suite report contains:

- schema version;
- suite name and pass/fail status;
- pass/fail/skip counts;
- mean quality;
- metric totals;
- per-metric maxima;
- all normalized cases.

`benchmark_json/2` serializes the report. `benchmark_human_summary/2` produces the concise summary used by the CLI and CI logs.

## Deterministic cases

The deterministic suite currently runs 16 reportable cases across the production subsystems:

- opaque context: `peek`, `search`, `partition`, `map`, `reduce`;
- the same long-context reasoning task at direct/depth-0, RLM depth-1, and RLM depth-2 under the same call/token budget;
- malformed structured-plan rejection before model/tool execution;
- agent mailbox backpressure, parent-child cancellation, and 20 logical agents over a bounded worker pool;
- graph interrupt/checkpoint/resume with history verification;
- MCP 2025 adapter, MCP 2026 adapter, and version-neutral dual facade readiness.

The full PlUnit suite remains the detailed protocol/behavior matrix. In particular, the existing MCP tests cover command encoding/decoding, discovery/version mismatch, routing metadata, compatibility-cache behavior, and dual-version runtime boundaries. The benchmark suite adds cross-subsystem comparable output rather than duplicating those protocol tests.

## Direct vs RLM comparison

The deterministic comparison deliberately uses one ground task and one fixed budget:

```text
task: shared_long_context_reasoning
remaining_calls: 4
remaining_tokens: 8000
```

Depth 0 forces the direct route. Depth 1 forces an admitted recursive route. Depth 2 requires the same explicit experimental gates as the production recursion policy:

```prolog
allow_deep_recursion(true),
deep_recursion_capability(true)
```

The route handlers return measured-style execution metadata through the production recursion runtime, so the resulting cases exercise the same `actual_cost`, `usage`, identity, and depth trace contract used by real handlers.

These deterministic numbers are conformance fixtures, not claims about provider economics. The `integration` mode is the source of real provider latency/token/cost observations.

## Real-provider integration

`integration` performs an actual OpenRouter request through `rlm_chain:model_complete/3` and records:

- requested and selected model;
- HTTP success evidence;
- latency;
- prompt/completion/total tokens when OpenRouter reports them;
- provider-reported cost when available;
- whether any usable assistant output was returned;
- whether the requested benchmark token was actually produced.

Integration **status** and output **quality** are separate signals. This is deliberate because aliases such as `openrouter/free` may select different models and output channels between runs.

The case passes the integration-health gate when the provider returns usable assistant output in text, reasoning, or tool-call form. Quality is graded independently:

```text
1.0  expected benchmark token appears in text or reasoning
0.5  usable assistant output exists but the expected token is missing
0.0  no usable assistant output; integration case fails
```

This means a healthy provider/runtime path cannot become a flaky CI failure merely because a dynamically selected free model ignores the exact-token instruction. The miss is still preserved as benchmark evidence through `quality=0.5` and `details.quality.expected_token=false` rather than being hidden.

Provider usage fields that are legitimately absent are reported as zero in the numeric metric schema while `details.usage_present` preserves whether provider usage metadata was available.

## Fixed regression budgets

`benchmark_budget_check/3` supports these upper bounds:

```text
max_model_calls
max_tool_calls
max_context_ops
max_total_tokens
max_cost_usd
max_latency_ms
max_recursion_depth
max_context_bytes_inspected
```

A case may exceed more than one budget; every breach is returned in `regressions` rather than stopping at the first one.

The deterministic suite applies stable fixed budgets to context inspection and direct/RLM call-token-cost-depth cases. Wall-clock latency is measured everywhere but is not tightly gated in the deterministic CI fixture because shared GitHub runners make small latency thresholds noisy. The generic budget API and PlUnit tests cover latency-regression detection explicitly.

## CI

CI runs two independent deterministic gates:

```text
complete PlUnit suite
standalone benchmark/run.pl deterministic suite
```

The second gate is intentional: it verifies the CLI, report serialization, budget application, and exit status independently of PlUnit.

The REAL OpenRouter job runs the existing core and structured-repair suites plus `benchmark/run.pl integration`. With credentials available, CI therefore gates a machine-readable real-provider benchmark report containing latency, token usage, provider-reported cost, selected-model evidence, provider/runtime health, and instruction-quality evidence.
