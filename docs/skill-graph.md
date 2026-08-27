# Skill catalog graph

`rlm_skill_graph` exposes the inert relationship graph already declared by normalized `rlm_skill` catalog entries. It is a read-only inspection and validation surface; it is not a selector, lifecycle store, capability system, or execution engine.

## Ownership

The canonical flow remains:

```text
SKILL.md
  -> rlm_skill normalization
       |-> prompt_unit -> rlm_prompt_compiler
       `-> rlm_skill_graph
```

The graph never reparses YAML or JSON, reads Markdown bodies, loads resource contents, or infers relationships from prose. `rlm_prompt_compiler` remains the authority for provider-visible activation and packing.

## API

```prolog
skill_catalog_graph(+Catalog, -Outcome).
```

A successful result is a ground `skill_graph{...}` containing deterministic `nodes`, `edges`, `diagnostics`, and a material `fingerprint`.

Nodes expose only inert normalized metadata such as `skill(Name)`, category, invocation mode, source/root references, relative directory, and the host-derived skill fingerprint. Instruction bodies and resource contents are excluded.

## Relationships

The graph projects the normalized relation fields:

- `requires` — directed hard dependency;
- `suggests` — directed soft relationship;
- `conflicts` — symmetric semantic conflict represented as one canonically ordered edge;
- `supersedes` — directed suppression/replacement declaration.

Targets remain the existing closed compiler-unit terms such as `skill(Name)`, `tool(Name)`, and `resource(Name)`. Graph membership does not make a target available or executable.

## Validation

Graph construction fails structurally for self-require/conflict/supersede edges, unresolved hard skill dependencies, hard skill requirement cycles, supersession cycles, requires+conflicts contradictions, and requires+supersedes contradictions.

Missing soft/suppressive skill targets are retained as explicit `unresolved_target` diagnostics. Relationships to non-skill units are retained as `external_target` diagnostics because a skill catalog alone cannot prove whether another host catalog resolves them.

The graph does not silently repair invalid metadata.

## Security boundary

Graph metadata cannot grant capabilities, authority, effects, provider visibility, mandatory context, or execution. Model text never becomes a graph edge unless trusted package metadata has already passed `rlm_skill`'s closed normalization. No handler or callable is stored in graph output.

Lifecycle promotion/rollback belongs to #170, evolution belongs to #171, and product-specific inspection/UI belongs downstream. This module only supplies the generic normalized graph contract frozen by #173 and implemented by #250.
