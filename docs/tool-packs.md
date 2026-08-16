# Tool-pack loading boundary

`prolog-rlm` core owns tool contracts, schemas, registry behavior, capability
enforcement, async invocation, and the loading ABI. It is not the home for a
growing collection of concrete filesystem, process, git, network, scraping, or
OSINT tools.

External trusted libraries declare packs with a multifile fact:

```prolog
:- multifile rlm_tool_loader:tool_pack/2.

rlm_tool_loader:tool_pack(
    filesystem,
    my_filesystem_tools:load_tool_pack).
```

The loader has the contract:

```prolog
load_tool_pack(+Registry, -Outcome).
```

A loader normally registers schemas and handlers with `rlm_tool:tool_register/4`.
It must return `ok(Value)` or `error(Error)`.

## Loading one pack

```prolog
?- tool_registry_create(Registry),
   rlm_load_tools(Registry, filesystem, Outcome).
```

The intended external package surface can therefore grow as separate packs:

```prolog
rlm_load_tools(Registry, filesystem, Outcome).
rlm_load_tools(Registry, git, Outcome).
rlm_load_tools(Registry, process, Outcome).
rlm_load_tools(Registry, network, Outcome).
rlm_load_tools(Registry, mcp, Outcome).
```

Only packs actually declared by loaded trusted Prolog libraries are available.
An unknown or multiply declared pack fails closed with a structured
`tool_loader_error{}`.

## Loading all declared packs

```prolog
?- rlm_load_all_tools(Registry, Outcome).
```

`rlm_load_all_tools/2` means all packs declared in the current host runtime. It
does not discover arbitrary packages from the network and does not install
software.

## Loading is not authorization

Loading a pack registers tool contracts and handlers. It does **not** add
`tool(Name)` capabilities to a session, agent, graph, or model request.

For example, after a pack registers `filesystem_read`, this still fails closed:

```prolog
?- tool_invoke(Registry,
               [],
               filesystem_read,
               _{path:"README.md"},
               [],
               Outcome,
               Trace).
```

The caller must separately hold the exact capability required by the tool.
Authority policy is also separate from loading. The `dangerous` authority tier
never widens capabilities, schemas, confinement, budgets, network policy, tool
validation, or tracing.

## Async boundary

Pack discovery/loading is immediate trusted host configuration and is not forced
through a Future. Latency-bearing **tool invocation** is different:

```text
tool_invoke_execute
        |
        +--> tool_invoke_async -> Future
        |
        +--> tool_invoke -> same async operation -> await Future
```

External pack handlers therefore inherit the canonical invocation machinery
without implementing their own sync/async business-logic trees.
