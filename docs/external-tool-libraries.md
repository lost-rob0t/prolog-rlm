# External tool libraries

`prolog-rlm` owns the registry, loading, validation and policy contracts. It does not own the production filesystem, Git, process, network or MCP server catalogs.

The boundary deliberately separates four ideas that must not collapse into one another:

```text
external library declaration
        |
        v
availability through category loading
        |
        v
capability permission at invocation
        |
        v
host authority mediation for the normalized effect
```

Loading controls **availability**. Capabilities control **invocation permission**. Authority controls **human mediation** of an already-valid operation. None of them substitutes for schema validation, confinement or hard execution policy.

## Declaring a library and category

The original trusted loader ABI remains valid:

```prolog
:- multifile rlm_tool_loader:tool_pack/2.

rlm_tool_loader:tool_pack(acme_filesystem,
                          acme_tools:load_filesystem).
```

A category-aware external library adds a sanitized manifest for the same pack:

```prolog
:- multifile rlm_tool_loader:tool_pack_manifest/2.

rlm_tool_loader:tool_pack_manifest(
    acme_filesystem,
    tool_pack_manifest{
        library:acme_tools,
        category:filesystem,
        tools:[tool_export{
                   name:project_search,
                   capability:tool(project_search),
                   effect:read
               }]
    }).
```

A **pack is one deterministic category-scoped loading unit**. A library that contributes several categories declares several packs with the same `library` value. This prevents loading one category from accidentally loading unrelated categories while still allowing several independent libraries to contribute to the same category.

The conventional categories are:

- `filesystem`
- `git`
- `process`
- `network`
- `mcp`

Core does not hard-code a production catalog merely to make those atoms exist. A category is discoverable when an installed/loaded external library advertises it. Third-party libraries may advertise additional categories without modifying core.

Manifest metadata is declarative. It contains library/category identity plus sanitized tool name, capability and effect metadata. Trusted loader predicates remain internal host state and are never returned by the discovery API.

## Discovery

The immediate host-facing discovery predicates are:

```prolog
rlm_tool_packs(Packs).
rlm_tool_libraries(Libraries).
rlm_tool_categories(Categories).
rlm_tool_catalog(Catalog).
```

`rlm_tool_catalog/1` returns sanitized declarative pack metadata. It does not return loader predicates or registered tool handlers.

Actual registered schemas are still obtained from the ordinary `rlm_tool` registry after loading.

## Loading one category

Use the established explicit-registry API:

```prolog
rlm_load_tools(Registry, filesystem, Outcome).
```

When `filesystem` is an advertised category, every pack in that category is preflighted and loaded in deterministic pack-name order. Packs in `git`, `process`, `network`, `mcp` or third-party categories are not loaded as a side effect.

For backward compatibility, if a selector is not an advertised category but exactly names a legacy pack, that one pack can still be loaded directly.

An unknown selector fails closed with a structured `unknown_tool_category` error that includes currently discoverable categories and declared packs.

## Loading all installed packs

```prolog
rlm_load_all_tools(Registry, Outcome).
```

Load-all resolves every declared pack deterministically and performs conflict preflight before executing trusted loaders. It does **not** grant any capability and does **not** change authority.

## Idempotency

Successful pack loads are recorded per live registry.

The first successful load reports `status:loaded`. Loading the same pack/category again in the same registry reports `status:reused` and does not call the trusted loader again, so duplicate registration is not used as the idempotency mechanism.

Ordinary `tool_registry_destroy/1` automatically reclaims the loader's per-registry idempotency bookkeeping when `rlm_tool_loader` is loaded. The loader observes the registry-liveness lifecycle through SWI-Prolog's named predicate listener; core does not import the loader or transfer registry ownership to it. Cleanup is scoped, deterministic and idempotent.

Hosts that explicitly manage loader state independently of a registry may still call:

```prolog
rlm_tool_loader_forget_registry(Registry).
```

That explicit operation remains useful for unusual host lifecycles, but normal registry destruction does not require it.

## Conflict semantics

