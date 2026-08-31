# Direct native-tool runtime

## Decision

Direct mode is a bounded, non-symbolic model conversation. The model receives
capability-filtered native schemas, may request context or registered tools,
receives correlated bounded observations, and is called again until it returns
final text. It never has to emit a typed plan.

Typed-plan mode remains a separate execution strategy. Native calls and typed
plan operations converge on the same context adapters and registered-tool
executor; direct mode does not add another scheduler, authority system, effect
journal, capability model, or verifier.

The existing `rlm_completion/4` direct-answer envelope remains a compatibility
contract for the root direct-or-plan controller. It is not the native-tool
direct strategy described here. `llm_query/3` also remains unchanged: it makes
exactly one raw model request, does not expose or execute tools, and returns the
provider response as data.

## Public predicates

The direct strategy is exposed by `rlm_direct` and the `rlm` facade:

```prolog
rlm_direct(+Query, +Context, +Options, -Outcome).
rlm_direct_async(+Query, +Context, +Options, -Future).
rlm_direct_execute(+Query, +Context, +Options, -Outcome).
rlm_direct_model_step(+Context, +Capabilities, +Options, +Budget, +Token,
                      +Provider, +Prompt, +RequestOptions, +NativeBudget,
                      -Outcome).
```

`rlm_direct_async/4` submits the canonical `rlm_direct_execute/4` operation to
`rlm_async`. `rlm_direct/4` starts that same Future and awaits it. Code already
running in a bounded worker calls `rlm_direct_execute/4` directly.

`rlm_direct_model_step/10` is the trusted typed-plan model-step ABI. Host
runtimes bind it (module-qualified, with the already-acquired context handle,
capabilities, runtime options, remaining budget, and cancellation token) as the
`model_step_handler` of a typed-plan runtime. The plan runtime then calls it
with the step provider, prompt, request options, and native budget; it runs one
provider-native direct session through `rlm_direct_execute/4` and reports a
`native_model_execution{response,responses,iterations,model_calls,tool_calls,
context_calls,observation_bytes}`. It is never model-supplied data.

Provider-neutral native data is exposed by `rlm_native_tool`:

```prolog
native_tool_call_normalize(+WireCall, -Outcome).
native_tool_calls_normalize(+WireCalls, -Outcome).
native_tool_schema_normalize(+RuntimeSchema, -Outcome).
native_tool_schema_wire(+Format, +NativeSchema, -Outcome).
native_tool_result_message(+Call, +Result, -Outcome).
```

The only built-in wire format is `openai_compatible`. Unsupported formats fail
before provider dispatch. Hosts may provide other provider transports and
renderers in later additive modules without changing execution terms.

## Result and state contracts

A successful direct loop returns:

```prolog
ok(direct_result{
    value: Text,
    response: FinalModelResponse,
    responses: [ModelResponse, ...],
    usage: UsageSummary,
    turns: ModelTurnCount,
    iterations: ProviderTurnsAndNestedPlanSteps,
    context_calls: ContextCallCount,
    tool_calls: NonContextNativeCallCount,
    observation_bytes: ObservationBytesBeforeFinalText,
    output_bytes: ObservationAndFinalBytes,
    trajectory: [DirectEvent, ...]
})
```

`value` is exactly the final nonempty model text. `response` preserves the
canonical final provider response and `responses` preserves every provider
response of the session in chronological order, so nested typed-plan sessions
can account for all spent calls. Usage is the sum of every provider turn,
including turns that requested tools. Trajectory events preserve provider
response identity and each native call ID; registered-tool events additionally
retain canonical authority/effect trace data.

Terminal failure is:

```prolog
error(direct_error{
    phase: Phase,
    kind: Kind,
    message: Text,
    usage: UsageSummary,
    trajectory: Events,
    model_responses: [ModelResponse, ...],
    ...
})
```

When failure occurs before execution state exists, usage and trajectory are
zero/empty. Once state exists, failures retain all completed calls and admitted
effects. A pending approval is a structured terminal result for this call; the
direct worker never waits for a human.

Internal loop state is closed runtime data:

```prolog
direct_state{
    messages: Messages,
    seen_call_ids: CallIds,
    responses: [ModelResponse, ...],
    model_calls: N,
    context_calls: N,
    tool_calls: N,
    output_bytes: N,
    usage: UsageSummary,
    trajectory: Events
}
```

It contains no provider, registry, adapter, handler, or authority callable.
Those remain trusted execution configuration.

## Provider-neutral representations

A normalized request is:

```prolog
native_tool_call{
    id: CallIdString,
    name: ToolNameAtom,
    arguments: GroundJsonObject,
    type: function
}
```

