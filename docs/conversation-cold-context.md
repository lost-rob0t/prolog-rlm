# Lazy cold conversation context

Managed conversations keep a complete durable transcript without copying that lifetime history into every RLM call.

The cold layer uses the generic trusted adapter boundary in `rlm_context`:

```text
conversation transcript store
        |
        | ground conversation_ref only
        v
context adapter registry
        |
        v
opaque context_handle
        |
        +-- metadata
        +-- peek
        +-- slice
        +-- search
        |
        v
bounded context_result + trace
```

The active provider prompt still contains the token-budgeted hot/warm working set. The opaque handle represents historical state that can be searched or sliced only when the planner decides it is needed.

## Generic trusted adapter boundary

`rlm_context` now provides host/library APIs:

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

These are trusted runtime APIs, not model-callable tools. Ordinary `context_register/3` still accepts only `text(Text)` and `terms(List)` and cannot install callbacks from source data.

Adapter capabilities explicitly declare allowed context operations. An adapter cannot execute an undeclared operation even if its callback happens to support one.

A live adapter-backed handle prevents the adapter definition from being unregistered underneath it.

## Enforcement stays in `rlm_context`

Adapters resolve source semantics, but they do not own the final output boundary.

For every adapter operation, `rlm_context` still owns:

- opaque handle/version validation;
- adapter capability checks;
- wall-time limits;
- `max_results`;
- `max_bytes`;
- structured errors;
- output truncation;
- trace sequence/timestamps;
- bytes returned;
- tombstones after handle deletion.

The core re-bounds adapter callback output before producing a `context_result`. A trusted adapter therefore cannot accidentally bypass result-count or provider-visible byte limits merely by returning a larger value.

## Conversation cold handles

The top-level conversation API exposes:

```prolog
conversation_cold_context(+Conversation,
                          +ContextOptions,
                          -Outcome).
```

The returned metadata contains safe source information such as:

```prolog
conversation_source{
    kind:conversation,
    bytes:unknown,
    items:MessageCount,
    conversation_id:ConversationId,
    source_revision:LatestSequence,
    store_backend:memory_or_persist
}
```

It does not expose the full transcript.

The conversation adapter supports:

```prolog
context_peek(Handle, head(N), Options, Outcome).
context_peek(Handle, tail(N), Options, Outcome).
context_peek(Handle, item(Index), Options, Outcome).
context_slice(Handle, Start, Length, Options, Outcome).
context_search(Handle, Pattern, Options, Outcome).
```

Indexes for `item/1` and `slice/2` are zero-based, matching the existing context runtime. Returned views keep exact durable message refs, sequence, role, and content.

Partition/map/reduce are intentionally not declared for the conversation adapter in this slice. Unsupported operations fail through the normal capability boundary instead of silently inventing semantics.

## Managed turn behavior

`conversation_turn/4` now:

```text
persist current user turn
        |
compile hot/warm context under max_context_tokens
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

The durable conversation is never deleted when the ephemeral context handle is cleaned up.

When the caller does not provide an explicit `capabilities(...)` option, managed turns grant only the minimal context capabilities needed for cold retrieval in addition to the existing model/RLM defaults:

```prolog
context(peek)
context(slice)
context(search)
```

If the caller supplies an explicit capability set, the conversation layer does not widen it.

## Why this is the unbounded-chat boundary

Before this slice, managed turns compiled a bounded active prompt but also passed the entire lifetime transcript as `terms(FullTranscript)` into `rlm_completion/4`. That delayed prompt overflow but still made every turn copy the whole conversation into the context runtime.

Now the lifetime transcript remains in the conversation store. A model call receives:

```text
bounded active hot/warm prompt
+
small opaque cold-history metadata/handle
```

Historical payload is projected only when a context operation requests it.

This makes conversation length independent from the provider context window. The provider window limits active attention, not the total durable history that the RLM can address.

## Current scaling note

The adapter boundary is lazy with respect to `rlm_context` storage and provider requests. The current local conversation backends may still scan/materialize their own message lists while satisfying a search. That is a storage/indexing optimization issue, not a context-window issue.

A later indexed backend can implement the same adapter callbacks with database search or project-KB retrieval without changing the RLM/context contract.
