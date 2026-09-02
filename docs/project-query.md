# Project query observations

`rlm_project_query` is the structural query layer below the semantic project
knowledge boundary. It executes inert Tree-sitter query packs against a
registered source file and publishes closed, provenance-rich observations. It
does not normalize symbols, select experts, execute model-authored Prolog, or
change direct/symbolic runtime behavior.

```text
registered File + active grammar + active query pack
        -> temporary native parse and query cursor
        -> bounded grouped matches/captures
        -> closed syntax_node(Parse, Path) identities
        -> extraction observation and project-query journal
```

## Query packs

Registration is inert data. Activation is a separate trusted host operation:

```prolog
project_query_pack_register(
    Registry,
    python,
    definitions,
    "(function_definition) @definition",
    _{version:"fixture-v1", provenance:_{origin:host}},
    ok(_)
),
project_query_pack_activate(Registry, python, definitions, ok(_)).
```

Pack source is only accepted as an atom or string and is passed to
`ts_query_new`. It is never parsed as a Prolog term, consulted, asserted, or
called. Packs do not grant filesystem, process, network, tool, capability, or
authority access. Re-registering changed source replaces the inert pack and
marks extractions that used the old pack stale.

## FFI surface

The optional native module exposes the Tree-sitter 0.20-compatible intersection:

```prolog
ts_query_compile(+Language, +Source, -Query).
ts_query_pattern_count(+Query, -Count).
ts_query_capture_count(+Query, -Count).
ts_query_capture_name(+Query, +CaptureId, -Name).
ts_query_capture_quantifier(+Query, +Pattern, +CaptureId, -Quantifier).
ts_query_predicates(+Query, +Pattern, -Steps).
ts_query_cursor_create(-Cursor).
ts_query_cursor_exec(+Cursor, +Query, +Node).
ts_query_cursor_set_byte_range(+Cursor, +Start, +End).
ts_query_cursor_set_point_range(+Cursor, +Start, +End).
ts_query_next_match(+Cursor, -Match).
ts_query_next_capture(+Cursor, -Match, -CaptureIndex).
```

Matches retain Tree-sitter grouping and native capture order:

```prolog
ts_match(MatchId,
         PatternIndex,
         [ts_capture(CaptureId, NativeNode), ...]).
```

Query objects retain their grammar resource and are immutable after compilation,
so cached query objects may be used by bounded workers. Cursors retain their
query and tree resources and are thread-affine. Explicit close is idempotent;
garbage-collection release remains safe for dependent resources.

Malformed source returns `tree_sitter_error(query_compile(Kind, ByteOffset),
Point)`. The point is derived from the UTF-8 byte offset and its column is a
byte column, matching Tree-sitter. Predicate-bearing patterns are rejected by
the project layer as `unsupported_predicate`; Tree-sitter reports predicate
steps but does not evaluate them.

## Project extraction

The project facade uses the canonical async direction:

```prolog
project_query_extract(+Registry, +File, +Source, +Purposes, +Options, -Outcome).
project_query_extract_async(+Registry, +File, +Source, +Purposes, +Options, -Future).
project_query_extract_execute(+Registry, +File, +Source, +Purposes, +Options, -Outcome).
```

The worker admits an extraction generation, checks the registered file hash,
resolves active packs, parses through `rlm_project_source`, executes each query
against the root or a validated `syntax_node(Parse, Path)` subtree, and
publishes one record per match. The primary observation query is grouped:

```prolog
project_query_current_extraction(+Registry, +File, -Extraction).
project_query_matches(+Registry, +Extraction, -Match).
project_query_captures(+Registry, +Extraction, -Capture).
project_query_node_provenance(+Registry, ?Node, -Provenance).
```

Each `project_query_capture{...}` includes an ordinal, capture ID/name, closed
node identity, byte span, point span, parse generation, grammar reference, pack
identity/hash, query-source hash, and project/file provenance. A repeated
capture name therefore remains multiple ordered list entries rather than being
collapsed into a name-keyed map. No published fact contains a native pointer.

Options are bounded and host-controlled:

- `max_source_bytes(N)` (default `1048576`);
- `max_matches(N)` (default `10000`);
- `max_captures(N)` (default `50000`);
- `timeout_seconds(Number)` (default `30.0`);
- `byte_range(Start, End)` or `point_range(point(Row, Column), point(Row, Column))`;
- `subtree(syntax_node(Parse, Path))`;
- `kb_root(AbsoluteProjectRoot)`.

Limit exhaustion produces `partial(Summary)` with an explicit reason. A timeout
or cancellation is a typed error and does not restore a previous generation as
current. Parse generation reuse is allowed only when the current parse has the
exact source hash and is the latest admitted generation; otherwise a new parse
identity is opened.

Publication is fenced: when a new parse or extraction generation is
successfully published, every earlier record for the same file that a
superseded admission left as `indeterminate(pending(...))` is explicitly marked
`stale`. For extraction records the stale currentness is also written to the
project-query journal, so a restart cannot resurrect a superseded observation
as current. Failed admissions (`reject_query_admission`) fence their own
pending records the same way; only the published generation is `current`.

## Project-KB durability

Query extraction facts are project epistemic observations, distinct from
artifacts, graph checkpoints, effect journals, runtime observations, and
authority. When `kb_root/1` is supplied, or the registered project metadata
contains trusted `project_root`, the local persistence adapter writes to:

```text
<project-root>/.kb/project-query/project-<project-identity-hash>.pl
```

The adapter journals closed `extraction_record/3` and `match_record/4` terms and
replays them when the registry opens. The initial adapter uses SWI
`library(persistency)` with `sync(close)`, the strongest option supported by
SWI-Prolog 10.0.2; this closes the journal after every publication so a process
kill cannot leave an acknowledged append in a process-local stream. A future
backend can replace the adapter without changing the `rlm_project_query`
facade. An absent, relative, or read-only project root returns structured
`project_query_error{kind:kb_unwritable}` rather than silently degrading to
memory-only state.

Compiled native query objects are intentionally process-local cache entries.
They are keyed by language, grammar reference, and query-source SHA-256, with a
bounded FIFO of 32 entries. A restart deterministically recompiles them; no
native pointer crosses a process boundary.

## Runtime layering

The dependency direction is:

```text
#97 structural captures
        -> #98 semantic normalization
        -> #99 freshness/invalidation
        -> canonical project knowledge providers
        -> direct-mode tools and symbolic planner/verifier consumers
```

Direct mode remains the normal agentic model/tool loop with the context
compiler. Symbolic mode remains the more constrained typed-plan loop in which
the model contributes bounded reasoning/generation and trusted runtime code
owns expert/tool calls and verification. This query layer does not add an
expert catalog or wire itself into either mode.
