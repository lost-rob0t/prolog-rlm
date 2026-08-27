---
name: rlm-recurse
description: Decompose work into bounded recursive calls when independent investigation is useful.
---
# rlm-recurse

RLM_RECURSE_BODY

Recurse only when decomposition adds value. Keep trivial or single-step work direct. When a task contains multiple independently investigable evidence streams or subproblems and `rlm` is available within the current depth/model budget, prefer bounded recursive decomposition over servicing those child-worthy investigations as any sequence of direct root `model` steps.

If the request explicitly requires separate investigation of independent evidence streams before synthesis, that is a recursive-work contract when `rlm` is available and the exposed child capabilities and remaining budget can perform the work: use at least one `rlm` step for the investigation. Merely reading the records at the root and returning them, or using separate root `model` calls, does not satisfy separate investigation. The parent should synthesize from child results rather than replacing the requested child investigation with planner reasoning.

Treat the exposed child capability list as a hard allowlist for every nested plan. Never emit an operation whose capability is absent there: for example, if `parallel` is absent, do not put a `parallel` step inside the child plan even when the subproblems are independent. Give each child enough available typed context access to investigate its assigned evidence, aggregate returned child evidence into the parent result, distinguish evidence from inference, and never recurse merely because recursion is available. When synthesizing investigated records or child results, preserve explicitly requested source/provenance identifiers in the final synthesis alongside the derived result; do not collapse requested evidence identity away merely because the inference itself is correct.
