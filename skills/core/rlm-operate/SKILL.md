---
name: rlm-operate
description: Operate the bounded typed RLM runtime without inventing context or capabilities.
---
# rlm-operate

RLM_OPERATE_BODY

Use only the tools, bindings, references, context, providers, and capabilities the runtime actually exposes to you. Respect budgets. Never invent unseen context, unlisted tools, ungranted providers, or authority you do not hold.

## Your output: one closed JSON object

Your entire reply is exactly one JSON object with nothing outside it. Choose one of two root decisions:

1. Direct answer — when no runtime tool would add value (no context retrieval, no tool call, no extra model call, no recursion):
   `{"mode":"direct","answer":"<nonempty final text>"}`
2. Typed plan — when runtime tools genuinely help:
   `{"steps":[...]}`
   Do not wrap the steps array inside a `plan`, `goal`, or any other key, and never inside prose.

Prose is never accepted as an answer. A provider-native tool call is never accepted as a plan or an answer. Any other output shape is rejected without execution.

## Plan tools

A plan is an ordered list of steps. Every step is one call to a plan tool: the `op` field names the tool, and `bind` names the result for later reference. Exactly one `final` step must come last.

- `final` — end the plan and return a value.
  `{"op":"final","value":{"ref":"var","name":"answer"}}`
- `model` — call a provider granted to you; `provider` must be a granted provider name. To pass the original completion goal without copying it, use `{"ref":"input","name":"query"}` as the prompt expression.
  `{"op":"model","provider":"<granted-provider>","prompt":{"ref":"input","name":"query"},"options":{},"bind":"answer"}`
- `context` — read a bounded projection of the opaque context bytes. The context is available only through the `context` input; never invent its bytes from metadata. Use exactly the action names and fields the runtime exposes.
  `{"op":"context","handle":{"ref":"input","name":"context"},"action":{"type":"slice","start":0,"length":1024},"bind":"evidence"}`
- `tool` — invoke an active tool. `name` must exactly match an active tool schema and `args` must match that schema. Seeing a schema does not grant permission: call a tool only when its capability is listed. A successful tool step binds an envelope object whose `value` field holds the schema-conforming result, so select nested result fields through chained references. For example, to return a tool's `content` field as the final value:
  `{"op":"tool","name":"<active-tool-name>","args":{},"bind":"tool_result"}`
  `{"op":"final","value":{"ref":"field","value":{"ref":"field","value":{"ref":"var","name":"tool_result"},"key":"value"},"key":"content"}}`

The recursive `rlm` plan tool is documented in the `rlm-recurse` skill and may be emitted only when the runtime grants the `rlm` capability.

## References

Use a previous binding as `{"ref":"var","name":"binding"}` or select one of its fields as `{"ref":"field","value":{"ref":"var","name":"binding"},"key":"field"}`. References are backward-only: bind a value before referring to it.

## Prefer the direct answer

Do not return a plan whose only purpose is to pass the original goal to another model call; answer directly instead. Return a typed plan only when its context, tool, model, or recursive steps genuinely add value beyond your own direct answer.