Call IDs must be nonempty bounded protocol tokens. Calls must be ground and
acyclic. The function type, name, and arguments are mandatory. Arguments may
arrive as a JSON object or as JSON object text; arrays, scalars, malformed JSON,
unknown fields, duplicate IDs, and unsupported call types fail before any call
in that assistant batch executes. The canonical assistant message must contain
the exact same normalized call batch as the provider response envelope; a
mismatched continuation fails before execution.

A successful canonical observation is represented as:

```prolog
native_tool_result{
    call_id: CallIdString,
    name: ToolNameAtom,
    operation: context(peek|slice|search) | tool(ToolNameAtom)
             | spec(Operation) | plan(execute),
    value: ClosedValue,
    truncated: Boolean,
    trace: ClosedTrace
}
```

`native_tool_result_message/3` requires exact call/result ID and name equality,
encodes closed values as JSON-safe data, enforces the direct observation byte
limit at the caller, and emits:

```prolog
message{
    role: tool,
    tool_call_id: CallIdString,
    name: ToolNameAtom,
    content: JsonText
}
```

The original assistant message, including its provider call IDs, is appended
before these tool messages. The next request therefore uses the provider's own
correlation identity without treating it as capability, authority, durable
effect, or idempotency identity.

Registered-tool, Spec, and typed-plan results are retained as one-item opaque
contexts. Their immediate tool result contains a `native_context_ref` with a
stable per-call alias such as `result_call_123`, not the potentially large
value. The model uses native `context_peek`, `context_slice`, or
`context_search` to disclose a bounded projection. These derived contexts live
only for the enclosing direct call and are closed by the host on every terminal
path.

## Schema projection

The host supplies a context and capability set. Only these reserved context
tools can be projected, and only with the matching capability:

- `context_peek` for `context(peek)`;
- `context_slice` for `context(slice)`;
- `context_search` for `context(search)`.

There is no model schema for context close, delete, registration, adapter
registration, partition, map, or reduce in direct mode. Context handles are
host-owned and are not provider arguments.

Registered schemas follow the existing path:

```text
tool registry
-> prompt compiler selection under capabilities and context budget
-> inert native_tool_schema values
-> provider wire rendering
```

Executable bindings remain private in the original registry. Schema presence
does not grant capability or authority. A returned name must match an active
schema and is then independently checked again by `tool_invoke_execute/6`.
Reserved context names cannot be shadowed by registry tools.

The capability-gated reserved runtime catalog also contains:

- `spec_catalog` for `spec(catalog)`;
- `spec_normalize` for `spec(normalize)`;
- `spec_compile` for `spec(freeze)`;
- `spec_observe` for `spec(observe)`;
- `spec_verify` for `spec(verify)`;
- `typed_plan_execute` for `plan(execute)`.

These are standard provider function tools. `spec_compile` accepts closed SPEC
source text and composes normalize, trusted assertion-registry validation, and
freeze. Observe and Verify consume exact retained result contexts, so the model
cannot replace a Frozen Spec or observation with a similar-looking JSON value.
`typed_plan_execute` accepts one complete plan object and calls the existing
plan runtime with remaining shared budgets; model steps inside that plan run as
nested provider-native sessions through the shared `rlm_direct_model_step/10`
handler. Existing Prolog APIs remain the lower-level non-model interfaces.

Tool schemas already define execution contracts, so the model does not repeat
them as Spec requirements. Core cannot infer a task's desired outcome from a
tool argument/result schema. Hosts may register trusted Spec templates or
assertion mappings; the model then supplies only task-specific values or
selects a template, and Prolog still validates and freezes the result.

## Execution state machine

```text
prepare trusted provider/context/catalog
-> check cancellation and model/iteration/token/cost budget
-> send current messages plus native schemas
-> account provider usage immediately
-> strictly normalize the complete native-call batch
-> no calls: require nonempty final text and finish
-> calls:
     preflight all IDs, names, JSON argument envelopes, and batch budgets
     append canonical assistant message
     execute calls in provider order
       context call -> matching capability -> existing bounded context API
       registry call -> tool_invoke_execute/6
                      -> schema/capability/confinement
                      -> authority
                      -> durable effect boundary when non-read
        Spec call -> rlm_spec_lang or rlm_verify
        typed plan call -> rlm_plan with the remaining shared budget
                       (plan model steps re-enter this direct loop through
                        the trusted rlm_direct_model_step/10 handler)
     encode and bound each correlated observation
     append tool messages
     repeat
```

The loop is sequential. This gives deterministic observation ordering and does
not create one thread per tool call. A future parallel-call contract would need
an explicit shared-budget and partial-effect design.

## Budgets and cancellation

Direct mode uses `completion_budget`, including `max_model_calls`,
`max_tool_calls`, `max_context_ops`, `max_total_tokens`, `max_cost_usd`,
`max_output_bytes`, `max_iterations`, and `time_limit`.

