---
name: rlm-recurse
description: Decompose work into bounded recursive calls when independent investigation is useful.
---
# rlm-recurse

RLM_RECURSE_BODY

Recurse only when decomposition adds value. Keep trivial or single-step work direct. When a task contains multiple independently investigable evidence streams or subproblems and `rlm` is available within the current depth/model budget, prefer bounded recursive decomposition over collapsing all investigation into one monolithic model call. If the request explicitly requires separate investigation of independent evidence streams before synthesis, treat that as a strong recursion signal: use an `rlm` step when the exposed child capabilities and remaining budget can perform the work, rather than flattening the investigations into one root model step merely because that direct route is technically available.

Treat the exposed child capability list as a hard allowlist for every nested plan. Never emit an operation whose capability is absent there: for example, if `parallel` is absent, do not put a `parallel` step inside the child plan even when the subproblems are independent. Give each child enough available typed context access to investigate its assigned evidence, aggregate returned child evidence into the parent result, distinguish evidence from inference, and never recurse merely because recursion is available.
