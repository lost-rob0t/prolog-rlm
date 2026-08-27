# Tool result projection

Tool execution, durable retention, and provider-visible projection are separate runtime concerns.

The canonical invariant is:

```text
REGISTERED != EXECUTABLE != EXECUTED != STORED != PROJECTED
```

A projection policy controls only what representation of a retained tool observation may be placed into model context. It does not unregister a tool, grant authority, delete a result, or weaken auditability.

## Public visibility presets

The public API exposes four presets through `rlm_tool_projection:result_visibility_preset/2`:

```prolog
result_visibility_preset(full, Outcome).
result_visibility_preset(once, Outcome).
result_visibility_preset(reference, Outcome).
result_visibility_preset(hidden, Outcome).
```

They compile to canonical inert policy data:

```text
full      => initial=full,      after_consumption=full
once      => initial=full,      after_consumption=none
reference => initial=reference, after_consumption=reference
hidden    => initial=none,      after_consumption=none
```

All current presets retain results durably and keep them retrievable:

```prolog
result_projection{
    initial: Initial,
    after_consumption: After,
    retention: durable,
    retrievable: true
}.
```

`result_projection_normalize/2` accepts either a public preset or an already-expanded canonical projection dict and validates it structurally.

## Canonical metadata helpers

`tool_message_projection/3` first normalizes a message through the canonical chain schema, requires `role:tool`, and then attaches `result_projection` metadata.

```prolog
?- tool_message_projection(
       _{role:tool,
         content:"large output",
         tool_call_id:"call-1",
         name:"shell"},
       once,
       Outcome).
```

`tool_result_projection/3` attaches the same canonical policy to an inert tool-result dict and retags it as `tool_result`. Anonymous SWI-Prolog dict tags are accepted: the canonicalizer requires the dict's key/value pairs to be ground, then replaces the input tag with the fixed `tool_result` tag. A nonground payload remains a structured validation failure.

These helpers define data shape only. This first slice intentionally does **not** change managed conversation packing, token accounting, tool invocation, or provider serialization.

## Next slice

The next integration step is to accept:

```prolog
result_visibility(full|once|reference|hidden)
```

in tool invocation options while retaining the complete authoritative result regardless of projection policy. Consumption tracking and context-packing behavior follow in later slices of #211.
