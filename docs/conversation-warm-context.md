# Warm conversation context

`rlm_conversation_warm` derives compact, versioned context from immutable conversation ranges. It is the middle layer between hot recent turns and cold full-history retrieval.

```text
full transcript
    |
    | exact source refs
    v
warm derivation
    |
    +-- verbatim
    +-- detailed_summary
    +-- compact_summary
    +-- facts_only
    |
    v
versioned artifact
    |
    v
candidate narrowing + CLP(FD) context pack
```

Compaction never deletes or rewrites source conversation messages.

## Public API

```prolog
default_warm_policy(-Policy).
warm_context_schema(-Schema).

conversation_warm_derive(+Conversation,
                         +Range,
                         +Options,
                         -Outcome).

conversation_warm_publish(+Conversation,
                          +ArtifactStore,
                          +Range,
                          +Options,
                          -Outcome).

conversation_warm_list(+Conversation,
                       +ArtifactStore,
                       +Options,
                       -Outcome).

conversation_warm_context_units(+Conversation,
                                +ArtifactStore,
                                +Signals,
                                +Options,
                                -Outcome).
```

## Derived schema

The generator must produce a structured object with:

```text
summary
 decisions
 facts
 unresolved
 entities
 topics
 files
 symbols
```

All list fields contain strings. The runtime validates this shape before any warm state is admitted.

A deterministic trusted generator can be supplied for tests or specialized hosts:

```prolog
generator(my_module:derive_warm)
```

The callback contract is:

```prolog
my_module:derive_warm(+WarmSource, +Options, -Generated).
```

Without an explicit callback, the production path uses `rlm_completion/4` over the exact source messages as opaque context. The RLM result must decode and validate against the same structured schema. Caller-provided completion options are forwarded; warm compaction does not add capabilities or widen authority.

## Durable identity

Warm state reuses `rlm_artifact` rather than creating a second derived-state database.

For conversation `SessionId`, records are published under:

```prolog
[conversation, SessionId, warm]
```

A source range such as `range(40, 90)` uses key:

```prolog
range_40_90
```

Recompacting the same logical range creates a new immutable artifact version. Exact historical artifact refs remain readable, while the original conversation messages remain unchanged.

Each warm record stores:

- exact source message refs;
- source range;
- validated generated structure;
- all provider-visible variants and token counts;
- generator provenance;
- creation time.

## Multiple representations

Every warm range produces four measured representations:

```prolog
warm_variant{kind:verbatim, ...}.
warm_variant{kind:detailed_summary, ...}.
warm_variant{kind:compact_summary, ...}.
warm_variant{kind:facts_only, ...}.
```

The generic `rlm_context_budget` layer supplies the optional `omitted` choice when the warm unit is not mandatory.

This lets the solver choose fidelity under pressure instead of treating compaction as a one-way destructive operation.

## Replacing covered cold turns

`conversation_context_pack/3` accepts additional compiled units:

```prolog
context_units(WarmUnits)
```

Warm values carry `source_refs`. Old optional transcript messages covered by those refs are removed from the candidate set so the solver cannot waste tokens selecting both a summary and the exact source it replaces.

Mandatory recent turns are never suppressed by warm coverage. Hot context wins if a source range accidentally overlaps the mandatory recent window.

## Candidate narrowing

Exact CLP(FD) search should operate on a bounded candidate set, not an entire lifetime transcript.

The warm policy defaults to:

```prolog
max_candidates:32
```

Warm artifacts are ranked before exact packing. Ranking uses source recency plus explicit weighted signals. Supported signal kinds are:

```text
pinned
 direct_reference
 active_task
 unresolved
 dependency
 entity
 topic
 retrieval
```

Signals use:

```prolog
warm_signal(ArtifactKey, Kind, Strength)
```

Example:

```prolog
warm_signal(range_40_90, direct_reference, 10)
```

A strong direct reference can therefore promote an old relevant range over a newer irrelevant one before the CLP solver sees candidates.

`pinned` additionally makes the resulting unit mandatory. The solver may still choose a smaller representation of that unit when required by the token ceiling.

## Token accounting

Variant token counts use the same `token_count_text/3` boundary as hot conversation context. A trusted provider/model tokenizer callback can be supplied through:

```prolog
token_options([token_counter(Module:Predicate)])
```

Otherwise the count remains explicitly marked estimated.

When a warm unit is selected, its actual chosen representation appears as a normal context-unit stage in `token_ledger.stages`, including representation kind, charged tokens, and cumulative context use.

## Remaining cold-history work

This slice provides durable warm derivation and replacement semantics. Managed turns still expose the full transcript as opaque RLM context in the underlying first conversation slice.

The next cold-history slice should replace that materialization with a durable/searchable conversation context backend so an RLM root can request exact historical ranges on demand. That is what turns a bounded rolling prompt into effectively unbounded conversation history without sending the lifetime transcript on every provider request.
