# Direct Tree-sitter FFI

`rlm_tree_sitter` is the native parser boundary for issue #94. It binds
SWI-Prolog directly to the Tree-sitter C runtime. There is no Python, Node,
Nim, parser service, or subprocess between Prolog and `libtree-sitter`.

```text
SWI-Prolog
    |
    | SWI foreign language interface
    v
c/rlm_tree_sitter.c
    |
    v
libtree-sitter
    |
    +-- host-provided grammar shared libraries
```

The C layer intentionally knows nothing about projects, language detection,
symbols, SPEC, VERIFY, or language-specific extraction. Those belong to later
Prolog layers (#95 through #99).

## Build

Tree-sitter is an **optional host-loaded native parser boundary**, not a
prerequisite for installing or loading the core `prolog_rlm` SWI pack. The
repository's default `make` target therefore leaves native parser support
unbuilt. Hosts that select Tree-sitter must build it explicitly.

The native module requires SWI-Prolog development headers, a C compiler,
`pkg-config`, and Tree-sitter development files.

On Ubuntu 24.04 the deterministic CI setup is:

```sh
sudo apt-get update
sudo apt-get install --yes \
  swi-prolog-nox \
  build-essential \
  pkg-config \
  libtree-sitter-dev

make tree-sitter-ffi
```

The result is written to the repository-local `foreign/` directory using
SWI-Prolog's configured shared-object extension. Loading `rlm_tree_sitter`
without that library is expected to fail; the host must opt into the native
build before selecting that parser backend.

The deterministic grammar fixtures use generated parser sources already
packaged by Ubuntu. They do not require a language-specific runtime or grammar
generator during the test:

```sh
sudo apt-get install --yes \
  tree-sitter-c-src \
  tree-sitter-lua-src \
  tree-sitter-query-src

make tree-sitter-test-grammars
```

These fixtures prove that one generic FFI can load three independent grammars.
They are build products and are not committed.

## Grammar loading is trusted native code

A Tree-sitter grammar shared library is native machine code. Loading it can run
shared-library initializers before the grammar entry function is called.
Therefore `ts_language_load/3` is a trusted host/operator API, not a capability
that model output or arbitrary repository data receives merely because parsing
is available.

The later grammar registry in #95 should admit host-selected grammar identities
and map languages to them. It must not turn model-provided paths into ambient
`dlopen` authority.

The loader is generic:

```prolog
:- use_module(prolog/rlm_tree_sitter).

ts_language_load(
    '/trusted/grammars/tree-sitter-python.so',
    tree_sitter_python,
    Language
).
```

Adding another compatible grammar does not require editing the FFI source.

## ABI compatibility

Grammar compatibility is checked before a language handle is returned.

```prolog
ts_runtime_abi(Minimum, Maximum).
ts_language_abi(Language, Abi).
ts_language_compatible(Language, Outcome).
```

The binding compiles against the installed Tree-sitter headers and accepts only
grammars whose language ABI is within the runtime's advertised minimum and
maximum range. It supports the older `ts_language_version()` API used by stable
Tree-sitter runtimes and the newer `ts_language_abi_version()` API selected by
current headers.

This is an ABI policy, not a claim that the Tree-sitter C runtime exposes its
full package semantic version at runtime.

## Parser and tree lifecycle

Native resources are represented by SWI foreign BLOBs rather than integer
addresses.

Ownership is:

```text
Language handle
    |
    +-- Parser dependency
    |
    +-- Tree dependency
            |
            +-- Node handles
```

A parser retains its configured grammar. A parsed tree retains the grammar
independently of the parser. A node retains the tree resource. Consequently,
garbage-collecting a public tree handle while nodes are still reachable cannot
silently leave those nodes pointing into freed native memory.

Explicit close predicates are idempotent:

```prolog
ts_language_close(Language, ok(closed)).
ts_parser_close(Parser, ok(closed)).
ts_tree_close(Tree, ok(closed)).
```

A second close returns `ok(already_closed)`. Explicitly closing a tree
invalidates retained nodes; subsequent node access raises a structured
`closed_tree` error rather than dereferencing stale native state.

## Thread ownership

`TSParser` is mutable, and this first binding does not pretend sharing one
parser across SWI engines is safe. Parsers and trees are thread-affine to the
SWI-Prolog thread that created them.

Cross-thread use raises:

```prolog
error(tree_sitter_error(wrong_thread, Detail), rlm_tree_sitter)
```

Use one parser per logical parse worker/context. Later parallel indexing can
create independent parser instances. The binding does not add a second runtime
scheduler.

## Parsing and traversal

The first surface is deliberately small:

```prolog
ts_parser_create(-Parser).
ts_parser_set_language(+Parser, +Language, -Outcome).
ts_parse_string(+Parser, +Source, -Tree).

ts_tree_root(+Tree, -Node).
ts_node_type(+Node, -Type).
ts_node_named(+Node).
ts_node_has_error(+Node).
ts_node_start_byte(+Node, -Byte).
ts_node_end_byte(+Node, -Byte).
ts_node_start_point(+Node, -Point).
ts_node_end_point(+Node, -Point).
ts_node_child_count(+Node, -Count).
ts_node_child(+Node, +Index, -Child).
ts_node_named_child(+Node, +Index, -Child).
ts_node_field(+Node, +FieldName, -Child).
```

Example:

```prolog
ts_parser_create(Parser),
ts_parser_set_language(Parser, Language, ok(configured)),
ts_parse_string(Parser, "int answer = 42;", Tree),
ts_tree_root(Tree, Root),
ts_node_type(Root, translation_unit),
ts_node_named_child(Root, 0, Declaration),
ts_node_start_byte(Declaration, Start),
ts_node_end_byte(Declaration, End).
```

Tree-sitter's recovery behavior is preserved. Incomplete source can still yield
a tree; `ts_node_has_error/1` exposes error-bearing syntax instead of requiring
the entire file to parse cleanly.

## Text and ranges

Atoms and strings are passed to Tree-sitter as UTF-8. Byte offsets are therefore
UTF-8 byte offsets, not Prolog character indices.

Points are returned as zero-based:

```prolog
point(Row, Column)
```

where the column follows Tree-sitter's byte-oriented point semantics.

## Errors

Native failures are surfaced as normal Prolog exceptions. FFI-specific failures
use:

```prolog
error(tree_sitter_error(Code, Detail), rlm_tree_sitter)
```

Current codes include:

- `load_library`
- `load_symbol`
- `platform_abi`
- `null_language`
- `incompatible_language_abi`
- `closed_language`
- `closed_parser`
- `closed_tree`
- `parser_without_language`
- `language_lifetime`
- `parse_failed`
- `wrong_thread`
- `stale_handle`

Normal SWI type, domain, resource, and representation errors are used where
those contracts already describe the failure precisely. Missing node fields
fail logically; an invalid child index is a domain error.

## Scope after #94

This module is mechanics only. The follow-up dependency chain remains:

- #95: declarative Project/source/language/grammar registry;
- #96: canonical syntax/symbol fact extraction;
- #97: project-KB/index materialization;
- #98: context/search integration;
- #99: verified workflow adoption.
