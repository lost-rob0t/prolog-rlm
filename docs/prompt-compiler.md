# Prompt compiler

`rlm_prompt_compiler` is the symbolic authority for deciding which declarative prompt units are visible to a provider on a request. It compiles a larger trusted catalog into a bounded, inspectable projection. It does **not** execute tools, grant capabilities, own effect authority, or turn model text into callable Prolog.

The core separation is:

```text
registered != available != active != authorized
```

A unit can be registered and executable by the trusted runtime without being active in the current provider-visible projection. Conversely, making a schema active never grants permission to invoke it.

## Public surface

The module exports the catalog lifecycle and compilation surface:

```prolog
prompt_catalog_create(-Catalog).
prompt_catalog_destroy(+Catalog).
prompt_catalog_register(+Catalog, +UnitSpec, -Outcome).
prompt_catalog_register_tool_registry(+Catalog, +Registry, +Options, -Outcome).
prompt_catalog_search(+Catalog, +Query, +Options, -Outcome).
prompt_catalog_search_schema(-Schema).
prompt_catalog_search_handler(+Catalog, +Arguments, +Metadata, -Outcome).
prompt_compile(+Catalog, +Input, +Options, -Outcome).
prompt_recompile(+Compiled0, +Event, +Options, -Outcome).
prompt_explain(+Compiled, +Unit, -Outcome).
prompt_render(+Compiled, +Provider, -Outcome).
prompt_compiler_context_units(+Compiled, -Units).
prompt_compiler_tool_schemas(+Compiled, -Schemas).
```

Catalog entries are inert declarative data. Tool-registry import sanitizes schemas and never imports handlers, preflight callables, transport/session handles, credentials, authority continuations, or other executable runtime state.

## Compilation modes

`prompt_compile/4` uses normal contextual compilation unless the trusted host supplies `mode(all_tools)`.

- **compiled**: contextual evidence, policy, capability eligibility, dependencies/conflicts and the shared context budget determine the active projection.
- **all_tools**: compatibility/debug mode that bypasses contextual narrowing for eligible tools while preserving the same compiler, capability and packing boundaries.

`all_tools` is not an authority bypass. A visible tool still has to pass the canonical runtime schema, capability, authority and effect checks when invoked.

## Completion integration

`rlm_completion` deliberately keeps two products from a tool registry:

```text
registry
  |-- capability-filtered trusted runtime bindings --> plan execution / authority / effects
  `-- sanitized declarative schemas ----------------> rlm_prompt_compiler --> root planner
```

The default completion option is `prompt_compile_mode(compiled)`. `prompt_compile_mode(all_tools)` preserves compatibility visibility through the same compiler path. Any other trusted mode fails closed as:

```prolog
completion_error{
    phase:prompt_compile,
    kind:invalid_prompt_compile_mode,
    mode:Mode,
    ...
}
```

The failure occurs before planner dispatch. Negative tests assert this structured failure while the test suite remains green.

When a registry is supplied, completion imports its schemas into an ephemeral compiler catalog, compiles the current query under the current capability and context-budget policy, extracts `prompt_compiler_tool_schemas/2`, and destroys the temporary catalog with `setup_call_cleanup/3`. The planner receives **Active tool schemas**, not the raw registry inventory.

Direct trusted `tools(...)` runtime bindings are execution inputs, not an implicit provider-visible schema catalog. If a host wants provider-visible declarative discovery, it should register schemas through the canonical registry/compiler path instead of assuming possession implies visibility.

## Budget and context ownership

Final packing belongs to `rlm_context_budget`; the prompt compiler does not introduce a second token optimizer. Compiler units use the same bounded context-unit model as the rest of the runtime so selected representations and charged representations stay aligned.

Permanent/default RLM operating skills such as `rlm-operate`, `rlm-recurse`, `rlm-facts`, and `rlm-constraints` are host-owned compiler policy. Skill/package metadata may describe a unit but cannot pin itself permanently, grant a capability, or override trusted denial.

Compiled provider context is disposable. Persistent KB/history, artifacts, graph state, runtime observations, authority state, and effect journals remain separate semantic stores.

## Delegation and child agents

Typed delegation policy may carry compiler-authenticated role/skill metadata into the canonical `rlm_subagent` path, but compilation never grants child authority. Child capabilities and authority continue to narrow through the runtime. A child learning that a tool exists does not restore a capability withheld by its parent.

The root planner receives the compiled provider-visible RLM context through the
existing trusted completion/provider-context path. Plan execution is a separate
task-model boundary: planner instructions are not projected onto model steps,
because planner structure is not task output. Do not add a second compiler in
recursive plan execution or downstream products.

## Security invariants

- Model/user prose is evidence, never trusted host policy.
- Model-generated data is never meta-called as arbitrary Prolog.
- Visibility does not imply registration, possession, capability, authority, or effect permission.
- Catalog import must remain declarative and secret-free.
- Required unavailable/denied dependencies fail explicitly; they are not silently dropped to make a budget fit.
- Provider-specific rendering may change representation, but it must not change authorization semantics.
- Runtime/downstream adapters consume the compiler result; they do not reimplement selection policy.

## Verification expectations

For provider-surface changes, internal `selected` or `active_units` assertions are not enough. Tests should capture the exact provider/planner request and prove the intended units are present or absent. Where live-provider behavior is affected, the repository's credential-backed OpenRouter lanes remain part of the exact-head gate.

Related design/research: issue #176, issue #183, and `research/RLM-RESEARCH-011-managed-context-tool-discovery.org`.
