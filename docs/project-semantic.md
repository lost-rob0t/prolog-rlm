# Project semantic knowledge

`rlm_project_semantic` is the #98 semantic layer above the #97 query layer:
it turns grouped Tree-sitter captures into closed, provenance-carrying
semantic facts about project source and exposes the public query surface that
the future project knowledge expert (#380) consumes directly.

```text
registered File + active grammar + active query pack
        -> #97 extraction observations (grouped matches/captures)
        -> semantic normalization (this layer)
        -> closed direct observations + bounded derived relations
        -> coherent Project KB snapshot (#99, later)
```

## Module layout

- `prolog/rlm_project_semantic.pl` — normalization, semantic knowledge,
  public query surface, bounded resolution, derived relations, persistence
  gating.
- `prolog/rlm_project_semantic_pack.pl` — inert standard adapter packs, the
  capture-name protocol, and `language_analysis_capability/2` capability
  declarations.
- `prolog/rlm_project_semantic_persist.pl` — durable journal adapter for the
  direct observations under `<project-root>/.kb/project-semantic/`.

## Adapter protocol

Packs are inert data; activation stays a trusted-host operation. Capture
names carry the semantic protocol inside a grouped #97 match:

```text
@<relation>                     principal observation node
@<relation>.<kind>              principal with an explicit closed symbol_kind
@<relation>.name                defining/using name text
@<relation>.callee              call target name
@<relation>.target              import target text
@<relation>.alias               import alias name
@<relation>.keyword             language keyword text (kind disambiguation)
```

The first principal of a relation pairs with the first `name`/`callee`/
`target`/`alias`/`keyword` detail of the same relation in the match. A
principal without the details its relation requires is reported as a
`skipped_reason/2` entry in the summary — never silently dropped, never
fabricated. Capture names that do not follow the protocol produce a typed
`invalid_capture_name`-class fault, so a malformed custom pack fails loudly.

`language_analysis_capability/2` is the closed per-language capability
declaration: a purpose without a capability row reports `unsupported` in the
summary instead of masquerading as zero matches. Analyzed files with zero
matches report `normalized(0)`.

## First language coverage

- **Python** — definitions (functions, classes), references (attribute
  usage), calls, imports (plain, aliased, `from`).
- **JavaScript** (the grammar available for the JavaScript/TypeScript family
  here; TypeScript grammars can be host-registered and flow through the same
  packs) — definitions (functions, classes, methods, arrow bindings),
  references (member usage), calls, imports, exports.
- **Common Lisp** — definitions (keyword-disambiguated: `defun` → function,
  `defmacro` → macro, etc.) and calls with a following element, so parameter
  lists such as `(x)` are not mistaken for calls. Zero-argument calls and
  package-system imports are declared limitations; imports/exports are
  reported `unsupported`.

For Prolog source projects, SWI-native xref/source semantics should
eventually supply stronger observations behind the same normalize surface;
that is a separate extraction backend, not Tree-sitter parity work.

## Identities

All identities stay distinct and closed:

```text
project                 project(P)
file                    source_file(Project, LocalId)
source generation/hash  file generation + sha256 (registered + content)
parse                   syntax_parse(File, Generation)
extraction              query_extraction(File, Generation)
query pack              query_pack(Language, Purpose, SourceHash)
syntax node             syntax_node(Parse, Path)
semantic observation    semantic_observation(Extraction, Sequence)
symbol                  project_symbol(Project, Name, Kind, DefinitionId)
reference               a direct project_semantic_reference observation
derived relation        computed on demand, never persisted
```

Every direct observation carries
`project_semantic_provenance{project, file, file_hash, file_generation,
content_hash, parse, parse_generation, language, backend, grammar_ref,
pack_identity, pack_sha256, pack_purpose, extractor, node, start_byte,
end_byte, start_point, end_point, extraction}` and a stable
`semantic_observation/2` identity.

## Public surface

```prolog
rlm_project_semantic_ready/0
project_semantic_normalize(+Registry, +File, +Source, +Options, -Outcome)
project_semantic_normalize_async/5, project_semantic_normalize_execute/5
project_semantic_knowledge_state(+Registry, +File, -State)  % current | stale(E) | none
project_semantic_definitions(+Registry, +File, ?Query, ?Definition)
project_semantic_references/4, calls/4, imports/4, exports/4
project_semantic_contains(+Registry, +File, ?Parent, ?Child)
project_semantic_call_reachable(+Registry, +File, +From, +To, -Outcome)
project_semantic_file_dependencies(+Registry, +Project, ?From, ?To, ?Support)
project_semantic_resolve(+Registry, +Project, ?Request, -Outcome)
project_semantic_symbol_index(+Registry, +Project, -Outcome)
project_semantic_observation_provenance(+Registry, +Observation, -Provenance)
project_semantic_registry_clear(+Registry)
```

The pack facade lives in `rlm_project_semantic_pack`:
`project_semantic_pack_languages/1`, `project_semantic_pack_register/3`
(inert), `project_semantic_pack_activate/3` (trusted), `project_semantic_
pack_source/3`, `project_semantic_standard_purposes/1`, and
`language_analysis_capability/2`.

Read predicates answer only while the extraction they were derived from is
the current extraction; a stale or missing gate yields no rows. Use
`project_semantic_knowledge_state/3` to distinguish `current`, `stale/1`,
and `none`.

## Resolution semantics

Extraction and resolution are separate operations. Normalization produces
direct observations only; `project_semantic_resolve/4` is an explicit,
bounded second pass over current knowledge with closed outcomes:

```prolog
ok(resolved(SymbolOrFile)) | ok(ambiguous(List)) | ok(unresolved)
| ok(external) | error(project_semantic_error{...})
```

Duplicate names in different files or scopes stay distinct
`project_symbol/4` identities and surface as `ambiguous`. Import targets
resolve against registered file paths; an unknown target stays `external`
rather than guessed. The bounded `project_semantic_symbol_index/3` emits the
`#288`-compatible `symbol_index{project, kinds, definitions, coherence}`
with `symbol_definition(symbol_ref{...}, source_span{...}, provenance)`
entries — definitions only from still-current extractions, with files whose
knowledge went stale reported through `coherence: partial(StaleFiles)` so a
consumer never mistakes a partial index for coherent current evidence.
`plan_graph_resolve_symbol/3` consumes this index directly.

## Freshness boundary

Freshness reuses #97 currentness. Replacing a query pack marks dependent
extractions stale, which invalidates the semantic observations derived from
them; a stale extraction cannot answer a current query, and `knowledge_
state/3` reports `stale(Extraction)` explicitly. Never publishing mixed
generations is structural: reads and the index re-check the live extraction
currentness on every access, and the currentness of semantic knowledge is
*never journaled* — the #97 extraction journal remains the authority, so a
restart cannot resurrect superseded semantic facts as current.

## Persistence

The journal mirrors the #97 project-query adapter: SWI `library(persistency)`
with `sync(close)` (the strongest process-crash boundary SWI-Prolog 10.0.2
supports), one journal per project identity, and hydration on first
registry use. Derived relations are recomputed on demand and are never
persisted. Raw captures stay in the #97 journal; there is no duplicate
source index.

## Runtime layering

```text
#97 structural captures
        -> #98 semantic normalization (this layer)
        -> #99 freshness/invalidation
        -> canonical project knowledge providers (#380 consumers)
```

No model calls, no scheduler, no `consult/1` of project source, and no
filesystem, Git, process, network, tool, capability, or authority access is
added by this layer. An expert registry or `project_knowledge_expert` is
explicitly out of scope (#377 owns the runtime; #380 owns the expert).