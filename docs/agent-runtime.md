# Supervised logical agents

`rlm_agent` provides a bounded logical-agent runtime for prolog-rlm. Logical
agents keep mutable state in SWI-Prolog engines, use finite message queues as
mailboxes, and share a bounded thread pool for blocking trusted host work.

The design deliberately avoids one permanent operating-system thread per agent.
An engine is driven only while the supervisor processes a mailbox message.
Provider/tool work that may block is dispatched to the runtime's worker pool.

## Public lifecycle

The main `rlm` module exports the host-facing agent API:

```prolog
agent_runtime_create(+Options, -Runtime).
agent_runtime_destroy(+Runtime).
agent_runtime_status(+Runtime, -Status).
agent_spawn(+Runtime, +Parent, +Spec, +Capabilities, -Outcome).
agent_spawn_async(+Runtime, +Parent, +Spec, +Capabilities, -Future).
agent_send(+Runtime, +Agent, +Message, +Options, -Outcome).
agent_send_async(+Runtime, +Agent, +Message, +Options, -Future).
agent_pump(+Runtime, +Agent, +Options, -Outcome).
agent_pump_async(+Runtime, +Agent, +Options, -Future).
agent_supervised_call(+Runtime, +Agent, +Handler, +Work, +Options, -Outcome).
agent_supervised_call_async(+Runtime, +Agent, +Handler, +Work, +Options, -Future).
agent_status(+Runtime, +Agent, -Outcome).
agent_children(+Runtime, +Agent, -Children).
agent_cancel(+Runtime, +Agent, +Reason, -Outcome).
agent_cancel_async(+Runtime, +Agent, +Reason, -Future).
agent_trace(+Runtime, -Events).
```

Spawn, send, pump, and cancellation are canonical async-first operations. Each
`*_async` predicate submits one `*_execute` operation to `rlm_async`; each sync
predicate starts that same operation and awaits its Future. Trusted library
code already running inside a canonical async worker calls the execute ABI
directly instead of starting and waiting on a nested Future.

The execute predicates are a trusted host/library composition ABI, not part of
model-generated callable resolution. `rlm_async` schedules public API work; the
agent runtime's separate bounded worker pool still bounds blocking mailbox host
work and preserves actor fairness, backpressure, and supervision semantics.

`agent_supervised_call/6` admits one ground work value into an existing logical
agent, runs a ground trusted host closure on that same bounded worker pool, and
waits for the result through the agent mailbox. Its `timeout(Seconds)` option is
a positive wall-time ceiling. The handler is host-owned executable policy; it
is never derived from model or KB data. Cancellation of a parent signals the
admitted child worker, preserves the child's cancelled terminal state, and
returns a structured cancelled outcome.

Always destroy a runtime with `setup_call_cleanup/3` or an equivalent host
lifecycle. Destruction cancels outstanding worker activity, drains the bounded
worker pool, destroys engines/mailboxes, and clears the runtime registry.

Example:

```prolog
setup_call_cleanup(
    agent_runtime_create(
        [ root_capabilities([tool(spawn_agent), tool(read)]),
          worker_count(2),
          mailbox_size(16)
        ],
        Runtime),
    run_agents(Runtime),
    agent_runtime_destroy(Runtime)).
```

## Runtime options

`default_agent_options/1` reports the defaults. Supported overrides are:

- `max_agents(N)` — maximum logical agents in the runtime;
- `mailbox_size(N)` — maximum queued messages per agent;
- `worker_count(N)` — maximum simultaneous blocking workers;
- `worker_backlog(N)` — bounded worker-pool backlog;
- `send_timeout(Seconds)` — bounded enqueue wait;
- `trace_limit(N)` — maximum retained runtime trace events;
- `root_capabilities(Capabilities)` — authority available to root agents;
- `worker_handler(Closure)` — trusted host worker adapter.

The worker handler is host configuration. The model never supplies or receives
its callable.

## Agent identity and supervision

Agents are represented externally as opaque logical IDs:

```prolog
agent(agent_7)
```

A root has parent `none`. A child has a supervisor agent. Child authority is
always produced with `capabilities_narrow/3`; requesting authority outside the
parent set returns `capability_denied` and creates no child.

```prolog
agent_spawn(Runtime,
            none,
            agent_spec(root),
            [tool(spawn_agent), tool(read)],
            ok(Root)),
agent_spawn(Runtime,
            Root,
            agent_spec(child),
            [tool(read)],
            ok(Child)).
```

The child cannot add a capability that is not held by its parent.

## Agent specifications

Compact term syntax:

```prolog
agent_spec(worker_name)
```

Structured syntax:

```prolog
agent_spec{
    name:worker_name,
    mode:worker,
    metadata:agent_metadata{dataset:"example"}
}
```

JSON-origin dict tags are canonicalized before storage. Actual metadata values
must still be closed JSON-like data: dicts, lists, and atomic values. Unbound or
arbitrary compound values are rejected.

## Mailbox protocol

The runtime recognizes a closed message vocabulary:

