# Deterministic leaf experts

`library(rlm_expert)` implements the first bounded leaf slice of #377.
It uses the existing tool registry, scheduler, schema validation, capability
checks, time/output bounds, and direct/plan tool projections. It makes no
provider calls. Host code supplies a trusted model-free handler with the same
`Handler(+Arguments,-Value)` ABI as a tool.

```prolog
tool_registry_create(Registry),
Contract = expert_contract{
    id:classify_exit, version:1, goal:test_result, priority:100,
    description:"Classify supplied test evidence",
    arguments:_{type:integer}, result:_{type:string},
    limits:_{time_limit:1.0,max_output_bytes:1024,inferences:10000}
},
expert_register(Registry, Contract, my_host:classify_exit, Outcome).
```

Registration grants no permission. `expert_catalog/2` returns inert contracts,
never handlers. `expert_select/4` takes a goal atom and a host context containing
`capabilities`; it selects the highest-priority matching registered goal whose
`tool(Id)` capability is present. Equal-priority ties return `ambiguous_expert`.
Selection is a routing decision, not evidence that a goal is satisfied.
Input schemas validate the actual evidence supplied when the expert runs.

`expert_invoke/7` takes registry, expert id, arguments, host context, ordinary
tool invocation options, outcome, and trace. It invokes the canonical async
tool path and awaits it. Inside an existing async/plan worker use
`expert_invoke_execute/6`; its result is the ordinary `tool_async_result`
envelope. Invocation rechecks capability and schema. Registration also exposes
the same handler as an ordinary registered tool, so existing direct-mode
projection and `tool_registry_runtime_tools/3` use one implementation.

Experts are read-only reasoning handlers. Host code is responsible for their
purity, just as for trusted read-tool handlers. They may derive inert proposals;
actual mutation must use a separately registered effectful tool. The closed
plan-native goal set `sync_remote`, `run`, `index`, and `delete` is rejected.
Unknown contract fields (including fallback policies) fail rather than being
silently ignored. Destroying the underlying registry removes its contracts.

This does **not** complete #377 or the expert-system epic. Recursion/delegation,
aggregate nested work budgets, evidence-aware applicability rules, explicit
metered model fallback, invocation lineage, and per-expert unregister remain
open. No expert result is automatically Frozen-Spec verification evidence.
