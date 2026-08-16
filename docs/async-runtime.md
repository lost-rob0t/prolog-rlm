# Dual synchronous / asynchronous runtime

`prolog-rlm` exposes both blocking and non-blocking surfaces for operations that can take meaningful time.

The synchronous API remains the simplest interface:

```prolog
llm_query("hello", Options, Outcome).
```

The asynchronous API schedules the same operation and returns an opaque future:

```prolog
llm_query_async("hello", Options, Future),
rlm_future_await(Future, Outcome),
rlm_future_destroy(Future).
```

`Outcome` has the same shape as the synchronous call. The future layer does not wrap successful results in another `ok/1`.

## Scheduler

The generic async runtime is resource-bounded. It uses a fixed process-local worker set and a finite submission backlog rather than creating one operating-system thread for every future.

Current defaults are eight workers and a backlog of 64 queued tasks. A full backlog resolves the submitted future to a structured `async_error` with `kind:backpressure` instead of blocking the caller indefinitely or creating more workers.

Runtime counters are available through:

```prolog
rlm_async_runtime_status(Status).
```

The status includes worker count, backlog limit, queued, pending, running, completed, and cancelled counts. Downstream runtimes may impose stricter limits.

## Future API

```prolog
rlm_async_submit(Closure, Future).
rlm_async_runtime_status(Status).
rlm_future_status(Future, Status).
rlm_future_await(Future, Outcome).
rlm_future_await(Future, TimeoutSeconds, Outcome).
rlm_future_cancel(Future, CancelOutcome).
rlm_future_all(Futures, Outcomes).
rlm_future_destroy(Future).
```

`rlm_async_submit/2` accepts a closure that receives one final result argument:

```prolog
work(Input, Result) :-
    ... .

?- rlm_async_submit(work(Input), Future).
```

The future is intentionally opaque. Callers should inspect it only through the public predicates.

### Timeout behavior

An await timeout does **not** cancel the task:

```prolog
rlm_future_await(Future, 0.25, TimeoutOutcome),
% TimeoutOutcome = error(async_error{kind:timeout, ...})
rlm_future_await(Future, FinalOutcome).
```

Use `rlm_future_cancel/2` when cancellation is intended.

### Cancellation

Cancellation marks the future cancelled. If the task is already running, the scheduler signals the worker currently executing that task; if it is still queued, the worker skips it when dequeued. Awaiting a cancelled future returns a structured `async_error` with `kind:cancelled`.

Destroy futures when the caller no longer needs their result so per-future state is reclaimed.

## Library facades

The dual-surface APIs cover:

### Completion

```prolog
rlm_completion(Query, Context, Options, Outcome).
rlm_completion_async(Query, Context, Options, Future).

llm_query(Prompt, Options, Outcome).
llm_query_async(Prompt, Options, Future).

rlm_query(Query, Context, Options, Outcome).
rlm_query_async(Query, Context, Options, Future).
```

The top-level `rlm` facade applies the same public recursion policy to synchronous and asynchronous completion calls.

### Provider / chain

```prolog
model_complete_async(Provider, Request, Future).
model_stream_async(Provider, Request, Handler, Future).
chain_invoke_async(Chain, Request, Options, Future).
chain_stream_async(Chain, Request, Handler, Options, Future).
```

### Tools

`tool_invoke/7` has two result outputs (`Outcome` and `Trace`), so its async facade resolves to one structured value:

```prolog
tool_invoke_async(Registry, Caps, Name, Args, Options, Future),
rlm_future_await(Future, Result).

% Result = tool_async_result{
%              outcome: Outcome,
%              trace: Trace
%          }
```

### MCP

```prolog
mcp_client_connect_async(TransportSpec, ClientInfo, ClientCaps, Options, Future).
mcp_client_command_async(Client, Command, Options, Future).
mcp_client_close_async(Client, Future).
mcp_server_handle_async(Server, Session, Command, Options, Context, Future).
```

These call the canonical, version-neutral MCP facade; protocol adapters are not duplicated in the async layer.

### Agents

```prolog
agent_spawn_async(Runtime, Parent, Spec, Options, Future).
agent_send_async(Runtime, Agent, Message, Options, Future).
agent_pump_async(Runtime, Agent, Options, Future).
agent_cancel_async(Runtime, Agent, Reason, Future).
```

### Graphs

```prolog
graph_run_async(Compiled, Input, Options, Future).
graph_resume_async(Compiled, RunId, State, Input, Options, Future).
```

## Design rule

Async facades do not duplicate model/tool/MCP/agent/graph business logic. They schedule the existing operation through `rlm_async` and preserve its ordinary result term.

This makes the async layer suitable for responsive clients such as a future `agentProlog` TUI while keeping synchronous scripts and simple expert systems straightforward.

Async execution does not bypass capability checks, budgets, cancellation rules, tool confinement, or any later authority policy. Those checks remain inside the underlying operation.
