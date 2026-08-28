# Typed symbolic plans

`rlm_plan` is the execution boundary between model-selected strategy and
runtime-authoritative execution. Typed plans are a first-class execution
strategy of this runtime, not a legacy or deprecated path.

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

## Model steps: native session path and compatibility fallback

A `model` step resolves its prompt to text and then runs on one of two paths.

### Canonical native session path

When the host runtime supplies a trusted `model_step_handler` runtime option,
the step is executed by that handler as one bounded provider-native session.
Root completion (`rlm_completion/4`) and direct-mode `typed_plan_execute` both
supply the canonical `rlm_direct_model_step/10` handler, so a typed-plan model
step gets exactly the same provider-native behavior as direct mode:

- canonical query-aware prompt/compiler selection: registered tool schemas and
  skills are projected for the step prompt, and the selected bundle is compiled
  once per session and reused unchanged for every continuation turn;
- provider-native `tools` and `tool_choice`, assistant `tool_calls`, and
  correlated `role:tool` messages with exact provider call-ID preservation;
- continuation turns after context or registered-tool observations (large tool
  results stay behind per-call opaque result contexts and re-enter
  `tool_invoke_execute/6`);
- complete response and usage accounting: the final response and every provider
  response are recorded into the plan result, and execution errors retain every
  completed response for accounting.

The plan runtime reserves one step and one model call for the step. After the
handler reports the native execution (`iterations`, `model_calls`,
`tool_calls`, `context_calls`, `observation_bytes`), the runtime charges
`iterations - 1` steps, `model_calls - 1` model calls, all native tool calls
and context operations, and the provider-facing observation bytes against the
shared plan budget atomically before binding the final response. Binding and
final-output byte accounting are unchanged.

The handler is a trusted, module-qualified host closure. It is runtime
configuration and is never carried in or constructed from model-controlled
data.

### Compatibility fallback

Standalone `plan_run/5` without a `model_step_handler` keeps its existing
one-call behavior: the step runs as a single raw provider call with the step's
own request options, no native schemas, and no continuation turns. This
fallback is a compatibility profile for host-level plan execution; the native
session path above is the canonical behavior for runtime-integrated typed
plans.

### Per-step request options

Per-step request options (for example `max_tokens` or `temperature`) are
preserved, capped by the remaining shared token budget. Model-supplied
`messages`, `tools`, `tool_choice`, and streaming controls are rejected before
provider dispatch: runtime-selected schemas and session messages remain
authoritative.

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
