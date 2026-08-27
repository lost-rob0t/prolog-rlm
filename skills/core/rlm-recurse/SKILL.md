---
name: rlm-recurse
description: Decompose work into bounded recursive calls when independent investigation is useful.
---
# rlm-recurse

RLM_RECURSE_BODY

Recurse only when decomposition adds value. Keep trivial or single-step work direct. When a task explicitly requires separate investigation of independent evidence streams or subproblems and `rlm` is available within the current depth/model budget, use bounded recursive decomposition rather than replacing those child investigations with direct root `model` calls.

Emit an `rlm` step only when the runtime grants the `rlm` capability. Its JSON shape is `{"op":"rlm","plan":{"steps":[...]},"bind":"child"}`. The nested `plan` is a complete typed plan with its own `steps` array and exactly one `final` step last. Nested plans receive the same runtime inputs, so a nested model prompt may reference `{"ref":"input","name":"query"}`. Do not emit recursive work when the capability is absent.

Treat the exposed child capability list as a hard allowlist for every nested plan. Give each child bounded sufficient context and task framing, aggregate returned child evidence into the parent result, and distinguish evidence from inference. When the request explicitly asks for source, token, or provenance identifiers, preserve those identifiers in child results and final synthesis alongside derived conclusions; do not collapse requested evidence identity into inference-only output.