```prolog
request(RunId, CallId, Work).
result(CallId, Result).
spawn(Parent, Child, Spec, Capabilities).
cancel(RunId, Reason).
checkpoint(RunId, Label).
budget_exhausted(RunId, Kind).
```

Mailboxes are finite. `agent_send/5` returns a structured `mailbox_full` error
when the queue cannot accept another message within the configured timeout.
Backpressure is therefore explicit rather than unbounded memory growth.

`agent_pump/4` removes at most one mailbox item and drives the target engine for
that transition. An empty mailbox returns an `idle` result.

## Blocking worker work

A `request/3` message moves a trusted operation to the shared worker pool:

```prolog
worker_handler(work(fetch, Request), Response) :-
    trusted_fetch(Request, Response).
```

Runtime configuration:

```prolog
agent_runtime_create(
    [ worker_count(2),
      worker_backlog(4),
      worker_handler(my_module:worker_handler)
    ],
    Runtime).
```

The worker pool is global to that logical runtime. Twenty logical agents may
exist while only two blocking workers can execute concurrently. If the pool and
its configured backlog cannot accept another request, dispatch fails with a
structured `worker_pool_saturated` outcome instead of spawning an unbounded
thread.

Worker results return through the requesting agent's mailbox as `result/2`.
Worker exceptions are converted to structured failures in the agent state.

When the requesting agent is supervised, a successful worker result is also
enqueued to its parent as `result(child(agent(ChildId)), ok(Value))`. The
parent records that value as a canonical `child_result`, and the runtime emits
one correlated `child_result` trace event containing the opaque parent and
child identities. If the bounded parent mailbox rejects delivery, the runtime
emits `child_result_backpressure` instead of claiming delivery.

The canonical `rlm_subagent` tool uses this supervised-call execute ABI. Its
bounded completion therefore runs as child-owned worker activity rather than
inside the tool-handler thread. An `unknown -> delegate_subagent` KB command
still compiles only to inert `tool(rlm_subagent)` data; ordinary tool
capability/authority checks run before child creation, and the parent receives
the same typed subagent result envelope that the tool returns.

## Failure supervision

When child work fails, the child enters a failed state and its supervisor gets
an observable child result:

```prolog
result(child(agent(ChildId)), error(Error))
```

A `child_failure` runtime trace event records the supervisor, child and
structured error. Parent code can therefore inspect failure without scraping
stderr or inspecting a worker thread directly.

## Cancellation

`agent_cancel/4` recursively cancels supervised children and signals outstanding
workers before marking the logical agent cancelled:

```prolog
agent_cancel(Runtime, Parent, user_cancelled, ok(_)).
```

Children do not continue normal supervised work after their parent run is
cancelled. The runtime does not expose engine or thread handles to model output.

## Bounded traces

`agent_trace/2` returns ordered, ground `agent_event` dicts such as:

- `runtime_created`;
- `spawn`;
- `mailbox_enqueued`;
- `mailbox_backpressure`;
- `request_dispatched`;
- `worker_completed`;
- `worker_result_enqueued`;
- `child_result`;
- `child_result_backpressure`;
- `child_failure`;
- `cancel`.

Only the newest `trace_limit` events are retained.

## `spawn_agent` in typed plans

`spawn_agent` is syntax over the existing closed trusted-tool boundary. It does
**not** create a second interpreter or allow model text to become a callable.

Term form:

```prolog
plan([
    spawn_agent(agent_spec(child), [tool(read)], child),
    final(var(child))
]).
```

JSON form:

```json
{
  "steps": [
    {
      "op": "spawn_agent",
      "spec": {
        "name": "child",
        "mode": "worker",
        "metadata": {}
      },
      "capabilities": [
        {"type": "tool", "name": "read"}
      ],
      "bind": "child"
    },
    {
      "op": "final",
      "value": {"ref": "var", "name": "child"}
    }
  ]
}
```

Both normalize to the closed operation:

```prolog
tool(spawn_agent,
     literal(agent_spawn_request{
         spec:Spec,
         capabilities:Capabilities
     }),
     Bind)
```

Consequences:

- the plan must possess `tool(spawn_agent)`;
- preflight requires a trusted registered handler;
- spawn consumes the normal shared plan step/tool budgets;
- tool output remains subject to output-byte limits;
- execution is traced through the existing plan transition machinery;
- capability denial happens before agent creation.

Host registration example:

```prolog
Options = [
    tools([
        tool(spawn_agent,
             rlm:agent_tool_handler(Runtime, Parent))
    ])
].
```

The adapter accepts only the normalized spawn request, validates child
capability descriptors, and calls the supervised runtime. The model never
selects the Prolog closure.

## Acceptance coverage

The deterministic suite proves:

- a child receives only a subset of parent capabilities;
- twenty logical agents coexist without twenty idle worker threads;
- finite mailbox capacity produces backpressure;
- worker results return through mailboxes;
- child worker crashes are visible to the supervisor;
- cancellation propagates to child work;
- worker-pool saturation fails closed;
- trace retention is bounded;
- term-form `spawn_agent` executes through the trusted tool boundary;
- JSON-form `spawn_agent` canonicalizes JSON dict tags and executes;
- missing `tool(spawn_agent)` authority prevents child creation.
