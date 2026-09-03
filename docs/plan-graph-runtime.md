# Plan-graph runtime

`rlm_plan_graph` is the long-horizon execution boundary between a
model-authored project plan and runtime-authoritative execution. The model
may propose a **plan dependency graph** over a closed project-op vocabulary,
but the graph is inert data: it is parsed, normalized, validated in full, and
only then executed step by step through `rlm_plan`.

```text
natural language
      |
    SPEC (rlm_spec / rlm_spec_lang: what must become true)
      |
model proposes PLAN GRAPH (inert data)
      |
plan_graph_validate (closed vocabulary, structure, capabilities, budget)
      |
ready_step scheduling (Prolog decides what is executable)
      |
expert KB (host registry decides who executes; the D6-11 plan-native
deterministic set executes at the plan layer instead)
      |
capability system (decides whether they are allowed)
      |
rlm_plan executes each step (budgets, tracing, tool registry)
      |
SPEC validator / verifier (whether the resulting state is acceptable)
```

`rlm_plan` remains the only step interpreter. There is no second scheduler:
`plan_graph_run_async/4` submits one execute predicate to `rlm_async`; the
ready-step loop runs inside that single worker calling `rlm_plan` execute
ABIs directly; the synchronous facade awaits the same Future.

## Module surface

```prolog
plan_graph_parse(+Input, -Outcome).            % JSON text, JSON dict, or term
plan_graph_normalize(+Input, -Outcome).
plan_graph_validate(+Graph, +Capabilities, +Budget, -Outcome).
plan_graph_ready(+Graph, +State, ?StepId).
plan_graph_execute(+Input, +Capabilities, +Options, +Inputs, -Outcome).
plan_graph_run(+Input, +Capabilities, +Options, +Inputs, -Outcome).
plan_graph_run_async(+Input, +Capabilities, +Options, -Future).
plan_graph_cancel(+Token).
plan_graph_cancellation_token(-Token).
plan_graph_op(?Name/Arity).                    % closed vocabulary, inert data
default_plan_graph_budget(-Budget).
plan_graph_resolve_symbol(+Index, +SymbolRef, -Outcome).
plan_graph_symbol_ref_valid(+SymbolRef).
plan_graph_source_span_valid(+SourceSpan).
```

`Outcome` is `ok(...)` or `error(plan_graph_error{phase, kind, detail})`.

## Closed project-op vocabulary

Ops are inert data constructors (`plan_graph_op/1` facts). The required
capability term for an op is exactly `tool(Op)` (inside the closed
`capability_shape/1` grammar); `delegate/2` requires `tool(spawn_agent)`.
The desugared plan and its capability term both derive mechanically from
`plan_capability_required/2`. The vocabulary is validated **before** any
desugaring, so model data can never name a host-registered tool outside the
closed set.

| Op | Args (closed terms) | Capability | Effect class |
|---|---|---|---|
| `sync_remote/1` | `sync_remote(op(Atom))` | `tool(sync_remote)` | external* |
| `index/1` | `index(scope(all))`, `index(scope(path(Atom)))` | `tool(index)` | observation |
| `search/2` | `search(Pattern, Scope)` | `tool(search)` | observation |
| `locate/1` | `locate(symbol_ref(SymbolRef))` | `tool(locate)` | observation |
| `read/1` | `read(path(Atom))` | `tool(read)` | observation |
| `diff/2` | `diff(Side, Side)`; Side = `path(A)` \| `ref(SymbolRef)` \| `span(SourceSpan)` | `tool(diff)` | observation |
| `edit/2` | `edit(Side, Replacement)` | `tool(edit)` | external* |
| `create/2` | `create(path(Atom), literal(Atom))` | `tool(create)` | external* |
| `delete/1` | `delete(path(Atom))` | `tool(delete)` | external* |
| `run/1` | `run(command(Atom))` | `tool(run)` | external* |
| `validate/1` | `validate(spec(fingerprint(Atom)))` | `tool(validate)` | orchestration |
| `delegate/2` | `delegate(task(Atom), caps([CapTerm]))` | `tool(spawn_agent)` | orchestration |

\* Externally effectful in real use. The D6-11 plan-native set (`sync_remote`,
`run`, `index`, `delete`) dispatches at the plan layer through deterministic
host adapter closures and must admit/dispatch/observe through the durable
effect boundary (`rlm_effect`) with trusted adapter identity and attempt
lineage. Remaining real expert packs (`edit`, `create`) carry the same
obligation. This layer adds no external-effect path: shipped handlers are
pure host-supplied closures.

`delegate/2` child capabilities are validated as a narrowing subset of the
graph capabilities (narrowing by default). Execution desugars to a plain
`tool(spawn_agent, ...)` step with a host-supplied handler; any additional
narrowing re-check at execution time is the host handler's obligation in
this slice.

## Model-facing JSON and term forms

```json
{
  "steps": [
    {"id": "s1", "op": "index", "args": {"scope": "all"}, "bind": "idx"},
    {"id": "s2", "op": "locate",
     "args": {"symbol": {"name": "foo", "kind": "function",
                          "occurrence": "definition"}},
     "bind": "span"}
  ],
  "depends_on": [
    {"step": "s2", "requires": ["s1"]}
  ]
}
```

Model text is decoded with the SWI JSON library only; model text is never
read as a Prolog term. Host-authored term form:

```prolog
plan_graph(steps([step(s1, index, index(scope(all)), idx),
                  step(s2, locate,
                       locate(symbol_ref(symbol_ref{name:foo,
                                                    kind:function})),
                       span)]),
           depends_on([depends_on(s2, [s1])]))
```

