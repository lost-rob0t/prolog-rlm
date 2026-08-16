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

## Future API

```prolog
rlm_async_submit(Closure, Future).
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

Cancellation marks the future cancelled and signals its worker thread. Awaiting a cancelled future returns a structured `async_error` with `kind:cancelled`.

Destroy futures when the caller no longer needs them so joinable worker resources can be reclaimed deterministically.

## Library facades

The first dual-surface APIs cover:

### Completion

```prolog
rlm_completion(Query, Context, Options, Outcome).
rlm_completion_async(Query, Context, Options, Future).

llm_query(Prompt, Options, Outcome).
llm_query_async(Prompt, Options, Future).

rlm_query(Query, Context, Options, Outcome).
rlm_query_async(Query, Context, Options, Future).
```

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

Async facades do not duplicate model/tool/agent/graph business logic. They schedule the existing operation through `rlm_async` and preserve its ordinary result term.

This makes the async layer suitable for responsive clients such as a future `agentProlog` TUI while keeping synchronous scripts and simple expert systems straightforward.

Async execution does not bypass capability checks, budgets, cancellation rules, tool confinement, or any later authority policy. Those checks remain inside the underlying operation.
