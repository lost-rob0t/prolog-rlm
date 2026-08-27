# Recursive completion runtime

`rlm_completion` is the bounded supervisor that turns a query plus opaque context into a validated symbolic plan and executes that plan with the existing closed interpreter.

## Public predicates

```prolog
rlm_completion(+Query, +Context, +Options, -Outcome).
llm_query(+Prompt, +Options, -Outcome).
rlm_query(+Query, +SubContext, +Options, -Outcome).
rlm_cancellation_token(-Token).
rlm_cancel(+Token).
default_completion_budget(-Budget).
```

`Context` may be an existing `context_handle/2`, a `context_ref` dict, or a source accepted by the context runtime such as `text(String)` or `terms(List)`. Sources registered by `rlm_completion/4` are deleted during cleanup.

## Execution contract

The root planner receives the user goal plus context metadata/handle information, capability declarations, and **compiler-active tool schemas**. It does not receive the full opaque context implicitly. Its output must parse as the typed plan AST used by `rlm_plan`.

Tool possession and provider-visible tool schemas are deliberately separate. `rlm_completion` keeps the complete capability-filtered trusted runtime bindings for execution, authority, and effect mediation. Registry schemas are imported as inert declarative units into an ephemeral `rlm_prompt_compiler` catalog; the compiler decides which schemas are visible to the root planner. Hiding a schema does not unregister a tool, and exposing a schema does not grant capability or authority.

The trusted host option `prompt_compile_mode/1` controls this projection:

- `prompt_compile_mode(compiled)` is the default and exposes only compiler-active schemas after contextual selection and final packing;
- `prompt_compile_mode(all_tools)` preserves compatibility visibility while still going through the same prompt-compiler projection path;
- any other value fails closed as `completion_error{phase:prompt_compile,kind:invalid_prompt_compile_mode,...}` before planner dispatch.

The temporary compiler catalog is always destroyed during cleanup. Tool handlers/callables never enter prompt-compiler data.

The supervisor then:

1. parses the model-selected plan;
2. validates recursive depth, duplicate/cycle structure, and child capabilities;
3. counts planned model calls and tightens their generation ceilings against the remaining token budget;
4. executes context/model/tool operations through `rlm_plan`;
5. aggregates visible provider usage and checks model-call, token, and cost ceilings;
6. returns the final value, bindings, plan transitions, recursion statistics, and model trajectory.

There is no arbitrary model-generated `call/1` path and no fake-provider fallback in production execution.

## Recursion

`max_recursion_depth` is a hard safety ceiling, not a target. The default is `1`.

A root `rlm(...)` step creates depth 1. A child does **not** need the `rlm` capability merely to exist. It needs `rlm` only if its own plan tries to recurse again.

Child capabilities are derived with `capabilities_narrow/3`; they may be equal to or narrower than the root set and cannot widen authority. The supervisor validates every child plan against the narrowed set before execution.

Obvious repeated recursive subplans are fingerprinted and rejected. Recursive retry of a child plan is also rejected when it would repeat the same recursive work.

## Default budget

```prolog
completion_budget{
    max_iterations:32,
    max_recursion_depth:1,
    max_concurrent_subcalls:2,
    max_model_calls:4,
    max_tool_calls:4,
    max_context_ops:8,
    max_total_tokens:8192,
    max_cost_usd:0.25,
    max_output_bytes:32768,
    time_limit:30.0
}
```

The completion budget is projected into the plan runtime's step/depth/concurrency/model/tool/context/output/time limits. Planner calls consume the same completion-level model-call/token/cost envelope.

`completion_budget.time_limit` is an execution wall-time, not a Future waiter timeout. The `rlm_subagent` runtime may replace only this field after resolving an optional model `timeout_seconds` request against host-owned default and maximum policy. Every other host completion-budget field remains authoritative and is preserved. Model-facing tool arguments never become a general completion-budget mutation surface.

An enclosing parent completion may terminate before a longer child request. Until the generic runtime exposes a reliable remaining-parent-deadline API, `rlm_subagent` does not invent one locally or widen the enclosing lifetime.

Provider-reported token and cost usage is enforced when numeric metadata is available. A generation request is also tightened against the remaining token ceiling before execution. If a provider omits usage or cost metadata, the trajectory records that it is unknown rather than fabricating precision.

## Cancellation

Create a token and pass it to any completion/query call:

```prolog
rlm_cancellation_token(Token),
rlm_completion(Query, Context, [cancel_token(Token)], Outcome).
```

Another thread may call:

```prolog
rlm_cancel(Token).
```

Cancellation marks the token and signals currently registered execution threads so a pending model operation can be interrupted. `setup_call_cleanup/3` still runs cleanup paths before the public predicate returns a structured `completion_error{kind:cancelled,...}`.

## Direct completion

Recursion is optional. A planner may emit a direct plan ending in `final(...)`, and `llm_query/3` provides a bounded direct model call for callers that do not need decomposition.

## Live acceptance gate

Trusted same-repository CI exercises the complete P0 path with production OpenRouter calls:

```text
real root planner
  -> external opaque context slice
  -> registered project_read tool
  -> one rlm child
       -> real OpenRouter model call
       -> child final
  -> root final
```

The live log emits only non-secret evidence such as HTTP status, authorization result, recursion depth/count, model-call count, and fixture-token success. Planner JSON, model response text/reasoning, API keys, Authorization headers, and environment dumps are not intentionally logged.

## Reasoning controls

Completion callers may set `reasoning_effort(Effort)` using the closed effort
enum `none|minimal|low|medium|high|xhigh|max`. When present, the runtime sends
`reasoning:{effort:Effort}` on direct model requests and enforces the same host
selection on every model step in the validated symbolic plan, including nested
`rlm`, `parallel`, and `retry` plans. Model-produced request options cannot
downgrade or widen an explicit host-selected reasoning effort.

The root planner inherits `reasoning_effort/1` by default. A trusted caller may
set `planner_reasoning_effort(Effort)` to control the planner independently. If
no reasoning option is supplied, no reasoning field is added and legacy request
shape/behavior is preserved.

The CLI exposes the same contract as `--reasoning-effort` and
`--planner-reasoning-effort`.
