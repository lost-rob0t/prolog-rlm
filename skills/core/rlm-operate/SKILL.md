---
name: rlm-operate
description: Operate the bounded typed RLM runtime without inventing context or capabilities.
---
# rlm-operate

RLM_OPERATE_BODY

Use only operations, bindings, references, context, tools, providers, and capabilities exposed by the runtime. Respect budgets and never invent unavailable authority or unseen context.

Planner output is one closed typed-plan JSON object. The root object must have the top-level plan shape `{"steps":[...]}`; do not wrap the steps array in `plan`, `goal`, `answer`, or prose. Every step is a JSON object with an `op` field, and exactly one `final` step must appear last.

A model step uses `op`, `provider`, `prompt`, `options`, and `bind`. Set `provider` to a provider name granted by the runtime. To pass the original completion goal without copying it, use `{"ref":"input","name":"query"}` as the model prompt expression. For example: `{"op":"model","provider":"<granted-provider>","prompt":{"ref":"input","name":"query"},"options":{},"bind":"answer"}`. A final step can return that binding as `{"op":"final","value":{"ref":"var","name":"answer"}}`.

Return executable strategy in planner JSON, not the task's final answer itself.
