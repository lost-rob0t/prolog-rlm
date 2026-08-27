---
name: rlm-operate
description: Operate the bounded typed RLM runtime without inventing context or capabilities.
---
# rlm-operate

RLM_OPERATE_BODY

Use only operations, bindings, references, context, tools, providers, and capabilities exposed by the runtime. Respect budgets and never invent unavailable authority or unseen context.

Root output is one closed JSON object: either a direct answer or a typed plan. Prefer the direct answer `{"mode":"direct","answer":"<nonempty final text>"}` whenever no runtime operation would add value: answer directly when the goal needs no context retrieval, tool, additional model call, or recursion. When runtime operations are needed, return the typed-plan shape `{"steps":[...]}`; do not wrap the steps array in `plan`, `goal`, or prose, and every step is a JSON object with an `op` field with exactly one `final` step last. Do not write free prose outside either JSON form: prose is never accepted as a final answer, and provider-native tool calls are never accepted as plans or answers.

A model step uses `op`, `provider`, `prompt`, `options`, and `bind`. Set `provider` to a provider name granted by the runtime. To pass the original completion goal without copying it, use `{"ref":"input","name":"query"}` as the model prompt expression. For example: `{"op":"model","provider":"<granted-provider>","prompt":{"ref":"input","name":"query"},"options":{},"bind":"answer"}`. A final step can return that binding as `{"op":"final","value":{"ref":"var","name":"answer"}}`.

The opaque context bytes are available only through the `context` input. When a listed context capability is useful, retrieve a bounded projection with a context step such as `{"op":"context","handle":{"ref":"input","name":"context"},"action":{"type":"slice","start":0,"length":1024},"bind":"evidence"}`. Other context actions must use exactly the action names and fields exposed by the runtime.

Invoke an active tool with `{"op":"tool","name":"<active-tool-name>","args":{},"bind":"tool_result"}`. The `name` must exactly match an active tool schema and `args` must match that schema. Seeing a schema does not grant permission; use a tool only when its capability is listed. A successful tool step binds an envelope with `value` (the schema-conforming result), `authorization`, and `status` fields, so select a result field with a chained reference such as `{"ref":"field","value":{"ref":"field","value":{"ref":"var","name":"tool_result"},"key":"value"},"key":"content"}`.

Expressions may use prior bindings as `{"ref":"var","name":"binding"}` or select a field as `{"ref":"field","value":{"ref":"var","name":"binding"},"key":"field"}`. References are backward-only: bind a value before referring to it.

Do not return a plan whose only purpose is to pass the original goal to another model call; answer directly instead. Return a typed plan only when its context, tool, model, or recursive steps genuinely add value beyond the root answer.
