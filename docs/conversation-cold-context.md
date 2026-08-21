# Lazy cold conversation context

Managed conversations keep a complete durable transcript without copying lifetime history into every RLM call.

The canonical managed pipeline is:

```text
complete transcript
        |
        +--> bounded hot transcript context
        +--> existing warm artifacts when configured
        +--> synthetic cold-history boundary
        |      tells the model how to recover omitted turns
        `--> opaque lazy cold-history handle
                     |
                     +-- peek
                     +-- slice
                     `-- search
```

Warm artifacts participate in the normal public managed context pack when `warm_store/1` is configured. Creating or compacting new warm artifacts is a separate explicit operation and is not triggered automatically by token pressure.

The cold-history boundary is synthetic provider-visible projection state. Durable user, assistant, system, and tool messages are never rewritten to carry runtime instructions.

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

Ordinary `context_register/3` still accepts only ordinary bounded context sources. Model-authored source data cannot install executable adapter callbacks.

Adapter capabilities explicitly declare allowed context operations, and a live adapter-backed handle prevents the adapter definition from being removed underneath it.

Adapter metadata is model-visible, so registration applies the validated `max_bytes` option to the complete serialized `context_metadata{...}` descriptor before any handle is published. The default ceiling is 16 KiB, matching the ordinary context byte limit. Oversized metadata is rejected rather than truncated as `adapter_metadata_too_large`, with `bytes` and `max_bytes` fields reporting the measured descriptor size and enforced ceiling.

## Enforcement stays in `rlm_context`

Adapters resolve source semantics; the context core owns the boundary:

- opaque handle/version validation;
- declared adapter capabilities;
- registration-time metadata byte limits;
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

The handle metadata contains safe source information such as conversation id, message count, store backend and source revision. It does not contain the transcript payload.

The conversation adapter supports:

```prolog
context_peek(Handle, head(N), Options, Outcome).
context_peek(Handle, tail(N), Options, Outcome).
context_peek(Handle, item(Index), Options, Outcome).
context_slice(Handle, Start, Length, Options, Outcome).
context_search(Handle, Pattern, Options, Outcome).
```

Partition/map/reduce are intentionally absent in this slice.

## Synthetic cold-history boundary

When a conversation extends beyond the configured `min_recent_turns` guarantee, `rlm_conversation_runtime` adds a mandatory context unit named `managed_cold_history_boundary`.

It tells the planner that the older prefix may be absent from active attention, that the transcript was not deleted, and that original history should be retrieved before guessing when an earlier decision, fact, file, symbol, task, person, requirement, or discussion is referenced.

The rendered boundary exposes the actual RLM retrieval forms:

```prolog
context(input(context), search("query"), Result).
context(input(context), slice(Start, Length), Result).
context(input(context), peek(item(Index)), Result).
```

The unit is token-accounted and mandatory. Its status records the cold prefix and guaranteed hot-tail start. The wording intentionally says old turns *may* be absent: warm context or available budget can still keep additional historical material in active context.

The boundary can be disabled explicitly with `cold_history_boundary(false)` for specialized callers. It is enabled by default.

## Managed turn behavior

The public managed runtime performs:

```text
reuse configured existing warm artifacts
        |
derive synthetic cold-history boundary
        |
persist current user turn
        |
compile bounded hot + warm + boundary context
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

When no explicit capability set is supplied, managed turns grant only the minimal cold context capabilities needed in addition to existing model/RLM defaults:

```prolog
context(peek)
context(slice)
context(search)
```

Explicit caller capabilities are never widened.

## Why this is the unbounded-chat boundary

The provider receives a bounded hot/warm working set, a small retrieval boundary, and opaque cold-history metadata. Historical payload remains in the conversation store and is projected only through bounded context operations.

Conversation length is therefore independent from the provider context window. The window limits active attention, not the amount of durable history RLM can address.

## Current scaling note

The adapter is lazy with respect to `rlm_context` storage and provider requests. Current local conversation backends may still scan/materialize their own records while satisfying search. Indexed storage can replace that implementation later without changing the RLM contract.

Warm production is likewise independent: published warm state is reused automatically when configured, but no automatic compaction loop is required for unbounded chat.
