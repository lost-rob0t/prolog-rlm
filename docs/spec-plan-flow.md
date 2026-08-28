# SPEC-seeded plan flow

The Frozen Spec is the authority for desired state. Typed plans describe only
how the runtime attempts to satisfy that state.

This layer does **not** introduce a second scheduler, verifier, or plan
language. It composes the existing `rlm_spec`, `rlm_plan`, and
`rlm_spec_workflow` boundaries.

## Flow

```text
requirements
    |
    v
SPEC source
    |
    v
validated + Frozen Spec / SpecRef
    |
    v
plan_seed_from_spec/3
    |
    v
non-executable plan_seed
    |
    v
plan_refine/4
    |
    v
Spec-bound typed plan candidate
    |
    v
plan_validate_against_spec/5
    |
    v
whole-plan capability + budget validation
    |
    v
spec_plan_execute/5
    |
    v
observe + verify against the same Frozen Spec
    |
    +---- passed ---> done
    |
    `---- rejected --> plan_replan/5 --> validate --> execute --> verify
```

A replan may change execution strategy, dependencies, expert/tool selection,
retry structure, or decomposition. It may **not** change what counts as done.
Changing requirements, invariants, evidence policy, or output contracts requires
a new Spec version and therefore a new `SpecRef`.

## Public API

The SPEC-seeded planning API lives in `rlm_spec_plan`:

```prolog
plan_seed_from_spec(+FrozenSpec, +PlanningContext, -Outcome).
plan_refine(+FrozenSpec, +Seed, +TrustedRefiner, -Outcome).
plan_validate_against_spec(+FrozenSpec, +SpecPlan,
                           +Capabilities, +Budget, -Outcome).
plan_replan(+FrozenSpec, +ExecutionState, +PlannerInput,
            +TrustedRefiner, -Outcome).
plan_prepare_from_spec(+FrozenSpec, +PlanningContext, +TrustedRefiner,
                       +Capabilities, +Budget, -Outcome).
```

`Outcome` is always `ok(Value)` or `error(spec_plan_api_error{...})`.

## Seed contract

`plan_seed_from_spec/3` returns a non-executable artifact:

```prolog
plan_seed{
    schema_version:1,
    spec_ref:SpecRef,
    subject:Subject,
    goals:[plan_goal{requirement_id:Id,
                     severity:Severity,
                     evidence_policy:Policy}, ...],
    requirements:ValidatedRequirements,
    invariants:Invariants,
    output_contract:OutputContract,
    planning_context:PlanningContext
}
```

The seed deliberately contains enough trusted structure for an expert system or
bounded model planner to reason about the task without inventing a second goal
representation. It is **not** accepted by `plan_execute/4` and is not an
executable plan.

`goals` are deterministic projections of Frozen Spec requirements. They are not
LLM-generated intents and do not weaken the original requirement objects.

## Refiner contract

The refiner is a trusted, ground callable supplied by the host. Model data never
constructs the callable.

It is invoked as:

```prolog
call(TrustedRefiner, FrozenSpec, PlanningInput, Candidate).
```

For first planning, `PlanningInput` is a `plan_seed{...}`. For replanning it is
a `replan_context{...}`.

The refiner must return:

```prolog
plan_candidate{
    plan:PlanLike,
    project_state:ProjectState
}
```

The candidate is immediately rebound through `spec_plan_bind/4`, producing:

```prolog
spec_plan{
    spec_ref:SpecRef,
    project_state:ProjectState,
    plan:NormalizedTypedPlan
}
```

A candidate cannot substitute a different `SpecRef`.

## Validation against SPEC

`plan_validate_against_spec/5` first proves that the bound plan belongs to the
same Frozen Spec, then delegates executable-plan validation to the canonical
`rlm_plan:plan_validate/4` gate.

That preserves the existing guarantees:

- closed AST only;
- full-plan validation before side effects;
- capability checks;
- binding/scope checks;
- recursive/parallel/retry structure checks;
- static budget estimate checks.

The successful result is:

```prolog
validated_spec_plan{
    spec_ref:SpecRef,
    project_state:ProjectState,
    validation:ValidatedPlan
}
```

This API does not add another executable-plan representation.

## Replanning

`plan_replan/5` accepts execution state already pinned to the same `SpecRef` and
constructs:

```prolog
replan_context{
    schema_version:1,
    spec_ref:SpecRef,
    execution_state:ExecutionState,
    planner_input:PlannerInput
}
```

The same trusted-refiner ABI is used. The returned candidate is rebound against
the original Frozen Spec before it can be validated or executed.

A mismatched execution-state `SpecRef` is rejected before the refiner runs.

## Prepare helper

`plan_prepare_from_spec/6` performs only:

```text
seed -> refine -> whole-plan validation
```

It performs **no execution**. This makes it useful for hosts that want a stable
review/inspection boundary before execution starts.

Execution remains owned by `spec_plan_execute/5` or the existing
`spec_workflow_*` / `spec_strategy_*` compositions.

## Expert-system usage

A host expert system can persist planning facts independently of model context:

```prolog
planned_intent(Intent).
depends(Intent, Dependency).
completed(Intent).

ready(Intent) :-
    planned_intent(Intent),
    \+ completed(Intent),
    forall(depends(Intent, Dependency), completed(Dependency)).
```

The expert system may select the next ready intent and ask a model for a bounded
candidate plan patch or implementation contribution. Any resulting executable
plan still passes through the typed plan validator and remains bound to the same
Frozen Spec.

This is the intended long-horizon split:

- SPEC owns acceptance;
- PLAN owns current execution strategy;
- expert rules own durable dependency/ready-state reasoning where appropriate;
- the LLM proposes bounded structured contributions;
- VERIFY judges observed state against the Frozen Spec.

## Direct mode

Direct mode remains first-class. Callers do not need to create a Spec-seeded
plan for ordinary model interactions.

Use symbolic planning when durable state, dependency reasoning, constrained
expert selection, repair/replan behavior, or long-horizon verification justify
it.
