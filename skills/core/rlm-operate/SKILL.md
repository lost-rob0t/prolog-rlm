---
name: rlm-operate
description: Operate the bounded typed RLM runtime without inventing context or capabilities.
---
# rlm-operate

RLM_OPERATE_BODY

Operate only through the typed runtime surface exposed for this request. Emit a typed plan only when the current request is explicitly asking you to act as the planner. During execution of an ordinary `model` step, follow that step's prompt and return its requested task result; do not emit another plan unless that model step explicitly asks you to plan.

As planner, return only one JSON object whose `steps` value is an array. Every step object has an `op`. The closed step ops are `context`, `model`, `rlm`, `tool`, `parallel`, `retry`, `checkpoint`, and `final`. A minimal valid direct plan is `{"steps":[{"op":"final","value":"done"}]}`. `final` occurs exactly once and is the last step.

Context selectors/transforms are actions, never step ops. Each context action requires its exact active `context(Action)` capability; do not substitute a different context action merely because its JSON shape is familiar. A slice is `{"op":"context","handle":{"ref":"input","name":"context"},"action":{"type":"slice","start":0,"length":256},"bind":"chunk"}` and requires `context(slice)`. A scalar item lookup is `{"op":"context","handle":{"ref":"input","name":"context"},"action":{"type":"peek","selector":{"type":"item","index":0}},"bind":"item"}` and requires `context(peek)`. `peek` also supports `head`/`tail` selectors with `count`; other context action types are `search` with `pattern`, `partition` with a supported `strategy`, `map` with `transform`, and `reduce` with `reducer`. For a `terms` context, `peek(item)` returns one item while `slice` returns a list. A `model` prompt must resolve to text, so do not pass a list-valued context result directly as its prompt. Use only actions and parameters whose exact capabilities are exposed by the runtime.

Step key shapes: `tool` uses `op,name,args,bind`; `model` uses `op,provider,prompt,options,bind`; `rlm` uses `op,plan,bind`, where `plan` is another object with a `steps` array; `parallel` uses `op,plans,bind`; `retry` uses `op,attempts,plan,bind`; `checkpoint` uses `op,label`; `final` uses `op,value`. Expressions may reference data as `{"ref":"input","name":"context"}`, `{"ref":"var","name":"binding"}`, or `{"ref":"field","value":{"ref":"var","name":"binding"},"key":"field"}`; ordinary JSON values are literals. References are runtime expressions, not string templates: the runtime does not interpolate `{{...}}` inside a literal string. When a bound or input text value itself should be the prompt of a model step, set `prompt` to that reference expression directly instead of inventing interpolation syntax. A `model` step binds the full structured model response, not just its text; when a later prompt or final value needs that assistant text, reference the bound response's `text` field rather than the whole binding.

Use a tool only when its active schema and capability are exposed. Use a model provider only when its model capability is exposed. Recurse only when decomposition adds value, and nested plans obey the same capability and finalization rules. Use only bindings produced by earlier steps, inspect opaque context instead of inventing it, respect all budgets, and never invent unavailable authority, tools, context, providers, or bindings.
