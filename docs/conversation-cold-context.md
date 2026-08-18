# Lazy cold conversation context

Managed conversations keep a complete durable transcript without copying lifetime history into every RLM call.

The default path is:

```text
complete durable transcript
        |
        +--> bounded active hot context
        |
        `--> opaque cold-history handle
             peek / slice / search on demand
```

Warm/derived context is an optional explicit feature. It is not automatically generated or loaded by managed turns.

## Generic trusted adapter boundary

`rlm_context` provides trusted host/library APIs:

```prolog
context_adapter_register(+Name,
                         +Capabilities,
                         +MetadataHandler,
                         +OperationHandler,
                         -Outcome).

context_adapter_unregister(+Name, -Outcome).
context_adapter_info(+Name, -Outcome).

context_register_adapter(+Name,
                         +GroundSourceRef,
                         +Options,
                         -Outcome).
```

These are runtime APIs, not model-callable tools. Ordinary `context_register/3` still accepts only `text(Text)` and `terms(List)` and cannot install callbacks from model-authored data.

Adapter capabilities explicitly declare allowed operations. Live adapter-backed handles prevent their adapter definition from being removed underneath them.

## Enforcement stays in `rlm_context`

Adapters resolve source semantics, but `rlm_context` still owns:

- opaque handle/version validation;
- capability checks;
- wall-time limits;
- `max_results`;
- `max_bytes`;
- structured errors;
- output truncation;
- tracing and tombstones.

Adapter output is re-bounded by the core before becoming a `context_result`.

## Conversation cold handles

The conversation API exposes:

```prolog
conversation_cold_context(+Conversation,
                          +ContextOptions,
                          -Outcome).
```

Safe metadata identifies the durable source without exposing the transcript payload.

The conversation adapter supports:

```prolog
context_peek(Handle, head(N), Options, Outcome).
context_peek(Handle, tail(N), Options, Outcome).
context_peek(Handle, item(Index), Options, Outcome).
context_slice(Handle, Start, Length, Options, Outcome).
context_search(Handle, Pattern, Options, Outcome).
```

Indexes for `item/1` and `slice/2` are zero-based. Returned views keep exact durable message refs, sequence, role, and content.

Partition/map/reduce are intentionally not part of this adapter contract yet.

## Managed turn behavior

```text
persist current user turn
        |
compile bounded active hot context
        |
register ephemeral conversation cold handle
        |
rlm_completion(Query, ColdContextRef, ...)
        |
planner may peek/search/slice old history when needed
        |
delete only ephemeral context handle
        |
persist assistant result
```

The durable conversation is never deleted when the ephemeral handle is cleaned up.

If the caller does not provide explicit capabilities, managed turns add only the minimal cold-retrieval capabilities beside their normal model/RLM capabilities:

```prolog
context(peek)
context(slice)
context(search)
```

Explicit caller capabilities are never widened.

## Warm context remains opt-in

`rlm_conversation_warm` is still available as a library feature. Callers may explicitly derive versioned summaries/facts and pass their context units into the shared token-budget solver.

The default managed-turn path does **not**:

- derive warm records;
- discover/load warm records;
- summarize because the token budget is tight;
- replace cold retrieval with compaction.

This keeps the baseline predictable: old turns leave active attention but remain directly addressable through RLM.

## Why this is the unbounded-chat boundary

A model call receives a bounded active prompt plus small opaque cold-history metadata. Historical payload is only projected when a bounded context operation requests it.

Conversation length is therefore independent from the provider context window. The provider window limits active attention, not total durable history.

The current local conversation backends may still scan their own records while satisfying a search. That is a storage/indexing optimization, not a context-window limitation. A later indexed backend can implement the same adapter callbacks without changing the RLM contract.
