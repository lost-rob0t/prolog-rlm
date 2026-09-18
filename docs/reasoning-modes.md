# Canonical reasoning modes

`rlm_reasoning_mode` owns the public reasoning-strategy state used by
downstream hosts such as AgentProlog. It deliberately does **not** own
conversation history, provider state, tools, capabilities, authority, effects,
verification state, or budgets.

A reasoning-mode transition changes how the runtime intends to reason. It does
not grant permission.

## Modes

The public vocabulary is closed:

- `direct` — ordinary provider-native model/tool reasoning through the existing runtime.
- `symbolic` — facts, rules, constraints, Specs, typed plans, verification, and expert-guided local reasoning.
- `symbolic-recursive` — symbolic reasoning plus explicitly permitted bounded recursive/subagent decomposition.
- `auto` — deterministic strategy selection from trusted task/runtime evidence.

An `auto` context starts with `effective:none` and
`reason:awaiting_selection`. The effective strategy is chosen only after a
trusted host supplies the closed task-evidence record to
`reasoning_mode_select/4`.

Explicit modes are sticky. Calling `reasoning_mode_select/4` while an explicit
mode is active returns that mode with `reason:explicit_override`.

## Public API

```prolog
reasoning_mode_open(+Context, -Outcome).
reasoning_mode_open(+Context, +RequestedMode, -Outcome).
reasoning_mode_get(+Context, -Outcome).
reasoning_mode_set(+Context, +RequestedMode, -Outcome).
reasoning_mode_select(+Context, +TaskContext, +Options, -Outcome).
reasoning_mode_close(+Context, +Reason, -Outcome).
reasoning_mode_destroy(+Context, -Outcome).
```

The host supplies a stable ground Context identity such as a run or session
term. The reasoning-mode layer stores that identity but does not duplicate the
underlying session or conversation.

A successful state is shaped as:

```prolog
reasoning_mode_state{
    context: Context,
    requested: Requested,
    effective: Effective,
    reason: Reason,
    generation: Generation,
    status: active|closed
}
```

Generation increments on explicit mode mutation, auto selection, and close.

## Auto selector v1

The task evidence vocabulary is intentionally small, closed, and boolean:

```text
expert_applicable
has_frozen_spec
has_constraints
requires_verification
decomposable
long_horizon
recursion_allowed
```

Unknown fields are rejected. Capability, authority, tool grants, budgets, model
credentials, and effect policy therefore cannot be smuggled into strategy
selection.

Selection order is deterministic:

| Evidence | Effective mode | Reason |
| --- | --- | --- |
| expert + decomposable + recursion allowed | symbolic-recursive | expert_decomposition |
| long-horizon + decomposable + recursion allowed | symbolic-recursive | decomposable_long_horizon |
| applicable deterministic expert | symbolic | expert_applicable |
| Frozen Spec present | symbolic | frozen_spec |
| constraints present | symbolic | constraints |
| verification required | symbolic | verification |
| otherwise | direct | flexible_default |

`recursion_allowed` is only a strategy-selection signal from trusted runtime
policy. It does not itself grant recursion capability or increase any recursion,
model, token, time, concurrency, or cost budget. The selected recursive path
must still pass the normal runtime gates.

## Expert integration

The `expert_applicable` signal is the handoff point to the canonical expert
runtime owned by issue #377.

Until that registry is fully implemented, issue #459 defines a compatibility
projection where sanitized registered tool schemas may be presented as inert
expert candidates. A candidate can recommend a normal registered tool, but it
never receives the trusted handler and never grants capability or authority.

Expert-guided symbolic execution follows this direction:

```text
trusted facts / Spec / constraints
        ↓
expert applicability and selection
        ↓
local symbolic answer
   or bounded next-step advice
        ↓
optional one model step
        ↓
normal typed tool/capability/authority/effect boundary
```

The model is a bounded reasoning operator in that loop. Expert advice may tell
the model what semantic step or registered tool is worth trying next; it cannot
make that operation executable.

## Downstream usage

AgentProlog issue #9 is the first product consumer. Its `/direct`,
`/symbolic`, `/symbolic-recursive`, and `/auto` commands should mutate or
inspect this canonical state rather than keeping a frontend-owned mode variable.

A downstream status surface should render requested and effective mode
separately. For example:

```text
auto -> symbolic (expert_applicable)
```

Mode changes must preserve the same canonical conversation/run identity and
must not reset provider history, capability sets, authority state, budgets,
effect lineage, cancellation, or verifier requirements.