- Every provider turn consumes one model call and its reported tokens/cost.
- Every provider turn and every nested typed-plan step consumes one shared
  iteration; a nested plan receives only the remaining iteration budget.
- A typed-plan model step runs as one nested direct session: the plan reserves
  one step and one model call, and the runtime then charges the session's
  actual continuation iterations, model calls, tool calls, context operations,
  observation bytes, and recorded provider responses against the same shared
  budget before binding the step result.
- Every non-context native operation consumes one tool call before dispatch.
- Every context invocation consumes one context operation before dispatch.
- Every provider-visible observation and the final text consume output bytes.
- The whole operation uses one wall-time scope and one completion cancellation
  token.

Budget admission happens before the relevant dispatch. Provider usage is
charged even when the returned call or final output is malformed. Cancellation
is checked before every provider and runtime operation; interruption after
durable external dispatch retains the canonical conservative effect outcome.

## Effects, replay, and failure

Registered tools always use the existing trusted invocation ABI. A non-read
tool therefore follows:

```text
schema -> capability -> confinement -> authority
-> durable effect admission -> durable dispatch -> adapter -> observation
```

Provider call IDs are correlation only. They cannot override store namespace,
execution epoch, logical-call identity, executable fingerprint, attempt
lineage, adapter identity, or provider idempotency key.

Duplicate call IDs are rejected across the entire conversation. If a provider
requests an already-admitted non-read operation under a fresh call ID, the
durable executor prevents resubmission; direct mode treats replay,
in-progress, reconciliation-required, or terminal effect state as a terminal
failure rather than interpreting it as retry permission. Fresh retry/resample
authority remains an explicit host operation outside the model loop.

## Native call batches: classification, isolation, and repair

The complete native batch returned by one provider response is normalized
first (closed JSON objects, bounded protocol tokens, unique call IDs).
Normalization failures are terminal for the run.

After normalization, the runtime performs one side-effect-free
classification pass that resolves every call against the trusted catalog
and validates its arguments, then evaluates batch-fatal invariants against
the ORIGINAL requested batch before anything executes:

```text
complete native batch normalized
-> one side-effect-free classification pass
-> batch-fatal invariants evaluated against original request
-> explicitly whitelisted per-call preflight/schema faults become
   repair observations
-> valid read siblings may execute
-> effectful multi-call requests remain entirely batch-fatal even when
   the effectful call itself has malformed arguments
```

Batch-fatal conditions (whole requested batch is rejected, nothing
executes, no repair observations are produced): duplicate call IDs
(within one batch or across turns), an effectful call anywhere in a
multi-call requested batch, exhausted context/tool budgets,
assistant-message integrity failures, unsupported formats, unclassified
faults, cancellation, and missing final text. Text accompanying malformed
calls never converts that response into a success.

Effect isolation is evaluated on the original request: every call that
resolves to a trusted binding retains that binding even when its argument
validation fails recoverably, so a malformed effectful call still counts
as a requested effectful operation. Per-call recovery can never shrink an
unsafe requested batch into a safe executable batch.

Only two per-call preflight/schema fault classes are explicitly
whitelisted as recoverable, keyed by fault phase and kind
(`recoverable_fault/2`): schema-phase `malformed_arguments` and
catalog-phase `unavailable_tool_schema`. Every other direct fault is
batch-fatal by default; a new fault becomes repairable only by an
explicit policy change. Each whitelisted fault becomes one bounded
repair observation carrying the original call ID, tool name, stable
fault kind, and bounded repair-relevant detail; observations are
returned in the original requested call order and the bounded loop
continues so the model can repair the rejected call on the next bounded
provider turn. Faulted calls are never charged as tool or context
operations, but observations and turns stay inside the output, model
call, and iteration budgets.

Recoverable does not mean executable, and visible does not mean
authorized: a malformed effectful call never executes and its handler
never runs; an unavailable call has no binding at all; repair
observations carry no binding, capability, authority, or handler data.
The loop still fails closed for capability or authority denial, invalid
confinement, oversized observations, cancellation, replayed effects, and
missing final text.

## Optional Spec composition

Spec verification remains an opt-in layer above execution:

```text
Frozen Spec
-> spec_strategy{mode:direct|typed_plan,...}
-> existing direct loop OR existing typed-plan outcome
-> refresh observation sources
-> Observe
-> Verify
-> bounded strategy repair when host policy permits
```

The strategy value is closed data bound to the exact Frozen Spec reference.
Trusted configuration owns the direct runner, plan runtime options, observation
adapters, verifier registry, repair policy, and limits. A repair can replace the
strategy payload, and may switch strategy only when host policy allows, but it
cannot mutate the Frozen Spec, widen capability or authority, replace trusted
verifiers, or turn failed verification into effect retry authority.

