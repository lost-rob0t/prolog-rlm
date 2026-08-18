# Lazy cold conversation context

Managed conversations keep a complete durable transcript without copying lifetime history into every RLM call.

The canonical managed pipeline is:

```text
complete transcript
        |
        +--> bounded hot transcript context
        +--> existing warm artifacts when configured
        `--> opaque lazy cold-history handle
                     |
                     +-- peek
                     +-- slice
                     `-- search
```

Warm artifacts participate in the normal public managed context pack when `warm_store/1` is configured. Creating or compacting new warm artifacts is a separate explicit operation and is not triggered automatically by token pressure.

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

Ordinary `context_register/3` still accepts only `text(Text)` and `terms(List)`. Model-authored source data cannot install executable adapter callbacks.

Adapter capabilities explicitly declare allowed context operations, and a live adapter-backed handle prevents the adapter definition from being removed underneath it.

## Enforcement stays in `rlm_context`

Adapters resolve source semantics; the context core owns the boundary:

- opaque handle/version validation;
- declared adapter capabilities;
- wall-time limits;
- `max_results`;
- `max_bytes`;
- structured errors;
- output rebounding/truncation;
- trace sequence and timestamps;
- returned-byte accounting;
- tombstones after handle deletion.

## Conversation cold handles

The conversation API exposes:

```prolog
conversation_cold_context(+Conversation,
                          +ContextOptions,
                          -Outcome).
```

The handle metadata contains safe source information such as the conversation id, message count, store backend and source revision. It does not contain the transcript payload.

The conversation adapter supports:

```prolog
context_peek(Handle, head(N), Options, Outcome).
context_peek(Handle, tail(N), Options, Outcome).
context_peek(Handle, item(Index), Options, Outcome).
context_slice(Handle, Start, Length, Options, Outcome).
context_search(Handle, Pattern, Options, Outcome).
```

Partition/map/reduce are intentionally absent in this slice.

## Managed turn behavior

The public managed runtime performs:

```text
reuse configured existing warm artifacts
        |
persist current user turn
        |
compile bounded hot + warm context
        |
register ephemeral conversation cold handle
        |
rlm_completion(...)
        |
RLM may peek/search/slice older history
        |
delete only ephemeral handle
        |
persist assistant result
```

The durable transcript and warm artifact store are not deleted when the ephemeral cold handle is cleaned up.

When no explicit capability set is supplied, managed turns grant only the minimal cold context capabilities needed in addition to the existing model/RLM defaults:

```prolog
context(peek)
context(slice)
context(search)
```

Explicit caller capabilities are never widened.

## Why this is the unbounded-chat boundary

The provider receives a bounded hot/warm working set plus small opaque cold-history metadata. Historical payload remains in the conversation store and is projected only through bounded context operations.

Conversation length is therefore independent from the provider context window. The window limits active attention, not the amount of durable history RLM can address.

## Current scaling note

The adapter is lazy with respect to `rlm_context` storage and provider requests. Current local conversation backends may still scan/materialize their own records while satisfying search. Indexed storage can replace that implementation later without changing the RLM contract.

Warm production is likewise independent: published warm state is reused automatically when configured, but no automatic compaction loop is required for unbounded chat.
