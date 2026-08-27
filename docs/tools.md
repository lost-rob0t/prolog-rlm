# Capability-gated tools

`rlm_tool` is the trusted host boundary between model-selected tool names and executable Prolog handlers.

## Invariants

- model output may select a registered tool name, but never supplies a callable;
- every tool declares exactly one `tool(Name)` capability;
- invocation validates arguments before capability authorization, authority/effect admission, or handler execution, so malformed inputs fail at the canonical schema boundary even when the requested capability is absent;
- child capability sets are narrowing-only with `capabilities_narrow/3`;
- arguments and normalized results are checked against the registered schema;
- per-tool wall-time and output-byte ceilings are enforced;
- a per-invocation trace records authorization, status, output bytes, and elapsed time;
- plan execution uses `tool_registry_runtime_tools/3` to adapt the registry to
  the closed typed-plan runtime;
- trusted hosts that need invocation-local authority or correlation metadata
  use `tool_registry_runtime_tools/4`; registration and model visibility remain
  unchanged.

The capability vocabulary also reserves explicit terms for context, model, graph, persistence, network, filesystem, process, and MCP authority. Merely possessing one capability does not imply another. In particular, no shell/process or ambient filesystem/network capability is granted by default.

## Registry lifecycle

```prolog
?- tool_registry_create(Registry).
?- tool_register(Registry, Schema, TrustedHandler, Outcome).
?- tool_discover(Registry, Schemas).
?- tool_lookup(Registry, some_tool, Lookup).
?- tool_registry_destroy(Registry).
```

Discovery returns normalized schemas only. Trusted handler closures are never returned through discovery.

A canonical schema contains:

```prolog
tool_schema{
    name:example,
    description:"Example",
    capability:tool(example),
    arguments:_{type:object, ...},
    result:_{type:object, ...},
    limits:_{time_limit:1.0, max_output_bytes:4096}
}
```

The schema vocabulary supports `any`, `string`, `integer`, `number`, `boolean`, `list`, `array`, and `object`, including required object fields and `additional_properties:false`.

For `integer` and `number` schemas, the runtime supports the numeric bounds `minimum`, `maximum`, `exclusiveMinimum`, and `exclusiveMaximum`. Bounds are enforced for both arguments and results. Bound metadata must itself be numeric, and an empty or contradictory interval is rejected when the tool is registered instead of becoming a misleading provider-visible contract.

Examples:

```prolog
_{type:integer, minimum:1, maximum:32}
_{type:number, exclusiveMinimum:0}
_{type:number, minimum:0, exclusiveMaximum:1.0}
```

A bound violation is reported through the existing structured schema failure envelope (`phase:schema`, `kind:schema_validation_failed`) and preserves the nested value path. Invalid arguments never reach capability/authority/effect admission or the trusted handler. Result-bound violations are likewise rejected before an `ok(...)` tool result is returned.

## Invocation

```prolog
?- tool_invoke(Registry,
               [tool(example)],
               example,
               Args,
               [],
               Outcome,
               Trace).
```

An allowed success returns `ok(tool_execution{value:Value, trace:Trace})`.

Capability denial, malformed arguments, handler failure/exception, timeout, invalid result shape, oversized result, unknown tool, and stale registry are structured failures. A denied or schema-invalid call does not enter the handler.

Call options may tighten a registered `time_limit` or `max_output_bytes`; they cannot widen the registered ceiling.

## Read-only project tool

`register_project_read_tool/4` installs the first real tool:

```prolog
?- register_project_read_tool(Registry,
                              '/srv/project',
                              [max_file_bytes(8192), time_limit(1.0)],
                              Outcome).
```

It requires `tool(project_read)` and reads one UTF-8 regular file beneath the explicitly configured project root. Absolute paths, `.` / `..` traversal, backslash paths, NUL-containing paths, and symlink components are rejected. The file itself and the normalized result remain byte-bounded.

This is intentionally a narrow local capability. Registering it does not grant general `filesystem(read)`, network, process, or shell access.

## Typed-plan integration

```prolog
Caps = [tool(project_read)],
tool_registry_runtime_tools(Registry, Caps, RuntimeTools),
plan_run(Plan,
         Caps,
         [tools(RuntimeTools)],
         Inputs,
         Outcome).
```

Trusted supervised execution can bind those same adapters to an existing
authority owner without mutating registry-wide state:

```prolog
tool_registry_runtime_tools(
    Registry,
    ChildCaps,
    [authority_context(agent(RuntimeId, ChildId))],
    RuntimeTools).
```

The typed plan is validated for `tool(project_read)` before execution. The registry adapter independently rechecks the same capability at invocation time. Successful plan tool results include non-secret authorization/status metadata, and the plan trajectory records the `tool(project_read)` transition.

Deterministic CI covers allow/deny behavior, pre-invocation denial, narrowing, malformed arguments, numeric schema bounds, timeout, oversized output, project-root confinement, discovery, and typed-plan execution. Trusted same-repository CI additionally asks a real OpenRouter root controller, without a fixed plan or `planner_instruction`, to retrieve opaque context and execute the actual registered `project_read` tool against neutral repository fixture records. The live assertions use runtime transitions and independently inspect all bound evidence values rather than trusting model prose.
