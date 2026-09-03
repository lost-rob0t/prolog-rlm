# Plan-Graph Executor Design (issue #288)

Status: design record for `prolog/rlm_plan_graph.pl` — the closed project-op
plan vocabulary and the plan dependency-graph executor. Research basis:
`research/RLM-RESEARCH-027-spec-plan-graph-executor.org` (revised Inference),
adversarial review `rage/288-review-research-report.md`, issue #288.

## 1. Scope and non-goals

**Scope.** One new sibling module `prolog/rlm_plan_graph.pl` (sibling like
`rlm_spec_workflow` composes `rlm_plan`) that owns:

1. a closed 12-op project vocabulary as inert data (`plan_graph_op/1` facts),
   parsed from model JSON or Prolog terms into a canonical graph dict;
2. whole-graph validation before any execution (structure, ids, dependencies,
   cycles, vocabulary, arg shapes, per-op capabilities, aggregate budget);
3. a ready-step dependency scheduler with structured failure/blocked
   propagation, aggregate budget feed-forward, and cancellation abort;
4. per-step desugaring into the existing `rlm_plan` closed AST —
   `rlm_plan` remains the ONLY step executor; no second plan interpreter, no
   second scheduler;
5. a normalized `symbol_ref`/`source_span` data contract plus a bounded
   resolver over host-supplied index facts, consumed by `locate/1` (and
   reusable by `diff/2`, `edit/2`);
6. async-first surface `plan_graph_run_async/4` + `plan_graph_run/5` +
   `plan_graph_cancel/1` following the AGENTS.md canonical execution
   direction; and deterministic PlUnit + contract-gate coverage
   (`scripts/plan_graph_contract_check.pl`).

**Non-goals.**

- **No new external-effect path.** `sync_remote/1`, `edit/2`, `create/2`,
  `delete/1`, `run/1` are externally effectful in real use; their expert
  handlers in real packs must admit/dispatch/observe through the durable
  `rlm_effect` boundary with trusted adapter/attempt identity. THIS slice
  ships pure host-closure handlers only (tests, fixtures); no expert pack and
  no new durable-effect wiring is added here.
- **No durable restart / cross-restart graph resume.** Graph state is
  in-memory; durability via `rlm_graph_persist` (without adopting node
  semantics) is a follow-up. `abandoned` is terminal, never retry
  authorization.
- **No new scheduler or second plan interpreter.** One `rlm_async_submit`;
  the ready-step loop runs inside that single worker calling `rlm_plan`
  execute ABIs directly; no per-step Futures, no nested Future waits.
