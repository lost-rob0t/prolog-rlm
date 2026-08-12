# Typed symbolic plans

`rlm_plan` is the execution boundary between model-selected strategy and
runtime-authoritative execution.

A model may propose a plan, but it does not receive unrestricted Prolog
execution. Plans are parsed into a closed AST, normalized, validated in full,
and only then executed against explicitly granted capabilities and host
registries.

## Public flow

```prolog
plan_parse(+ModelOutput, -Outcome).
plan_normalize(+PlanLike, -Outcome).
plan_validate(+Plan, +Capabilities, +Budget, -Outcome).
plan_execute(+ValidatedPlan, +RuntimeOptions, +Inputs, -Outcome).
plan_run(+PlanLike, +Capabilities, +RuntimeOptions, +Inputs, -Outcome).
```

`Outcome` is `ok(...)` or `error(plan_error{...})`.

## Closed AST

The initial executable forms are:

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

Expressions are also closed:

```prolog
literal(Value).
input(Name).
var(Name).
field(BaseExpr, Key).
list(Exprs).
object(KeyExprPairs).
```

No AST form maps model data to arbitrary `call/1`, `shell/1`, `consult/1`,
filesystem dereferencing, or another unrestricted evaluator.

## JSON model output

Model output may be a JSON object or text containing one JSON object. The
parser extracts JSON and decodes it with SWI-Prolog's JSON library. It never
falls back to `read_term/3` for model text.

Example:

```json
{
  "steps": [
    {
      "op": "context",
      "handle": {"ref": "input", "name": "context"},
      "action": {"type": "search", "pattern": "needle"},
      "bind": "hits"
    },
    {
      "op": "tool",
      "name": "count_items",
      "args": {"ref": "var", "name": "hits"},
      "bind": "count"
    },
    {
      "op": "final",
      "value": {"ref": "var", "name": "count"}
    }
  ]
}
```

## Whole-plan validation

Validation happens before execution and checks:

- every operation is in the closed vocabulary;
- `final/1` appears exactly once and is last;
- every referenced variable was previously bound;
- bindings are not reused;
- context selectors/transforms/reducers are allow-listed;
- required capabilities are a subset of granted capabilities;
- recursive, retry, and parallel subplans are validated recursively;
- the static worst-case estimate fits the plan budget.

A plan that fails validation produces no context/tool/model side effects.

Runtime preflight then verifies that every named provider and tool appearing
anywhere in the validated plan exists in the host registry before the first
step executes. This prevents a late unknown-tool failure from occurring after
an earlier context operation has already run.

## Capabilities

Capabilities are explicit terms such as:

```prolog
context(search).
context(slice).
model(openrouter).
tool(count_items).
rlm.
parallel.
retry.
checkpoint.
```

A tool name in the model AST is not executable by itself. The host must also
supply a trusted closure:

```prolog
tools([
    tool(count_items, my_tools:count_items)
]).
```

Only that host-supplied closure is invoked. Model output cannot provide or
construct the callable.

Providers use the same host-registry pattern:

```prolog
providers([
    provider_ref(openrouter, ProviderTerm)
]).
```

## Budgets

Default plan budget:

```prolog
plan_budget{
    max_steps:64,
    max_depth:4,
    max_parallel:8,
    max_model_calls:8,
    max_tool_calls:16,
    max_context_ops:32,
    max_output_bytes:65536,
    time_limit:10.0
}
```

A partial dict overlays these defaults, for example:

```prolog
_{max_depth:2, max_tool_calls:4}
```

Static validation estimates worst-case steps and operation counts. Retry
multiplies the nested estimate by its maximum attempts. Recursive and parallel
subplans increase depth. Runtime counters are shared across recursion, retry,
and parallel branches rather than reset for child plans.

`max_output_bytes` is also global to the execution. Values bound by operations
and final results consume it, preventing nested plans from bypassing an output
budget by returning data through intermediate variables.

## Traces and checkpoints

Successful execution returns a `plan_result{...}` containing structured
transitions, checkpoints, remaining budget, variables, and the final value.
Transitions record sequence, operation, binding name, and status, but not raw
provider credentials or request headers.

`checkpoint(Label)` is currently structured runtime state only; it is not an
implicit filesystem/database write.

## REAL OpenRouter integration

The live CI suite asks the real OpenRouter provider to produce a JSON typed
plan. That model-selected plan is parsed and then executed against an opaque
context handle and one host-supplied trusted tool. CI verifies context
execution, tool execution, final result, provider/model metadata, and HTTP 200.

The live path has no fake provider fallback. CI logs only allow-listed evidence
fields; it does not print the generated plan, response content, reasoning text,
API key, Authorization header, or environment dump.
