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

## Planned direction: SPEC-seeded symbolic planning

Typed plans should not invent their own goal state. The canonical Frozen Spec
is the authority for desired state and acceptance requirements; planning uses
that spec as its seed.

The intended dependency direction is:

```text
requirements
    |
    v
SPEC source
    |
    v
canonical Frozen Spec / SpecRef
    |
    v
symbolic plan seed
    |
    v
planner / expert-system refinement
    |
    v
whole-plan validation
    |
    v
bounded execution
    |
    v
SPEC verification
```

The seed is not a second specification and is not automatically executable. It
is a typed planning skeleton derived from the Frozen Spec: required outcomes,
invariants that constrain execution, output contracts, known dependencies, and
other planning-relevant facts exposed by trusted providers. It may also contain
initial intents implied by those requirements.

The live planner may expand, decompose, reorder, retry, or replace execution
steps as observations arrive, but it remains bound to the same Frozen Spec. A
replan changes *how* the system attempts the task, not *what counts as done*.
Changing acceptance requirements requires a new Spec version rather than a plan
mutation.

This gives SPEC and PLAN deliberately different jobs:

- **SPEC** owns desired state, invariants, evidence requirements, and output
  contracts.
- **PLAN** owns the current execution strategy, dependencies, expert selection,
  retries, checkpoints, and next executable actions.
- **VERIFY** decides whether observed state satisfies the Frozen Spec.

A future API may expose this separation explicitly, for example:

```prolog
plan_seed_from_spec(+FrozenSpec, +PlanningContext, -Outcome).
plan_refine(+SeedPlan, +PlannerInput, -Outcome).
plan_validate_against_spec(+Plan, +FrozenSpec, +Capabilities, +Budget, -Outcome).
plan_replan(+FrozenSpec, +ExecutionState, +PlannerInput, -Outcome).
```

These predicates are design targets, not claims about the current public API.
The existing `plan_*` predicates above remain the implemented interface until a
runtime change lands separately.

### Symbolic control loop around the LLM

The model should be a bounded reasoning operator inside the runtime rather than
the authority for execution state.

```text
user/model intent
      |
      v
structured candidate intent / plan patch
      |
      v
symbolic planner + expert selection
      |
      v
constraint / capability / failure-path validation
      |
      v
bounded LLM, context, or tool operation
      |
      v
symbolic state transition
      |
      v
SPEC verification
```

The LLM remains useful where ambiguity and induction are useful: interpreting a
request, proposing decompositions, suggesting repairs, generating code or text,
and mapping observations into candidate structured facts. Symbolic machinery
handles the parts that should not depend on model memory or persuasion:

- dependency ordering and legal next actions;
- capability and authority checks;
- invariant enforcement;
- plan-state persistence across model calls;
- deterministic expert/tool routing where rules are sufficient;
- budget and recursion limits;
- rejection of known bad execution paths;
- verification against the Frozen Spec.

The planner therefore does not need to stuff the whole long-horizon task into
every model context. It can select the next ready intent from symbolic state,
compile only the relevant context and expert knowledge for that intent, ask the
model for a bounded contribution, then validate the result before updating the
plan state.

### Failure-path knowledge

Known failures can become executable planning constraints instead of passive
notes. A conceptual knowledge base might contain facts such as:

```prolog
known_failure(
    code_pattern(global_mutable_cache),
    context(concurrent_runtime),
    race_condition
).

reject(Candidate, Reason) :-
    candidate_property(Candidate, Property),
    candidate_context(Candidate, Context),
    known_failure(Property, Context, Reason).
```

A generated candidate that matches a proven bad path can be rejected before it
is executed. Repairs can then be proposed against the explicit rejection
reason rather than relying on the model to remember an earlier failure from
conversation history.

Embedding search may complement this mechanism when exact symbolic matching is
too narrow. Similar historical failures can be retrieved as candidate evidence,
but similarity alone should not become execution authority. A trusted rule,
validator, or explicit plan decision should determine whether the retrieved
failure actually constrains the current candidate.

This creates a useful learning path:

```text
execution failure
    -> durable failure artifact
    -> optional embedding retrieval for analogous failures
    -> candidate symbolic rule or constraint
    -> validation / approval
    -> durable planning knowledge
```

Over time, repeated model mistakes can therefore migrate out of prompt text and
into inspectable symbolic invariants.

### Plan authority and re-planning

A plan can be dynamic without becoming model-authoritative. The runtime should
be able to derive a relation such as `ready(Intent)` from persisted plan state
and dependencies, then ask the appropriate expert or model only for that bounded
intent.

Conceptually:

```prolog
ready(Intent) :-
    planned_intent(Intent),
    \+ completed(Intent),
    forall(depends(Intent, Dependency), completed(Dependency)).
```

The exact predicates and task representation remain an implementation choice,
but the authority boundary is not: the symbolic runtime owns the durable plan
state, while model output proposes typed updates that must pass validation.

This also preserves direct mode. A caller may still run a normal direct model
interaction when symbolic planning is unnecessary. Symbolic planning is an
available execution mode for tasks that benefit from durable state, dependency
reasoning, constrained expert selection, or long-horizon verification; it is
not a requirement that every model call become an agentic workflow.

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