Lower-level direct, typed-plan, Observe-only, and Verify-only callers remain
independently usable. Provider transport does not know about Specs.

The additive strategy workflow is exposed by `rlm_spec_strategy`:

```prolog
spec_strategy_bind(+Frozen,+Mode,+Payload,+ProjectState,-Outcome).
spec_strategy_execute(+Frozen,+Strategy,+Config,+Context,-Outcome).
spec_strategy_workflow_compile(+Frozen,+AssertionRegistry,+Config,+Options,
                               -Outcome).
spec_strategy_workflow_run_async(+Workflow,+Options,-Future).
spec_strategy_workflow_run(+Workflow,+Options,-Outcome).
```

It preserves each branch's raw result inside `strategy_execution`; it does not
pretend a direct result and typed `execution_outcome` are the same type.

## Runtime-wide token and cache boundary

Native tools save model-output tokens because the model emits compact function
calls instead of regenerating complete plan/tool contracts as prose. They do
not make schemas free: Chat Completions providers still receive the selected
`tools` JSON on each request and may count it unless their prompt cache hits.

Direct and root completion reuse the same prompt compiler, and recursion or
delegation re-enters that root boundary. A direct loop compiles once: its schema
list and order are identical on every continuation, static identity,
instructions, and explicit skills precede dynamic task/context metadata, and
observations only append to the message suffix. Typed plans are an independent,
first-class execution strategy: their `tool`, `context`, `model`, and recursive
operations remain supported. The `model` operation runs through the same
provider-native session executor whenever the runtime supplies the canonical
`rlm_direct_model_step/10` handler — root completion and direct-mode
`typed_plan_execute` always do — while standalone `plan_run/5` without a
handler keeps the one-raw-call compatibility profile described in
`docs/typed-plans.md`. The native path is canonical, not legacy.

`rlm_direct` defaults to `prompt_compile_mode(compiled)`, matching root
completion. The canonical prompt compiler uses the current query, capability
set, and context budget to select provider-visible registered tool schemas and
skills. The selected bundle is compiled once per direct session and reused
unchanged for every continuation in that session. Callers may explicitly choose
`prompt_compile_mode(all_tools)` when a stable capability-filtered inventory is
known to be cheaper across a warm workload; it is a compatibility/cache profile,
not the normal contextual path.

Explicit direct skills remain trusted forced selections, while the real query
still participates in dependency and contextual activation. Identity and base
runtime instructions remain the stable leading messages; compiler-selected
skill context and the task follow them. Provider cache behavior remains
provider/model-specific, so hosts should compare provider-reported cache tokens
against total prompt tokens and cost rather than maximizing hit percentage in
isolation.

`test/rlm_direct_test.pl` recreates contextual compilation ten times for the
same query and requires deterministic native tools and skill messages. It also
changes the query and proves that relevant tools and skills can enter or leave
the direct projection. The CI-only
`test/live_compiler_cache_openrouter_test.pl` runs fifteen
fresh constructions under an explicit `all_tools` cache profile and requires a
majority of the fourteen warm requests (and at least five) to report cached
native tokens or a response-cache source; a churning prefix would collapse
the hit rate toward zero, while provider upstream routing may periodically
miss a warm cache. It is intentionally not a local paid test.

## Rejected alternatives

- Extending `llm_query/3` with hidden looping would break its one-call contract.
- Requiring direct mode to emit a typed plan would preserve the protocol
  mistake. A model may explicitly select native `typed_plan_execute`, but
  ordinary context and tool use never requires plan syntax.
- Executing calls in `rlm_openai_compatible` would mix transport with
  capabilities, authority, and host adapters.
- Adding a chain middleware executor would create a second authority-bearing
  tool path and make provider retry capable of replaying effects.
- Passing raw registry inventory to the provider would bypass compiler and
  capability selection.
- Waiting in a worker for approval would violate bounded scheduler ownership.
- Using provider call IDs as durable attempt IDs would trust remote/model data
  with runtime effect identity.

## Acceptance mapping

Deterministic tests cover strict normalization, capability-filtered schemas,
context retrieval, registered execution, exact result IDs, malformed/unknown
calls, duplicate IDs, output bounds, all call budgets, cancellation, authority
denial, replayed effects, missing final text, and unchanged typed plans.

Credentialed tests use randomized cold data and registered read tools. The
random UUID is absent from every pre-retrieval provider message, native calls
are required, and the final text must equal the runtime-generated expected
value. Effect crash/restart guarantees are exercised by the existing fresh
process tool-effect fixtures because direct mode enters that same canonical
boundary; no generic provider-level exactly-once claim is made.
