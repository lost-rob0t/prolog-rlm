# Structured outcomes and bounded repair

`rlm_outcome` is the diagnostic boundary above the closed typed-plan runtime.
It gives plans and trusted-host Prolog goals one canonical result vocabulary,
adds bounded inspection helpers, and provides a scoped repair loop that consumes
remaining execution budget instead of resetting it.

## Canonical statuses

Every `execution_outcome` uses one of these statuses:

- `success`
- `logical_failure`
- `timeout`
- `depth_exhausted`
- `resource_exhausted`
- `capability_denied`
- `validation_failure`
- `exception`

This distinction is intentional. Logical Prolog failure is not an exception;
a missing capability is not generic validation failure; and exhausted depth or
runtime counters are not ordinary application errors.

## Plan outcomes

```prolog
?- plan_outcome(Plan, Capabilities, RuntimeOptions, Inputs, Outcome).
```

A successful plan outcome preserves:

- final `value`;
- plan variable bindings;
- checkpoints;
- remaining step/model/tool/context/output budget;
- a bounded trace tree derived from plan transitions.

A failed plan outcome preserves the structured `plan_error` produced by the
plan runtime plus any transitions and remaining budget attached to that error.
The outcome layer classifies it without scraping messages or stderr.

## Trusted-host goal outcomes

```prolog
?- goal_outcome(member(X, [a,b]), [], Outcome).
```

Goal execution is explicitly bounded by wall time and depth. A success stores a
copy of the bound goal and residual constraints returned by `copy_term/3`, so
attributed-variable constraints are not silently discarded.

The default goal limits are deliberately small enough for diagnostic use:

```prolog
outcome_limits{
    goal_time_limit:2.0,
    goal_depth_limit:256,
    trace_max_nodes:64,
    trace_max_bytes:8192,
    max_repairs:2,
    repair_time_limit:2.0
}
```

Callers may tighten or replace these through:

```prolog
[outcome_limits(_{goal_time_limit:0.5, trace_max_nodes:16})]
```

## Bounded trace trees

`outcome_trace/3` returns a trace tree whose node and serialized-byte ceilings
are explicit. Plan traces use the plan as the root and transitions as children.
Trusted goal traces use one bounded root node with callable shape, status, and
elapsed time.

If the serialized trace would exceed `trace_max_bytes`, the full structure is
replaced by a small summary node containing the original byte count and the
configured byte ceiling. Large terms are therefore not accidentally turned
into an unbounded observability channel.

## Inspection helpers

### Plan inspection

```prolog
?- plan_inspect(Plan, Capabilities, Budget, Inspection).
```

The inspection reports:

- normalized plan when parsing succeeds;
- required capabilities derived from operations;
- caller-provided capabilities;
- static plan estimate when validation succeeds;
- the same canonical status classification when validation fails.

Inspection does not execute the plan.

### Predicate inspection

```prolog
?- predicate_inspect(my_module:worker(_), Inspection).
```

The helper exposes bounded predicate metadata such as module/name/arity,
dynamic/static/multifile status, import source, meta-predicate declaration,
clause count, and source file/line when SWI-Prolog reports them. It does not
return predicate source text or create a model-callable escape hatch.

## Scoped repair

```prolog
?- plan_repair(Plan,
               Capabilities,
               RuntimeOptions,
               Inputs,
               TrustedRepairHandler,
               Outcome).
```

The repair handler is trusted host configuration. It is called as:

```prolog
TrustedRepairHandler(+Observation,
                     +Attempt,
                     +PreviousPlan,
                     -RepairedPlan)
```

`Observation` contains only structured state:

```prolog
repair_observation{
    attempt:Attempt,
    status:Status,
    phase:Phase,
    error:StructuredError,
    trace:BoundedTrace,
    budget_remaining:Remaining
}
```

This interface is suitable for deterministic repair logic or for a later
model-backed repair adapter. The core repair loop itself never parses stderr or
raw exception printouts to decide what happened.

### Budget rule

A repaired plan is executed with the **remaining** step/model/tool/context/output
counters from the failed attempt. The original recursion/concurrency ceilings
are retained. The remaining wall-clock allowance is recomputed from the start
of the whole repair run.

Validation failures happen before execution, so they may be repaired without
spending execution counters. Execution failures do spend counters. A repair
cannot restore consumed tool calls, steps, or output budget.

The number of repair proposals is separately bounded by `max_repairs`, and each
trusted repair callback has a `repair_time_limit`.

## Control-signal integrity

Plan-level wall-time and cancellation signals must stay control signals even
when they occur while a trusted tool is running. The plan runtime therefore
rethrows `time_limit_exceeded` and `rlm_cancelled(...)` from its trusted-tool
catch boundary instead of converting them into ordinary tool exceptions.

This invariant keeps the canonical `timeout`/cancellation semantics valid above
the tool boundary.

## Deterministic acceptance

The #10 suite covers:

- all canonical plan/goal status classes;
- logical failure versus exception;
- CLP(FD) residual constraints;
- plan/predicate inspection;
- node- and byte-bounded traces;
- execution failure followed by structured repair and success;
- consumed tool/step budget remaining consumed after repair;
- validation failure repair without execution-budget loss;
- plan timeout propagation through a running trusted tool.