## Validation (before any step executes)

Order is fixed; first fault wins:

1. structure (graph/step/edge shapes);
2. duplicate step ids and duplicate binds;
3. unknown dependencies;
4. cycles (three-color DFS; self-dependency is a cycle);
5. vocabulary (`plan_graph_op/1`) — before desugaring;
6. per-op argument shapes (incl. structural `symbol_ref`/`source_span`
   validation);
7. capability subset per op (`tool(Op)`; delegate child caps narrow);
8. aggregate budget estimate (steps, tool calls, model calls).

Errors are `error(plan_graph_error{phase, kind, detail})` with phases
`parse | normalize | structure | vocabulary | validate | capability |
budget | preflight | execute | resolve`.

## Scheduling semantics (ready_step)

Per-step statuses: `pending`, `ready`, `running`, `completed`, `failed`,
`blocked`, `abandoned`.

`plan_graph_ready(+Graph, +State, ?StepId)` succeeds exactly for pending
steps whose `requires` are all `completed`. The loop executes one ready step
at a time in normalized input order (deterministic). A failed step
transitively marks its dependents `blocked`. `abandoned` is terminal state,
never retry authorization.

**Cancellation is not ordinary failure.** A step outcome carrying
`error(rlm_cancelled(Token), _)` (thrown by the trusted layer, or raised via
`plan_graph_cancel/1` token plumbing) aborts the whole graph: remaining
steps become `abandoned` and the exact token is rethrown to the awaiting
facade. No further step executes and no re-submission occurs.

## Aggregate budget

Per-step plans start from a fresh runtime budget, so the graph owns an
aggregate and feeds it forward:

```prolog
default_plan_graph_budget(graph_budget{max_steps:64,
                                       max_total_tool_calls:16,
                                       max_total_model_calls:8,
                                       max_total_context_ops:32,
                                       max_total_output_bytes:65536,
                                       time_limit:30.0})
```

Each step receives `min(default, remaining aggregate)` per feed-forward
class; after each COMPLETED step the consumed budget (from
`plan_result.budget_remaining`) is deducted. Note that a step result's
bytes are charged at bind and again at `final/1`, so effective per-step
output cost is twice the result size (budgets are strict, never lenient). A step that cannot be funded,
that reports budget exhaustion, or that runs past the wall-clock deadline
aborts the graph: remaining steps are `abandoned` and the outcome is
`status:aborted` with reason `budget` or `time`. Never silent success, and
never a fresh budget for the next step.

## Expert registry, plan-native dispatch, and validate steps

The host supplies `experts([expert(Op, Handler)])`; the registry is
preflighted fail-closed before the first step (`unknown_expert` otherwise).
Each ready step is desugared mechanically into
`plan([tool(Op, literal(Args), Bind), final(var(Bind))])` and executed with
`rlm_plan` validate/execute ABIs. Handlers are invoked
`call(Handler, Args, ToolResult)` with model data as the argument, never as
a goal.

**D6-11 plan-native deterministic mutations.** The closed set
`sync_remote/1`, `run/1`, `index/1`, `delete/1` executes at the plan layer
through the canonical boundary (schema → capability → authority → durable
effect admission → dispatch → observe), exactly like a `tool/3` step —
never ambient shell/git access in plan code. They are excluded from expert
mapping and from the expert registry: the host supplies their deterministic
adapter closures through the separate `native_handlers([native_handler(Op,
Handler)])` option (only plan-native op names are admitted; an entry for
any other name faults `not_plan_native`), preflight requires a native
handler for every native step (`unknown_native_handler` otherwise), and an
expert-registry entry for a plan-native op faults `expert_mapping_excluded`.
Model-payload mutations (`edit/2`, `create/2`) remain write-expert-owned
per the design record §8.3 and are never members of the native set.

A `validate/1` expert is a host verifier closure (receiving
`validate(spec(fingerprint(Fp)))`); the closure resolves the fingerprint
against host-supplied frozen Specs and calls the direct execute ABI
`rlm_verify:spec_observe_execute/5`. Model self-report is never an
acceptance path.

## symbol_ref / source_span contract

```prolog
symbol_ref{name:Atom, kind:Atom, arity:NonNegInt (optional),
           owner:Atom (optional),
           occurrence:one_of([definition, reference, any])}
source_span{file:Atom, start_byte:NonNegInt, end_byte:NonNegInt}
```

`plan_graph_resolve_symbol/3` resolves over host-supplied index facts
`symbol_definition(SymbolRef, SourceSpan, Provenance)` inside
`symbol_index{kinds, definitions}`:

- exactly one match (identical spans deduped):
  `ok(symbol_binding{span, provenance})`;
- zero matches: `error(... kind:unresolved ...)`;
- multiple distinct spans: `error(... kind:ambiguous ...)`;
- kind not supported by the index: `error(... kind:unsupported ...)`.

A query ref matches a definition when every key present in the query is
present in the definition with an equal value; `occurrence: any` is a
wildcard. This layer performs no filesystem access and no parsing — source
extraction and the canonical project KB remain owned by #96-#98.

## Guarantee boundary

Not guaranteed by this layer: durability across restart (follow-up,
`rlm_graph_persist` substrate), provider-level exactly-once behavior,
external effects (expert-pack obligation through `rlm_effect`), and source
extraction (#96-#98). See also `typed-plans.md` for the closed-AST plan
runtime and `spec-verify.md` for frozen Specs and evidence semantics.
