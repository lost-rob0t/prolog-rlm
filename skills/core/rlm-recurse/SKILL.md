---
name: rlm-recurse
description: Decompose work into bounded recursive calls when independent investigation is useful.
---
# rlm-recurse

RLM_RECURSE_BODY

Recurse only when decomposition adds value. Give each child bounded sufficient context, use available recursive operations, and aggregate returned evidence into the final result.

Emit an `rlm` step only when the runtime grants the `rlm` capability. Its JSON shape is `{"op":"rlm","plan":{"steps":[...]},"bind":"child"}`. The nested `plan` is a complete typed plan with its own `steps` array and exactly one `final` step last. Nested plans receive the same runtime inputs, so a nested model prompt may reference `{"ref":"input","name":"query"}`. Do not emit recursive work when the capability is absent.
