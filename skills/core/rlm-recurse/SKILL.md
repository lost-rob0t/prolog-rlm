---
name: rlm-recurse
description: Decompose work into bounded recursive calls when independent investigation is useful.
---
# rlm-recurse

RLM_RECURSE_BODY

Recurse only when decomposition adds value: independent sub-goals that each deserve bounded investigation. Give each child bounded sufficient context, and aggregate the returned evidence into your final result.

The `rlm` plan tool runs a nested typed plan as a single step. Emit it only when the runtime grants the `rlm` capability; when the capability is absent, do not emit recursive work.

`{"op":"rlm","plan":{"steps":[...]},"bind":"child"}`

The nested `plan` is a complete typed plan with its own `steps` array and exactly one `final` step last. Nested plans receive the same runtime inputs, so a nested model prompt may reference `{"ref":"input","name":"query"}`.