- **No capability-grammar widening.** Per-op capability term is exactly
  `tool(Op)`; `delegate/2` requires `tool(spawn_agent)` and narrows child
  capabilities through the existing `rlm_tool:capabilities_narrow/3` / spawn
  path (#53 boundary untouched).
- **No Tree-sitter/semantic extraction** (owned by #96–#98); this slice only
  consumes host-supplied index facts.
- **No coding-agent tool catalog or product UX** (downstream `agentProlog`).

## 2. Module contract and internal terms

Module: `prolog/rlm_plan_graph.pl`, module name `rlm_plan_graph`.

### 2.1 Public exports (contract-gate list + async additions)

| Export | Role |
|---|---|
| `plan_graph_parse/2` | `plan_graph_parse(+TextOrTerm, -Outcome)`; `ok(Graph)` or `error(plan_graph_error{...})`; JSON or term input |
| `plan_graph_normalize/2` | `plan_graph_normalize(+Raw, -Outcome)`; canonicalizes JSON dict or term form onto the canonical graph dict |
| `plan_graph_validate/4` | `plan_graph_validate(+Graph, +Capabilities, +Budget, -Outcome)`; whole-graph validation before any execution (mirrors `plan_validate/4` arg order) |
| `plan_graph_ready/3` | `plan_graph_ready(+Graph, +State, ?StepId)`; succeeds exactly for pending steps whose `requires` are all `completed` |
| `plan_graph_execute/5` | `plan_graph_execute(+ValidatedGraph, +Capabilities, +Options, +Inputs, -Outcome)`; worker entry; runs the ready-step loop |
| `plan_graph_run/5` | `plan_graph_run(+GraphInput, +Capabilities, +Options, +Inputs, -Outcome)`; validate -> async submit -> await the same Future |
| `plan_graph_run_async/4` | `plan_graph_run_async(+GraphInput, +Capabilities, +Options, -Future)`; ONE `rlm_async_submit` (add to gate) |
| `plan_graph_cancel/1` | `plan_graph_cancel(+Token)`; cancellation token mirror of `rlm_graph:graph_cancel/1` (add to gate later — noted in §12) |
| `default_plan_graph_budget/1` | aggregate graph budget dict (§7) |
| `plan_graph_resolve_symbol/3` | `plan_graph_resolve_symbol(+Index, +SymbolRef, -Outcome)` (§9) |
| `plan_graph_symbol_ref_valid/1` | structural validation of `symbol_ref{}` (§9) |
| `plan_graph_source_span_valid/1` | structural validation of `source_span{}` (§9) |
| `plan_graph_op/1` | dynamic fact `plan_graph_op(Name/Arity)` enumerating EXACTLY the closed 12-op set (checked for exact set equality by the gate) |

Source must contain the gate strings `'plan_capability_required'`,
`'experts'`, `'preflight'` (source mentions in
`scripts/plan_graph_contract_check.pl`). The gate's `no_call_escape` probes
require that `plan_graph_eval/1`, `plan_graph_call/1`, `plan_graph_shell/1`
never exist: model data is never a goal.

### 2.2 Internal terms

Canonical internal dict (single representation; JSON and term inputs normalize
onto it):

```prolog
plan_graph{steps: [graph_step{}], edges: [graph_edge{}]}
graph_step{id:Atom, op:Name/Arity, args:ClosedTerm, bind:Atom, requires:[Atom]}
graph_edge{step:Atom, requires:[Atom]}     % derived from depends_on, kept in sync
graph_state{status:_{StepId:StatusAtom},   % per-step status (§6)
            results:_{StepId:step_result{}},
            sequence:[StepId]}             % completion order
step_result{step:Atom, status:StatusAtom, outcome:PlanResultOrError}
```

- `graph_step.requires` is authoritative; `edges` mirrors it and
  `plan_graph_validate` checks the two are consistent (normalize populates
  both from `depends_on`).
- `args` is a closed ground term per §3; never a goal, never `call/1`-able.
- `graph_state` is owned by the worker thread; it is returned inside the
  structured outcome and is not persisted in this slice.

## 3. Closed op vocabulary

Declared as `plan_graph_op(Name/Arity)` facts; the gate asserts the fact set
is EXACTLY this list (no more, no fewer). Arg shapes are closed ground terms;
model JSON maps onto them mechanically (§4).

| Op | Arity | Arg shape (closed terms) | `symbol_ref`/`source_span` | Capability | Effect class | Desugar note |
|---|---|---|---|---|---|---|
| `sync_remote/1` | 1 | `sync_remote(op(Atom))` — names a host-registered remote operation | — | `tool(sync_remote)` | external | pure host closure this slice |
| `index/1` | 1 | `index(scope(Scope))`, `Scope ∈ {all, path(Atom)}` | — | `tool(index)` | observation | — |
| `search/2` | 2 | `search(Pattern, Scope)`, `Pattern` atom, `Scope` as above | — | `tool(search)` | observation | — |
| `locate/1` | 1 | `locate(symbol_ref(SymbolRef))` | consumes `symbol_ref` | `tool(locate)` | observation | resolver binds `ok(binding{span, provenance})` into `StepBind` (§9) |
| `read/1` | 1 | `read(Source)`, `Source ∈ {path(Atom)}` | — | `tool(read)` | observation | — |
| `diff/2` | 2 | `diff(Left, Right)`, each side `∈ {path(Atom), ref(SymbolRef), span(SourceSpan)}` | both targets | `tool(diff)` | observation | — |
| `edit/2` | 2 | `edit(Target, Replacement)`, `Target ∈ {path(Atom), ref(SymbolRef), span(SourceSpan)}`, `Replacement` atom | target | `tool(edit)` | external | pure closure this slice |
| `create/2` | 2 | `create(path(Atom), literal(Atom))` | — | `tool(create)` | external | pure closure this slice |
| `delete/1` | 1 | `delete(path(Atom))` | — | `tool(delete)` | external | pure closure this slice |
| `run/1` | 1 | `run(command(Atom))` | — | `tool(run)` | external | pure closure this slice; real packs route through `rlm_effect` |
| `validate/1` | 1 | `validate(spec(fingerprint(Atom)))` — frozen Spec fingerprint | — | `tool(validate)` | orchestration | expert closure calls `spec_observe_execute/5` (§8) |
| `delegate/2` | 2 | `delegate(task(Atom), caps([CapTerm...]))` | — | `tool(spawn_agent)` | orchestration | desugars through `tool(spawn_agent, ...)`; `caps` validated as narrowing subset (§5 step 7) |

Notes:

- The required capability for op `Op` is exactly `tool(Op)` — inside the
  closed `capability_shape/1` grammar (`rlm_tool.pl:127-140`);
  `plan_op(...)` is invalid today (review D3, empirically Q4a). For
  `delegate/2` the required term is `tool(spawn_agent)` (existing precedent).
- Effect classification is explicit (review D6): `sync_remote/1`, `edit/2`,
  `create/2`, `delete/1`, `run/1` are externally effectful in real use and
  their real expert packs must route through the durable `rlm_effect`
  boundary (normalize -> schema/capability/policy -> authority -> durable
  admission -> dispatch -> observe-or-indeterminate), with adapter identity,
  attempt lineage, and expert closure identity as trusted runtime data.
  Shipped handlers in this slice are pure host closures, so no new
  external-effect path exists in this slice.
- Symbol refs/spans appear only as inert data inside `args` terms; they are
  never resolved by `rlm_plan` and never touch the filesystem or a parser in
  this layer (extraction remains #96–#98).

## 4. Model-facing JSON schema and canonical form

Model-facing JSON (snake_case, parity with `docs/typed-plans.md`):

```json
{
  "steps": [
    {"id": "s1", "op": "index",   "args": {"scope": "all"},  "bind": "idx"},
    {"id": "s2", "op": "locate",  "args": {"symbol": {"name": "foo", "kind": "function", "occurrence": "definition"}}, "bind": "span"},
    {"id": "s3", "op": "delegate", "args": {"task": "subtask", "caps": ["tool(read)"]}, "bind": "child"}
  ],
  "depends_on": [
    {"step": "s2", "requires": ["s1"]}
  ]
}
```

- `"steps"`: objects with exactly `id`, `op`, `args`, `bind` keys.
  `id`/`op`/`bind` are strings mapped to atoms; `args` is an object decoded
  per the §3 arg-shape table (fixed key set per op; unknown keys rejected).
- `"depends_on"`: objects with exactly `step`, `requires` (list of step ids).
  A step may omit an entry (no dependencies). `"requires":[]` is equivalent
  to no entry.
- **symbol_ref JSON**: `{"name":"foo","kind":"function","arity":2,
  "owner":"mod","occurrence":"definition"}` — `arity`/`owner` optional;
  `occurrence` one of `"definition" | "reference" | "any"` (default `"any"`).
- **source_span JSON**: `{"file":"src/x.py","start_byte":10,"end_byte":20}`.

Prolog term form (host-authored plans and tests):

```prolog
plan_graph(steps([step(s1, index, scope(all), idx),
                  step(s2, locate, symbol_ref(symbol_ref{name:foo, kind:function}), span))],
           depends_on([depends_on(s2, [s1])]))
```

**Canonical internal dict**: `plan_graph{steps:[graph_step{}], edges:[graph_edge{}]}` (§2.2). Both input forms normalize (`plan_graph_normalize/2`) onto the same dict; `graph_step.op` is stored as `Name/Arity` so arity is part of the closed-vocabulary check.

Mapping rules (reuse of `rlm_plan` JSON discipline):

- Extract the single JSON object from model text and decode with SWI's JSON
  library; **never** `read_term/3` on model text (typed-plans convention).
  Fenced code blocks are tolerated like `plan_parse` does.
- `args` decodes through per-op decoders only: each op's arg-shape table (§3)
  names its JSON keys and closed-term constructor; anything outside the key
  set or the closed value domain is a `phase:normalize,
  kind:invalid_args` error. Scalars are atoms/numbers/booleans; nested
  objects are only the documented `symbol_ref`/`source_span`/`ref`/`span`
  wrappers. No model text is ever passed to `read_term/3` or `call/1`.
- Step ids and bind names must be atoms after decoding; duplicate binds are
  rejected at validation (§5 step 2) so two steps cannot race the same
  binding.

## 5. Validation algorithm

`plan_graph_validate(+Graph, +Capabilities, +Budget, -Outcome)` returns
`ok(validated_plan_graph{graph, capabilities, budget, estimates})` or
`error(plan_graph_error{phase, kind, detail})`. Errors use the exact shape
`error(plan_graph_error{phase, kind, detail})` (sibling of
`error(plan_error{phase, kind, detail})`; see `docs/typed-plans.md`). Order
is fixed; first fault wins; **validation completes before ANY step executes**
(`plan_graph_execute` rejects unvalidated input fail-closed).

1. **Structure** (`phase:structure`, `kind:invalid_graph`): ground dict with
   non-empty `steps`; every `graph_step` has the five fields with correct
   types; `edges` consistent with per-step `requires`.
2. **Ids/binds** (`phase:structure`, `kind:duplicate_step_id` /
   `kind:duplicate_bind`): step ids unique; bind atoms unique across steps.
3. **Unknown dependency** (`phase:structure`, `kind:unknown_dependency`,
   `detail:dependency(StepId, Missing)`): every `requires` entry names an
   existing step.
4. **Cycle** (`phase:structure`, `kind:cycle`, `detail:cycle([Ids...])`):
   DFS three-color check; the detected cycle path is reported in `detail`.
   Self-dependency is a cycle.
5. **Vocabulary before desugar** (`phase:vocabulary`, `kind:unknown_op`,
   `detail:op(Name/Arity)`): every `step.op` must be a `plan_graph_op/1`
   fact. This ordering is normative: a model can never name a host-registered
   tool outside the 12-op vocabulary because desugaring happens only after
   this check (review D7; source mentions `plan_capability_required`).
6. **Per-op arg shapes** (`phase:validate`, `kind:invalid_args`,
   `detail:arg(StepId, Fault)`): per-op closed-term shape per §3, including
   structural `symbol_ref`/`source_span` validation via
   `plan_graph_symbol_ref_valid/1` / `plan_graph_source_span_valid/1`
   (§9): atoms where atoms are required, non-negative ints, `start_byte =<
   end_byte`, `occurrence` in the closed set, no unknown dict keys, fully
   ground.
7. **Capability subset** (`phase:capability`, `kind:capability_denied`,
   `detail:op(Op, required:tool(Required))`): per op, required = `[tool(Op)]`
   (`[tool(spawn_agent)]` for `delegate`); require `capabilities_narrow(Caps,
   [Required], _)` — the closed grammar rejects widening (Q4c), so a graph
   can never demand more than the caller holds. For `delegate/2`, child caps
   from `delegate(task(_), caps(Cs))` must themselves satisfy
   `capability_shape/1` and be a narrowing subset of the graph capabilities
   (checked at validation; the spawn path re-checks).
8. **Aggregate budget estimate** (`phase:budget`, `kind:budget_exceeded`,
   `detail:budget(Name, Estimated, Limit)`): step count vs `max_steps`;
   per-op cost estimates (1 tool call each; `validate/1` may add model calls;
   `delegate/2` adds child estimates) summed vs the aggregate budget of §7.
   An estimate exceeding any aggregate class fails here, before execution.

Vocabulary (step 5) runs before arg-shape (6) and both before capability (7)
and any desugaring: model data can never name — let alone reach — a tool
outside the closed set.

## 6. Scheduling state machine

Per-step statuses: `pending`, `ready`, `running`, `completed`, `failed`,
`blocked`, `abandoned`.

- `pending` — admitted to the state machine, dependencies not yet all
  completed.
- `ready` — `pending` AND all `requires` completed. This is exactly the
  `plan_graph_ready(+Graph, +State, ?StepId)` semantics: it succeeds
  precisely for such steps (multi-solution enumeration in normalized input
  order).
- `running` — admitted by the loop, desugared plan executing.
- `completed` — step outcome `status:ok`; result stored in
  `graph_state.results`.
- `failed` — step outcome `status:error`/`status:exception` that is NOT a
  cancellation (§ below).
- `blocked` — transitive propagation: a step whose `requires` contain a
  `failed` OR `blocked` step becomes `blocked` (so blocking closes over the
  whole downstream subgraph, structured and inspectable in `graph_state`).
- `abandoned` — terminal: steps that will never execute because the graph
  aborted (cancellation or aggregate-budget abort). `abandoned` is terminal
  state, NEVER retry authorization (AGENTS.md external-effect invariant).

### Ready-step loop (inside the single async worker)

1. If no step is `pending`/`ready`, terminate with the structured graph
   outcome (`graph_state` + per-step results).
2. Enumerate `plan_graph_ready/3` in normalized input order; take the first
   (deterministic; this slice executes one ready step at a time — no
   per-step Futures, no second scheduler).
3. Mark `running`; derive per-step budget (§7); desugar (§8); execute via
   `rlm_plan` ABIs; store `step_result`; mark `completed` or `failed`.
4. On `failed`: propagate `blocked` transitively to all dependents.
5. On cancellation (below): abort the whole graph -> remaining
   `pending`/`ready`/`blocked`/`running` steps become `abandoned`; rethrow.
6. On aggregate-budget exhaustion (§7): remaining steps become `abandoned`
   (not `blocked`); graph outcome `status:aborted` with reason `budget`.
7. Loop.

### Cancellation is not ordinary failure (review D1, mandatory)

Cancellation reaches the worker through two possible shapes and BOTH must be
unwrapped:

- **thrown**: `rlm_plan:plan_execute` rethrows
  `error(rlm_cancelled(Token), Context)` (`rlm_plan.pl:1479-1481`); the
  worker's per-step `catch/3` sees the throw.
- **folded**: if the step went through the structured outcome path
  (`rlm_outcome:plan_outcome/5`), the catch-all folds it into
  `execution_outcome{status:exception, error:diagnostic_error{kind:exception,
  exception:error(rlm_cancelled(Token), _)}}` (`rlm_outcome.pl:877-885`);
  the loop must unwrap `error.exception` and inspect it.

Either shape => abort the whole graph: no further ready step executes, no
re-submission, remaining steps `abandoned`, and the token is rethrown out of
`plan_graph_execute` so the awaiting facade (via the Future) observes
`error(rlm_cancelled(Token), _)`. A regression test pins: cancel mid-step =>
no further step executes and the exact token propagates (§12,
`cancellation_aborts_graph_and_rethrows_token`).

## 7. Aggregate graph budget

Per-step plans start from a FRESH `runtime_budget` (`initial_execution_state`,
`rlm_plan.pl:820-837`), so N steps would otherwise admit N× the allowances
(review D2, empirically Q5a/Q5b). The graph therefore owns an aggregate
budget and feeds it forward.

```prolog
default_plan_graph_budget(graph_budget{max_steps:64,
                                       max_total_tool_calls:16,
                                       max_total_model_calls:8,
                                       max_total_context_ops:32,
                                       max_total_output_bytes:65536,
                                       time_limit:30.0}).
```

(`time_limit` in seconds, matching `runtime_budget.time_limit` semantics;
`default_plan_budget/1` uses `10.0` per plan, the graph default allows 30.0
wall-clock across all steps — refine at implementation, unit is seconds.)

**Feed-forward mechanism.** The worker maintains `aggregate_remaining` with
the same per-class keys as `runtime_budget` minus `max_depth`/`max_parallel`
(those stay per-step defaults): tool calls, model calls, context ops, output
bytes, steps, time.

- Before admitting a ready step: derive the per-step `runtime_budget` as
  `StepBudget.Class = min(StepNeed.Class, AggregateRemaining.Class)` for
  every feed-forward class. `StepNeed` comes from the validation estimates
  (§5 step 8); a plain tool step needs 1 tool call; `validate/1` needs its
  model-call estimate; output-byte allowance defaults to
  `max_total_output_bytes` capped by remaining.
- After each step: read `plan_result.budget_remaining` (the `remaining` dict
  exposed on `plan_result{...}`; `rlm_plan.pl:1374-1381`) and decrement
  `AggregateRemaining.Class` by
  `StepBudget.Class - StepResult.budget_remaining.Class`. Keys map 1:1
  (`budget_remaining` carries exactly the feed-forward classes).
- Elapsed time is measured by the worker; `time_limit` exhaustion aborts like
  any other class.

**Exhaustion semantics.** If a ready step cannot be funded (any
`min(...)` collapses to a bound the step's own estimate exceeds), or a step
outcome reports `budget_exceeded`, the graph aborts: remaining steps
`abandoned`, structured partial outcome with `status:aborted` (reason
`budget`) and full `graph_state`. Never silent success; never a fresh
budget for the next step.

## 8. Execution pairing with rlm_plan

**Desugar (mechanical, per ready step).**

```prolog
Desugared = plan([tool(Op, literal(StepArgs), StepBind),
                  final(var(StepBind))])
```

`rlm_plan` requires exactly one trailing `final/1` (`plan_validate`; Q3b:
`final_must_be_unique_and_last`), so the minimal artifact is these two steps
(review D4). The step result routes through the plan binding and is charged
against the (derived, per-step) output-byte allowance. Desugar happens only
after §5 validation, and the desugared plan + inner capability term derive
mechanically from the single `plan_graph_op/1` declaration (pairing test per
op guards drift, review D7).

**In-worker call (exact ABI).** Per step:

```prolog
plan_validate(Desugared, StepCaps, StepBudget, ok(Validated)),
plan_execute(Validated, StepOptions, Inputs, Outcome)   % rlm_plan.pl:732
```

`plan_execute(+Validated, +Options, +Inputs, -Outcome)` (verified);
`Inputs` is the graph's `inputs` dict passed through. `StepOptions`
contains the runtime tool registry built from the host-supplied expert
registry option:

```prolog
experts([expert(sync_remote, Handler), expert(index, Handler2), ...])
```

mapped mechanically to `tools([tool(Op, Handler), ...])` — `rlm_plan` calls
`call(Handler, Args, ToolResult)` where the handler comes from the host
registry by exact atom match and registry entries are validated callable
(`rlm_plan.pl:780-787, 938-949`); model data is the argument, never the
goal. Plus `budget(StepBudget)` and the cancellation token option.

**Preflight (fail-closed, before first step).** Before executing any step,
the graph layer resolves every validated op against the experts registry
(source mentions `'experts'`, `'preflight'`; mirrors `rlm_plan`'s
`preflight_runtime`). An op with no `expert(Op, _)` entry fails before the
first step: `error(plan_graph_error{phase:preflight, kind:unknown_expert,
detail:op(Op)})`. Unknown expert can never surface mid-graph.

**`validate/1` — chosen path (ONE choice).** A `validate/1` step's expert is
a **host verifier closure registered under `tool(validate)`; the closure
itself calls the direct execute ABI
`rlm_verify:spec_observe_execute(Frozen, Sources, Registry, Options,
Outcome)`** (arity 5, `rlm_verify.pl:79-103`; the guarded entry
`spec_observe/5` stays outside the worker). Justification: it keeps the
scheduler uniform (every step is one `tool/3` step through `rlm_plan` with
identical budget/capability/tracing accounting) and avoids a second,
validate-special-cased execution path in the graph layer; calling the
execute ABI directly inside the worker is the sanctioned pattern (no nested
Future wait; precedent `rlm_spec_workflow.pl:240-244`). The closure receives
the frozen Spec fingerprint from `validate(spec(fingerprint(Atom)))` and
resolves it against host-supplied frozen specs; model self-report is never
an acceptance path.

## 9. symbol_ref / source_span contract and resolver

Closed ground data terms with structural validation:

```prolog
symbol_ref{name:Atom,
           kind:Atom,
           arity:NonNegInt (optional),
           owner:Atom (optional),
           occurrence:one_of([definition, reference, any]) (default any)}
source_span{file:Atom, start_byte:NonNegInt, end_byte:NonNegInt}
```

Structural validation (`plan_graph_symbol_ref_valid/1`,
`plan_graph_source_span_valid/1`): required keys present and typed; optional
keys either absent or valid; unknown keys rejected; terms fully ground;
`start_byte =< end_byte`. Malformed refs are rejected at §5 step 6 and by
these exported validators directly.

**Resolver** (bounded, host index only — no filesystem, no parser):

```prolog
plan_graph_resolve_symbol(+Index, +SymbolRef, -Outcome)
Index = symbol_index{kinds:[Atom],               % closed kinds this index can resolve
                     definitions:[symbol_definition(SymbolRef, SourceSpan, Provenance)]}
```

Outcomes:

- **exactly one match** (or several entries with an IDENTICAL span, deduped):
  `ok(symbol_binding{span:SourceSpan, provenance:Provenance})`.
- **zero matches** (kind supported, no definition):
  `error(plan_graph_error{phase:resolve, kind:unresolved,
  detail:symbol_ref(SymbolRef)})`.
- **more than one match with differing spans**:
  `error(plan_graph_error{phase:resolve, kind:ambiguous,
  detail:spans([...])})`.
- **kind not in `Index.kinds`** (no matching kind capability):
  `error(plan_graph_error{phase:resolve, kind:unsupported,
  detail:symbol_ref(SymbolRef)})`.

`locate/1` consumption: the host `locate` expert receives
`locate(symbol_ref(Ref))` as `Args`, resolves it via
`plan_graph_resolve_symbol` using the host index passed through options
(`symbol_index(Index)`), and on `ok` returns the binding (span +
provenance) as `ToolResult`, which flows through `final(var(StepBind))` so
the span is bound into the step bind var for downstream steps. `unresolved`,
`ambiguous`, and `unsupported` surface as ordinary structured step failures
(NOT cancellation) and propagate `blocked` downstream. `diff/2`/`edit/2`
targets (`ref(...)`, `span(...)`) resolve through the same expert-side
resolver; extraction remains owned by #96–#98.

## 10. Async / sync pairing

Canonical direction (AGENTS.md): `*_execute -> Future -> synchronous facade
awaits the same Future`; code inside the worker calls trusted execute ABIs
directly (no nested Future waits).

```prolog
plan_graph_run_async(GraphInput, Capabilities, Options, Future) :-
    graph_task_metadata(GraphInput, Options, Metadata),   % mirrors rlm_graph:graph_run_task_metadata
    rlm_async:rlm_async_submit(
        rlm_plan_graph:plan_graph_execute(GraphInput, Capabilities, Options, Inputs, _),
        Metadata, Future).
```

- `Inputs` comes from the `inputs(Inputs)` option (default `inputs{}`).
- `plan_graph_run(+GraphInput, +Capabilities, +Options, +Inputs, -Outcome)`:
  the facade adds `inputs(Inputs)` to the options, calls
  `plan_graph_run_async/4`, and awaits the SAME Future with
  `rlm_future_await/2,3`. One submission total; validation happens inside
  the worker before the ready-step loop (fail-closed for unvalidated input),
  so async and sync callers observe identical outcomes (async/sync parity
  test, §12).
- `plan_graph_cancel(+Token)`: mirrors `rlm_graph:graph_cancel/1` plumbing —
  a `rlm_plan_graph`-scoped cancellation token state (`plan_graph_cancel/1`
  flips token state to `cancelled` and `thread_signal`s the running worker,
  exactly like `rlm_graph.pl:507-525`); the worker's next cancellation
  observation aborts the graph and rethrows `error(rlm_cancelled(Token), _)`
  (§6). `rlm_future_cancel/2` remains the Future-level backstop
  (`rlm_future_cancel(Future, Outcome)`, `rlm_async.pl:568`).
- Metadata mirrors `graph_run_task_metadata` (`rlm_graph.pl:555-560`): task
  kind `plan_graph`, step count, capability count — trusted runtime data
  only.

## 11. Rejected alternatives

- **R1 — extend `rlm_plan.pl` in place** (project-op family + DAG scheduler
  inside `execute_steps/5`): entangles sequential execution with dependency
  scheduling in a 1632-line stable core with six public exports; large
  regression blast radius. Issue #288 goal-1's "data constructors in the
  existing `rlm_plan` closed-AST world" is read as: ops land as validated
  `tool(Op)` closed-AST steps executed by `rlm_plan` — the closed-AST
  *world*, not the file; issue text reconciled in the same slice (review
  REQUIRED CHANGE 7).
- **R2 — compile step/depends_on onto `rlm_graph` nodes**: edges are static
  and routes route on state, not dependencies; `max_visits_per_node` and
  checkpoint semantics are not dependency semantics; general DAGs would need
  graph-per-step encodings and would conflate trusted node closures with
  plan-op data. (A pure linear chain is expressible today, so the rejection
  is decisive for DAGs, not chains.) Future durability may reuse
  `rlm_graph_persist` as a substrate WITHOUT adopting node semantics.
- **R3 — a second SPEC vocabulary** (`spec(SpecId, [goal(...), ...])`): the
  existing closed SPEC language already covers the semantics; a parallel
  vocabulary would fragment validation/freezing/fingerprinting.
  `validate/1` references frozen Spec fingerprints instead.
- **R4 — executing ops directly in Prolog** (`call(sync_remote(...))`,
  `plan_graph_eval/1` escapes): violates the core authority invariant;
  model data must never become a goal. The only `call` on model-influenced
  data is `call(Handler, Args, ToolResult)` with host-registry handlers;
  the vocabulary-before-desugar ordering keeps the name space closed (§5).
- **R5 — Tree-sitter semantic extraction in this slice**: owned by #96–#98;
  this slice defines only the consumption contract (YAGNI).
- **(review D3) widening `capability_shape/1` with `plan_op/1`**: rejected —
  deliberate grammar widening with dual vocabulary risk; `tool(Op)` is
  consistent with the desugaring and existing precedent
  (`tool(spawn_agent)`).

## 12. Acceptance-criteria -> test map

All in `test/rlm_plan_test.pl` style (`begin_tests`, focused assertions over
public entries; host-recorded expert order for scheduling). File:
`test/rlm_plan_graph_test.pl`.

| Test | Issue #288 criterion | Review |
|---|---|---|
| `parses_model_json` | parse (JSON) | — |
| `parses_term_form` | parse (term) | — |
| `rejects_unknown_op` | closed-vocabulary rejection | D7 |
| `rejects_unknown_dependency` | unknown-dep rejection | — |
| `rejects_cycle` | cycle rejection | — |
| `rejects_duplicate_step_id` | duplicate-id rejection | — |
| `ready_step_admits_only_dependency_complete` | ready-step scheduling | — |
| `executes_in_topological_order` | ready-step scheduling order | D4 (two-step desugar shape exercised) |
| `blocks_dependents_on_failure` | failure→blocked propagation | — |
| `cancellation_aborts_graph_and_rethrows_token` | cancellation abort + token rethrow | D1 |
| `aggregate_budget_enforced_across_steps` | aggregate-budget enforcement | D2 |
| `capability_denied_per_op` | per-op capability denial | D3 |
| `vocabulary_validated_before_desugar` | closed-vocabulary rejection ordering | D7 |
| `unknown_expert_fails_preflight` | expert-registry resolution | — |
| `validate_step_uses_host_verifier` | SPEC validator decides acceptability | — |
| `delegate_narrows_capabilities` | delegate narrowing | D8 |
| `resolver_unresolved` | symbol resolution states | — |
| `resolver_ambiguous` | symbol resolution states | — |
| `resolver_unsupported` | symbol resolution states | — |
| `symbol_ref_rejects_malformed` | symbol_ref contract | — |
| `source_span_rejects_inverted_bytes` | span byte ordering | — |
| `run_async_awaits_same_future_as_run` | async/sync parity | D5 |
| `budget_bounds_step_count` | aggregate-budget step bound | D2 |

Gate notes: `scripts/plan_graph_contract_check.pl` substring tests
(`rejects_cycle`, `ready_step`, `blocks_dependents`, `capability_denied`,
`validate_step`, `delegate`, `unresolved`, `ambiguous`, `unsupported`,
`parses`, `budget`) are all satisfied by the names above. The gate must
later gain `plan_graph_run_async/4` and `plan_graph_cancel/1` presence facts
(review D5 / REQUIRED CHANGE 6); record that addition in the same slice.
Presence-gate results are never cited as behavioral evidence.

## 13. Docs outline for docs/plan-graph-runtime.md

1. **Overview** — closed op vocabulary + dependency-graph executor;
   `rlm_plan` remains the only step executor; LLM proposes the graph, Prolog
   decides executability, host experts execute, capabilities decide whether,
   SPEC validator decides acceptability.
2. **Module surface** — the §2.1 export table with modes.
3. **Op vocabulary** — §3 table incl. effect classes and the durable
   `rlm_effect` requirement for real expert packs (no new external-effect
   path in this slice; shipped handlers are pure closures).
4. **Plan-graph JSON and term forms** — §4 with `symbol_ref`/`source_span`
   JSON shapes; explicit "never `read_term/3` on model text".
5. **Validation** — §5 order and the exact `plan_graph_error{phase, kind,
   detail}` catalogue.
6. **Scheduling semantics** — `ready_step` definition (the gate greps for
   the literal string `ready_step` in this file), status machine, blocked
   propagation, cancellation-as-token-rethrow, `abandoned` terminal.
7. **Aggregate budget** — §7 dict, feed-forward via
   `plan_result.budget_remaining`, `status:aborted` semantics.
8. **Async contract** — one submission, same-Future await,
   `plan_graph_cancel/1`.
9. **Resolver contract** — §9 outcomes table; host index shape; #96–#98
   ownership note.
10. **Guarantee boundary** — what is NOT guaranteed: durability (follow-up),
    provider-level exactly-once, external effects (expert-pack obligation),
    extraction.

Cross-links: `docs/typed-plans.md` gains a link to
`plan-graph-runtime.md` (gate checks the back-link; add it in the same
slice), `docs/spec-verify.md` links `validate/1` -> verifier expert -> `spec_observe_execute/5`,
`docs/prolog-agent-roadmap.md` gains a note when AgentProlog readiness
changes (long-horizon execution layer available for the standalone product).

## 13b. Recorded deviations from this design (post final review)

- §6 named TWO cancellation shapes (thrown and `plan_outcome/5`-folded).
  The implementation calls `rlm_plan:plan_execute/4` directly and never
  goes through `plan_outcome/5`, so the folded shape cannot occur;
  `step_throw/2` covers the thrown and thread-signal shapes instead.
- §2.1 typed `plan_graph_execute/5` as taking `+ValidatedGraph`; the
  implementation takes raw `+Input` and validates inside the worker
  (consistent with §10 and the docs; §2.1 was the stale wording).
- §10 metadata omits step/capability counts; the implemented
  `async_metadata` mirrors `rlm_graph` keys exactly.

## 14. Appendix: verification queries

All queries run against the current checkout (branch state of this design
session), loading modules directly:

1. `plan_execute` exact signature — `prolog/rlm_plan.pl:732-742`:
   `plan_execute(Validated, Options, Inputs, Outcome)` with
   `must_dict_execution(Inputs, inputs)` and `preflight_runtime/2`. **Matches
   prompt** (arity 4, first arg the validated plan).
2. Cancellation rethrow — `prolog/rlm_plan.pl:1479-1481`:
   `execution_exception(error(rlm_cancelled(Token), Context), _) :- !,
   throw(error(rlm_cancelled(Token), Context))`. **Matches prompt.**
3. Async submit pattern — `prolog/rlm_graph.pl:555-560`:
   `graph_run_async` builds metadata then
   `rlm_async_submit(rlm_graph:graph_run_execute(...), Metadata, Future)`;
   `graph_run` awaits the same Future. **Matches prompt.**
4. Aggregate budget feed-forward data — `prolog/rlm_plan.pl:24-31`:
   `default_plan_budget(plan_budget{max_steps:64, max_depth:4,
   max_parallel:8, max_model_calls:8, max_tool_calls:16,
   max_context_ops:32, max_output_bytes:65536, time_limit:10.0})`;
   `time_limit` is a float in **seconds**. Graph default picks `30.0`
   accordingly (design §7; value refined at implementation). **Fact
   confirmed.**
5. `rlm_future_cancel/2` — `prolog/rlm_async.pl:568`:
   `rlm_future_cancel(Future, Outcome)`. `plan_graph_cancel/1` therefore
   mirrors `rlm_graph:graph_cancel/1` token plumbing
   (`rlm_graph.pl:507-524`) rather than the 2-arg Future cancel directly.
   **Fact confirmed; design §10 adjusted to token-based cancellation.**
6. Gate export list — read `scripts/plan_graph_contract_check.pl` in full:
   10 module-export facts + exact-vocabulary check + async/cancel absence
   (to be added later) + source mentions + docs/test presence. **Matches
   prompt.**
7. JSON discipline — `docs/typed-plans.md:52-56`: JSON object extraction,
   SWI JSON library decode, never `read_term/3` for model text. **Fact
   confirmed.**
8. Test style — `test/rlm_plan_test.pl:1-60`: `begin_tests`, relative
   `use_module('../prolog/...')`, `assertion/1` over structured outcomes.
   **Fact confirmed.**

No pre-verified fact required correction; one refinement recorded: the
per-step execute ABI is `plan_execute/4` (Validated, Options, Inputs,
Outcome) at `rlm_plan.pl:732` — cancellation rethrows from inside it, so
the worker's `catch/3` (§6) is the primary cancellation observation point,
with the `plan_outcome/5`-folded shape as the secondary unwrap.
