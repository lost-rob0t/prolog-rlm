# Project source and grammar registry

`rlm_project_source` is the declarative source-identity and parser-selection layer above the direct Tree-sitter FFI.

The boundary is intentionally split:

```text
Project / File / Language facts
          |
          v
parser backend + grammar registry
          |
          +--> swi_native
          |
          `--> tree_sitter configuration
                    |
                    v
              explicit activation
                    |
                    v
             rlm_tree_sitter (#94)
```

This module does not traverse syntax trees, run Tree-sitter queries, normalize symbols, or decide source freshness. `rlm_project_syntax` owns the #96 materialized CST layer; #97-#99 own structural queries, semantic normalization, and incremental freshness.

## Identity boundary

Project identities in this module are epistemic source identities. The host supplies them as closed ground data.

When #75 supplies a canonical security-sensitive `ProjectIdentity`, callers may reuse or reference that value. `rlm_project_source` does not derive authorization identity from `cwd`, paths, Git metadata, or parser output and does not make source registration a security decision.

Files have identities distinct from paths:

```prolog
source_file(Project, LocalId)
```

A file record carries path, content hash, generation, exclusion/vendor/generated flags, optional shebang and embedded-region metadata, and provenance. Two projects may contain the same relative path without sharing a file identity.

## Registry lifecycle

```prolog
project_source_registry_create(-Registry).
project_source_registry_destroy(+Registry).
```

Registries isolate Project/File/Language/grammar facts. Destruction also releases any active Tree-sitter language handles retained by the registry.

## Projects and files

```prolog
project_source_project_register(+Registry, +Project, +Meta, -Outcome).
project_source_project(+Registry, ?Project, ?Meta).

project_source_file_register(+Registry, +Project, +FileSpec, -Outcome).
project_source_project_file(+Registry, ?Project, ?File).
project_source_file(+Registry, ?File, ?Record).
```

Example:

```prolog
project_source_registry_create(R),
project_source_project_register(
    R,
    project(my_repo),
    _{provenance:_{origin:operator}},
    ok(project(project(my_repo)))
),
project_source_file_register(
    R,
    project(my_repo),
    _{ id:main,
       path:"src/main.py",
       hash:"sha256:...",
       generation:3,
       vendor:false,
       generated:false,
       excluded:false
     },
    ok(File)
).
```

`File` is not the path. Later parse/syntax facts can refer to it without packing language/path/version into one mega-term.

## Language evidence

The first detector surface is deliberately small and inspectable:

- extension evidence;
- trusted language-registry extension evidence;
- shebang evidence;
- explicit trusted-host override.

Evidence is queryable:

```prolog
project_source_language_evidence(
    Registry,
    File,
    Language,
    Source,
    Confidence
).
```

For example:

```prolog
extension_language('.py', python).
```

Trusted hosts can add another language without changing this module by
registering a `tree_sitter` backend with `extensions` metadata. The resulting
evidence is reported as `registered_extension(Extension)` rather than
masquerading as a built-in detector fact.

Language resolution returns structured states rather than hiding an imperative guess:

```text
known
unknown
ambiguous
unsupported
explicit_override
```

An override remains visibly an override. If an override names a language with no known parser backend, its support state remains `unsupported(no_parser_backend)`.

## Parser backends

Built-in backend declarations include:

```prolog
python       -> tree_sitter
javascript   -> tree_sitter
typescript   -> tree_sitter
nim          -> tree_sitter
common_lisp  -> tree_sitter
markdown/json/org -> tree_sitter
c/cpp/lua    -> tree_sitter
shell        -> tree_sitter
prolog       -> swi_native
```

Custom backends may be registered as `external(Name)` through trusted host code.

Use:

```prolog
parser_for_file(+Registry, +File, -Outcome).
```

A known Tree-sitter language with no registered grammar is not `unknown`; it returns an `unsupported` selection with reason `missing_grammar`.

Prolog source selects `swi_native`. Tree-sitter remains optional for editor-style syntax observations and is not promoted over SWI-native semantic analysis merely for symmetry.

## Tree-sitter grammar records

Grammar registration is data only:

```prolog
ts_grammar_register(+Registry, +Language, +GrammarSpec, -Outcome).
ts_grammar_unregister(+Registry, +Language, -Outcome).
ts_grammar(+Registry, +Language, -Grammar).
ts_grammars(+Registry, -Grammars).
```

A grammar spec has this shape:

```prolog
_{ identity:package(tree_sitter_python, "0.23.6"),
   library:"/trusted/lib/tree-sitter-python.so",
   symbol:tree_sitter_python,
   abi:unknown,
   version:"0.23.6",
   provenance:_{origin:nix_store}
 }.
```

`identity` is optional. If omitted, the registry derives a content identity. Either way the durable `grammar_ref(Language, Hash)` includes language, identity, library, symbol, declared ABI, version, and provenance. A raw library path is never the sole durable grammar identity.

Adding another compatible grammar requires data, not a C edit.

`rlm_project_grammar_pack` provides inert standard-pack metadata for C, Lua,
Tree-sitter query, Python, JavaScript, Markdown, JSON, Org, Common Lisp, and
Nim. `project_grammar_pack_register/4` accepts additional host-provided pack
entries through the same boundary. The Nix flake installs the standard set as
`.#tree-sitter-grammars`; see [project-syntax.md](project-syntax.md).

## Registration is not activation

This distinction is security-relevant:

```text
register grammar
  = store closed declarative data

activate grammar
  = trusted host chooses to load native code through #94
```

`ts_grammar_register/4` never `dlopen`s a path.

Native activation is explicit:

```prolog
ts_grammar_activate(+Registry, +Language, -Outcome).
ts_grammar_deactivate(+Registry, +Language, -Outcome).
```

The host must already have loaded `rlm_tree_sitter`. This keeps normal `prolog-rlm` module loading independent of a Tree-sitter installation.

Activation:

1. resolves the exact registered grammar record;
2. calls the generic #94 loader;
3. validates actual grammar/runtime ABI compatibility;
4. checks an explicitly declared ABI when present;
5. publishes an active state only if the same grammar registration is still current.

Failed or incompatible activation leaves the declarative grammar configured but inactive.

Native handles are internal and are never returned by `ts_grammar/3` or `ts_grammars/2`.

## Parser and grammar selection

```prolog
parser_for_file(+Registry, +File, -Outcome).
grammar_for_file(+Registry, +File, -Outcome).
```

Tree-sitter selections distinguish:

```text
missing grammar -> unsupported
registered only -> configured
ABI-validated activation -> ready
```

Selections carry file hash/generation and language-evidence provenance so #96 can bind parse generations to the exact source/parser configuration that produced them.

## Authority and execution

This registry does not grant:

- filesystem authority;
- process authority;
- network authority;
- tool capabilities;
- model execution authority;
- trusted project policy.

Source text, paths, grammar metadata, and parser observations are epistemic data. They do not become executable Prolog and are never auto-`consult`ed.

A model-facing workflow may inspect sanitized registry data, but native grammar activation and host overrides are trusted library/operator operations unless a future mediated tool explicitly narrows them.

## Relationship to the next slices

```text
#94 direct native FFI              complete substrate
#95 Project/File/Language registry this module
#96 CST -> versioned syntax facts  rlm_project_syntax
#97 structural query/capture API
#98 semantic symbols/relations
#99 incremental freshness
```

`rlm_project_syntax` consumes file identity, hash/generation, parser selection, grammar reference and active grammar provenance from this module. It does not invent another Project/File registry, and registry destruction clears its materialized observations.
