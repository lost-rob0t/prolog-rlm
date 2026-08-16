# Canonical asynchronous runtime

`prolog-rlm` exposes blocking and non-blocking surfaces for operations that can take meaningful time.

For completion and provider/chain execution, asynchronous work is the canonical implementation path. Synchronous predicates are convenience wrappers that start the same task, await its Future, and destroy the Future with cleanup protection.

The architectural invariant is:

```text
canonical execute semantics
        |
        +-- async API -> Future
        |
        +-- sync API  -> same async API -> await Future
```

Never implement an asynchronous facade by scheduling its synchronous public counterpart.

```prolog
llm_query_async("hello", Options, Future),
rlm_future_await(Future, Outcome),
rlm_future_destroy(Future).
```

The equivalent blocking call is:

```prolog
llm_query("hello", Options, Outcome).
```

`Outcome` has the same shape on both surfaces. The Future layer does not add another `ok/1` wrapper.

## Execution ABI

Completion and provider/chain modules separate three concerns:

- operation semantics live in internal `*_execute` predicates;
- asynchronous predicates submit those execution predicates to `rlm_async`;
- synchronous predicates call the async surface and await/destroy its Future.

Canonical operations that are already executing on an async worker call the internal execution ABI directly. They do not call a public synchronous wrapper and create a nested Future wait. This matters because the worker pool is intentionally bounded.

Examples include planner/model calls from completion, model steps in typed plans, and chain retry/stream transports.

## Scheduler

The generic async runtime is resource-bounded. It uses a fixed process-local worker set and a finite submission backlog rather than creating one operating-system thread for every Future.

Current defaults are eight workers and a backlog of 64 queued tasks. A full backlog resolves the submitted Future to a structured `async_error` with `kind:backpressure` instead of blocking the caller indefinitely or creating more workers.

Runtime counters are available through:

```prolog
rlm_async_runtime_status(Status).
```

The status includes worker count, backlog limit, queued, pending, running, completed, and cancelled counts. Downstream runtimes may impose stricter limits.

## Future API

```prolog
rlm_async_submit(Closure, Future).
rlm_async_submit(Closure, Metadata, Future).
rlm_async_runtime_status(Status).
rlm_future_status(Future, Status).
rlm_future_metadata(Future, Metadata).
rlm_future_await(Future, Outcome).
rlm_future_await(Future, TimeoutSeconds, Outcome).
rlm_future_cancel(Future, CancelOutcome).
rlm_future_all(Futures, Outcomes).
rlm_future_then(Future, Callback, NextFuture).
rlm_future_on_complete(Future, Callback).
rlm_future_destroy(Future).
```

`rlm_async_submit/2` accepts a closure that receives one final result argument:

```prolog
work(Input, Result) :-
    ... .

?- rlm_async_submit(work(Input), Future).
```

`rlm_async_submit/3` also accepts a ground metadata dict. Runtime metadata includes the Future/task ID, parent task ID, operation kind and creation time. Callers may add host-controlled correlation fields such as `trace_id` and `session_id`.

The Future is intentionally opaque. Callers should inspect it only through the public predicates.

### Continuations and callbacks

`rlm_future_then/3` creates a child Future. The continuation is enqueued only after the parent reaches a terminal state, so composition does not consume a worker merely waiting on another Future.

`rlm_future_on_complete/2` registers a host/library callback. Completion callbacks run once. They are not a model-callable execution surface.

Parent cancellation propagates to composed child Futures where the runtime owns that parent/child relationship.

### Timeout behavior

An await timeout does **not** restart or cancel the task:

```prolog
rlm_future_await(Future, 0.25, TimeoutOutcome),
% TimeoutOutcome = error(async_error{kind:timeout, ...})
rlm_future_await(Future, FinalOutcome).
```

Use `rlm_future_cancel/2` when cancellation is intended.

### Cancellation and cleanup

Cancellation marks the Future cancelled. If the task is already running, the scheduler signals the worker currently executing that task; if it is still queued, the worker skips it when dequeued. Awaiting a cancelled Future returns a structured `async_error` with `kind:cancelled`.

Synchronous wrappers use `setup_call_cleanup/3` around await/destroy so interruption or an exception during the wait does not leak owned Future state.

Destroy Futures when the caller no longer needs their result so per-Future metadata and composition state are reclaimed.

## Canonical library surfaces in this slice

### Completion

```prolog
rlm_completion(Query, Context, Options, Outcome).
rlm_completion_async(Query, Context, Options, Future).

llm_query(Prompt, Options, Outcome).
llm_query_async(Prompt, Options, Future).

rlm_query(Query, Context, Options, Outcome).
rlm_query_async(Query, Context, Options, Future).
```

The top-level `rlm` facade applies the same public recursion policy before synchronous and asynchronous execution. A synchronous call then waits on the same async path.

### Provider / chain

```prolog
model_complete(Provider, Request, Outcome).
model_complete_async(Provider, Request, Future).

model_stream(Provider, Request, Handler, Outcome).
model_stream_async(Provider, Request, Handler, Future).

chain_invoke(Chain, Request, Options, Outcome).
chain_invoke_async(Chain, Request, Options, Future).

chain_stream(Chain, Request, Options, Handler, Outcome).
chain_stream_async(Chain, Request, Handler, Options, Future).
```

Streaming uses the provider streaming transport incrementally inside the asynchronous task. It does not wait for a complete synchronous stream and replay it afterward.

## Remaining #54 migrations

The generic Future runtime is shared by tools, MCP, agents and graphs, but those libraries still contain compatibility async facades that schedule synchronous public operations. They are intentionally not described as canonical yet.

The next #54 slice must migrate latency-bearing operations in:

- `rlm_tool`;
- `rlm_mcp`, including the declarative lifecycle work tracked by #52;
- `rlm_agent`;
- `rlm_graph`.

Pure or immediate predicates should not be forced through Futures.

The same hard rule applies to those migrations: canonical task/async execution first, synchronous await wrappers second. Loading tools is not authorization, and async execution never bypasses capabilities, schemas, confinement, budgets, network restrictions, validation, tracing, or host-controlled authority policy.
