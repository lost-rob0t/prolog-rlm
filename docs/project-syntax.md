# Versioned project syntax observations

`rlm_project_syntax` projects a temporary Tree-sitter CST into bounded,
inspectable Prolog observations tied to the existing `rlm_project_source`
Project and File identities.

```text
registered File + active grammar + supplied source
        -> temporary native parse
        -> bounded named/all-node traversal
        -> atomic publication of closed Prolog observations
        -> native tree close
```

The project KB is not code-only. The same generic projection handles source
languages and structured documents such as Markdown, JSON, Org, and data or
configuration formats for which the host supplies a compatible grammar.

## Materialization

```prolog
project_syntax_materialize(+Registry, +File, +Source, +Options, -Outcome).
project_syntax_materialize_async(+Registry, +File, +Source, +Options, -Future).
project_syntax_materialize_execute(+Registry, +File, +Source, +Options, -Outcome).
```

The synchronous facade awaits the Future returned by the async surface; both
run the same execute predicate on `rlm_async`. Cancellation interrupts the
worker and native parser/tree cleanup remains protected by
`setup_call_cleanup/3`.

Options are:

- `mode(named)` (default) or `mode(all)`;
- `max_source_bytes(N)` (default `1048576`);
- `max_nodes(N)` (default `10000`);
- `max_depth(N)` (default `256`);
- `timeout_seconds(Number)` (default `30.0`);
- `include_excluded(Boolean)`, `include_vendor(Boolean)`, and
  `include_generated(Boolean)`, all false by default.

A complete publication returns `ok(project_syntax_summary{...})`. Node/depth
exhaustion returns `partial(project_syntax_summary{...})`, and the stored parse
record remains explicitly `partial`. Source-size or file-policy refusal returns
`blocked(project_syntax_error{...})` without publishing a parse.

Malformed source is not automatically a failed parse. Tree-sitter recovery is
published as `tree_status:recovered_with_errors` plus `missing`, `error`, and
`contains_error` node observations where available.

## Version and identity

```prolog
project_syntax_current_parse(+Registry, +File, -Parse).
project_syntax_parse_record(+Registry, ?Parse, ?Record).
project_syntax_node(+Registry, ?Node, ?Parse, ?Type).
```

Parse identities have the closed form `syntax_parse(File, Generation)`. Node
identities have the closed form `syntax_node(Parse, Path)`, where `Path` is the
bounded child-index path in that projection. Neither identity contains a native
pointer.

A new materialization makes the prior generation `stale`; historical facts
remain explicitly queryable. Node identity is stable only within one parse
generation. This layer makes no cross-generation identity promise. Concurrent
publication cannot replace a newer generation with an older one, and registry
destruction prevents in-flight work from republishing orphan observations.

An admitted refresh is `indeterminate(pending(Generation))` until its bounded
source identity is established. Current queries do not return the prior parse
during that interval. A timeout, cancellation, or oversized source therefore
cannot let older in-flight work restore stale state. A proven hash mismatch is
a rejected admission and restores the prior matching parse as current.

If a changed refresh is blocked or fails before publication, the previous
generation is invalidated rather than left falsely current. A non-`unknown`
File hash must match the supplied source SHA-256 (raw hex or `sha256:` form)
before the parse can claim that File generation as provenance.

## Observation queries

```prolog
project_syntax_named(+Registry, ?Node).
project_syntax_parent(+Registry, ?Node, ?Parent).
project_syntax_child(+Registry, ?Parent, ?Index, ?Child).
project_syntax_field(+Registry, ?Parent, ?Field, ?Child).
project_syntax_span(+Registry, ?Node, ?SourceSpan).
project_syntax_points(+Registry, ?Node, ?StartPoint, ?EndPoint).
project_syntax_error(+Registry, ?Node, ?Kind).
project_syntax_node_provenance(+Registry, ?Node, ?Provenance).
```

Every node resolves to Project, File, file hash/generation, exact content hash,
parse generation, language, backend, grammar reference, source range, and
current/stale state.

## Checked text reads

```prolog
project_syntax_node_text(+Registry, +Node, +Options, -Outcome).
```

Source is stored once per parse, not copied into every node. Text lookup slices
the exact parse source with Tree-sitter's UTF-8 byte offsets. It rejects stale
generations by default and enforces `max_bytes(N)` (default `65536`). Trusted
historical inspection can pass `allow_stale(true)`.

## Grammar installation

The flake provides a pinned baseline bundle:

```sh
nix build .#tree-sitter-grammars
```

It installs C, Lua, Tree-sitter query, Python, JavaScript, Markdown, JSON, Org,
Common Lisp, and Nim grammar libraries. `nix develop` sets
`RLM_TREE_SITTER_GRAMMAR_DIR` to the same bundle.

Registration remains inert and activation remains explicit:

```prolog
project_standard_grammar_pack_register(Registry, Directory, ok(_)),
ts_grammar_activate(Registry, markdown, ok(activated(_))).
```

There is intentionally no finite "all languages" hard-coded list.
`project_grammar_pack_register/4` accepts additional trusted grammar entries,
and `project_source_language_register/5` metadata can supply `extensions` for
new languages. They use the same generic parser and projection without C or
core changes. No API downloads, compiles, loads, or activates native code from
model/source data.

## Scope

This is the generic CST layer from #96. It does not implement Tree-sitter query
packs (#97), normalize symbols or references (#98), incrementally reparse or
invalidate semantic facts (#99), or grant filesystem/tool/execution authority.
The #97 query layer is a sibling observation provider below the canonical
project-KB boundary; it does not implement direct-mode expert tools or symbolic
planner behavior.