Before any loader in a requested category or load-all operation executes, core compares the sanitized manifests.

If two contributing packs advertise the same tool name, loading fails with structured `tool_name_conflict` metadata naming both contributing packs/libraries/categories. Load order never silently picks a winner.

If a requested manifest advertises a tool name that is already present in the target registry outside the loader's recorded pack state, loading also fails structurally instead of relying on `tool_register/4` to discover the collision after partial loading.

Malformed manifests, duplicate manifest declarations, malformed trusted loader declarations and invalid loader outcomes fail structurally.

## Capability and authority separation

A loader may register schemas and trusted handlers. It may not grant the corresponding capabilities.

For example, after loading a pack containing `alpha_echo`, this still fails at capability authorization:

```prolog
rlm_load_tools(Registry, filesystem, ok(_)),
tool_invoke(Registry, [], alpha_echo, _{value:7}, [], Outcome, Trace).
```

The caller must explicitly supply the matching capability before invocation can continue.

Loading also does not call `rlm_set_authority/*` and therefore cannot widen or otherwise change host authority. Unset authority still defaults to `approve_diff`; the canonical modes remain `approve_diff`, `allow_once`, `allow_session` and `dangerous`.

`dangerous` can skip interactive approval. It does not bypass schema, capability, confinement or hard execution policy.

## MCP category

`prolog/rlm_mcp_tool_pack.pl` advertises the `mcp` category and registers only inert, read-only discovery schemas:

- `mcp_servers`
- `mcp_server_inspect`

Loading the category:

```prolog
rlm_load_tools(Registry, mcp, Outcome).
```

never installs, starts, stops, restarts or connects an MCP server, never imports remote tools and never grants either discovery or imported-tool capabilities.

MCP lifecycle remains explicit through `rlm_mcp_server`. Remote tool import remains explicit through `rlm_mcp_tool` after the host has explicitly established a connection. Those latency-bearing operations continue to use the canonical execute -> async Future -> synchronous await direction and shared host authority established by the runtime.

The loader-facing MCP discovery adapter sanitizes declaration data before exposing it as tool output. Trusted fixture handlers/existing transport handles are not disclosed.

The #52 lifecycle policy boundary is complete on `main`: server declarations use first-class `env_ref/1` / `config_ref/1` references and closed host-controlled installer/stdio execution profiles, with package/version/configuration/cwd policy checked before process execution. Secret values are resolved only inside the exact trusted authority-permitted continuation. See `docs/mcp-lifecycle.md` for the canonical lifecycle contract. These hard execution rules remain separate from loader availability, capability permission, and authority mediation.

## Third-party example

A third party can add a new `database` category without a core patch:

```prolog
:- module(acme_database_tools, []).

:- use_module(prolog(rlm_tool)).
:- use_module(prolog(rlm_tool_loader)).

:- multifile rlm_tool_loader:tool_pack/2.
:- multifile rlm_tool_loader:tool_pack_manifest/2.

rlm_tool_loader:tool_pack(acme_database,
                          acme_database_tools:load_database).

rlm_tool_loader:tool_pack_manifest(
    acme_database,
    tool_pack_manifest{
        library:acme_database_tools,
        category:database,
        tools:[tool_export{
                   name:database_lookup,
                   capability:tool(database_lookup),
                   effect:read
               }]
    }).

load_database(Registry, Outcome) :-
    Schema = tool_schema{
                 name:database_lookup,
                 description:"Bounded database lookup",
                 capability:tool(database_lookup),
                 effect:read,
                 arguments:_{type:object,
                             required:[key],
                             additional_properties:false,
                             properties:_{key:_{type:string}}},
                 result:_{type:any},
                 limits:_{time_limit:1.0, max_output_bytes:4096}
             },
    rlm_tool:tool_register(Registry,
                           Schema,
                           acme_database_tools:database_lookup,
                           Outcome).
```

The loader callable above is trusted host code because it appears only in the multifile declaration. A model can discover the sanitized `database` category and tool metadata, but it cannot select or synthesize an arbitrary callable through the loader API.
