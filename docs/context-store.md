# Opaque external context runtime

`rlm_context` keeps large payloads outside model prompts and exposes bounded
operations through opaque versioned handles.

## Registration

The initial memory backend accepts only two explicit source forms:

```prolog
context_register(text(Text), Options, Outcome).
context_register(terms(Terms), Options, Outcome).
```

A successful registration returns metadata plus a handle, never the payload:

```prolog
ok(context_ref{
    handle:context_handle(Id, Version),
    metadata:context_metadata{
        backend:memory,
        kind:text,
        bytes:Bytes,
        items:Items,
        version:Version,
        created_at:CreatedAt
    }
}).
```

The memory backend advertises `filesystem:false` and `network:false`. Values
such as `file(Path)`, `url(URL)`, streams, sockets, and arbitrary callable terms
are not interpreted or dereferenced by the context store.

## Bounds

All projection operations accept an option list. Defaults are:

```prolog
[max_results(32), max_bytes(16384), time_limit(0.25)]
```

- `max_results` bounds returned matches, partitions, mapped values, or term
  projections.
- `max_bytes` is a global payload-output budget for the operation, not a
  per-result allowance.
- `time_limit` is a wall-time bound enforced by SWI-Prolog.

Invalid limits return structured `context_error{...}` outcomes.

## Operations

### Metadata

```prolog
context_metadata(Handle, Outcome).
```

Returns the model-safe reference/metadata without exposing the payload.

### Peek

```prolog
context_peek(Handle, head(Count), Options, Outcome).
context_peek(Handle, tail(Count), Options, Outcome).
context_peek(Handle, item(Index), Options, Outcome).   % term contexts
context_peek(Handle, metadata, Options, Outcome).
```

### Slice

```prolog
context_slice(Handle, Start, Length, Options, Outcome).
```

Indexes are zero-based. Text slices address characters; term slices address
items.

### Search

```prolog
context_search(Handle, Pattern, Options, Outcome).
```

Text contexts are searched by line. Term contexts are searched over their
stable textual representation. Match count and returned payload bytes are
bounded.

### Partition

```prolog
context_partition(Handle, fixed(Size), Options, Outcome).
context_partition(Handle, lines(Size), Options, Outcome). % text only
```

Partition count and total returned payload bytes are bounded. A partial or
stopped projection is marked `truncated:true`.

### Map

```prolog
context_map(Handle, identity, Options, Outcome).
context_map(Handle, lowercase, Options, Outcome).
context_map(Handle, uppercase, Options, Outcome).
context_map(Handle, length, Options, Outcome).
```

The transform vocabulary is allow-listed. Caller-supplied predicates are not
executed.

### Reduce

```prolog
context_reduce(Handle, count, Options, Outcome).
context_reduce(Handle, byte_count, Options, Outcome).
```

Reducers are allow-listed for the same reason.

## Structured outcomes and traces

Successful projections return:

```prolog
ok(context_result{
    handle:Handle,
    operation:Operation,
    value:Value,
    truncated:Boolean,
    trace:Trace
}).
```

Each trace records the operation, handle, bytes/items inspected, bytes
returned, truncation state, elapsed milliseconds, timestamp, and a monotonically
increasing sequence number for the handle.

Recent trace events are available through:

```prolog
context_trace(Handle, Limit, Outcome).
```

Malformed, unknown, deleted, or stale handles return structured errors. A
deleted handle is retained only as a tombstone so stale use can be diagnosed.

## Backend boundary

`context_backend(memory, Capabilities)` exposes the initial backend's declared
capabilities. The public handle/operation API is deliberately independent of
storage implementation so a later durable backend can preserve the same model
contract without letting persistence details leak into agent or graph logic.
