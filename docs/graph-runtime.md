# Durable state graphs

`rlm_graph` provides a bounded, resumable state-graph runtime for prolog-rlm.
It ports the useful orchestration properties of state-graph systems into a
Prolog-native design without making Python API compatibility a goal.

The graph specification is **declarative**. It contains state fields, node IDs,
edge structure, router IDs and subgraph IDs. Executable closures are supplied
separately by trusted host code in a registry. Model-produced graph data never
becomes a Prolog callable.

## Canonical async execution

Latency-bearing run/resume operations are async-first:

```prolog
graph_run_async(+Compiled, +InitialState, +Options, -Future).
graph_run(+Compiled, +InitialState, +Options, -Outcome).
graph_resume_async(+Compiled, +Backend, +RunId, +Resume, +Options, -Future).
graph_resume(+Compiled, +Backend, +RunId, +Resume, +Options, -Outcome).
```

The async surfaces submit `graph_run_execute/4` and `graph_resume_execute/6`.
The synchronous surfaces start those same operations and await their Futures.
Inline subgraphs call the execute ABI directly, preventing nested Future waits
when a graph already occupies an `rlm_async` worker. Compilation, schema
validation, checkpoint lookup/history, and backend metadata remain immediate.

Future metadata carries operation, graph ID, requested run ID, trace ID and
session ID when available. Execute predicates remain a trusted host/library
composition ABI and are not model-callable graph registry entries.

## Public API

The main `rlm` module exports:

```prolog
default_graph_options(-Defaults).
graph_compile(+Spec, +Registry, +Options, -Outcome).
graph_backend_open(+BackendSpec, -Backend).
graph_backend_close(+Backend).
graph_run(+Compiled, +InitialState, +Options, -Outcome).
graph_resume(+Compiled, +Backend, +RunId, +Resume, +Options, -Outcome).
graph_checkpoint(+Backend, +RunId, -Snapshot).
graph_history(+Backend, +RunId, -Events).
graph_cancellation_token(-Token).
graph_cancel(+Token).
```

## State schema

Every graph declares a closed state schema:

```prolog
[
    field(count, integer, 0, sum),
    field(messages, list, [], append),
    field(status, atom, pending, replace)
]
```

Supported types are:

- `any`
- `atom`
- `string`
- `integer`
- `number`
- `boolean`
- `list`
- `dict`

Supported reducers are deliberately closed:

- `replace`
- `append`
- `sum`

Node updates may change only declared fields. The reducer is applied before the
new value is checked against the declared type.

## Graph specification

Term form:

```prolog
graph(review_flow,
      [ field(attempts, integer, 0, sum),
        field(log, list, [], append),
        field(approved, boolean, false, replace)
      ],
      [ node(analyze, analyze_handler),
        node(decide, decide_handler),
        node(finish, finish_handler)
      ],
      [ edge(start, analyze),
        edge(analyze, decide),
        conditional(decide,
                    review_router,
                    [ route(retry, analyze),
                      route(done, finish)
                    ]),
        edge(finish, end)
      ]).
```

Structured dicts with equivalent `id`, `schema`, `nodes` and `edges` fields are
also accepted.

`start` and `end` are reserved endpoints. They are not executable nodes.

## Trusted registry

Closures are host configuration, not graph data:

```prolog
Registry = [
    handler(analyze_handler, my_graph:analyze),
    handler(decide_handler, my_graph:decide),
    handler(finish_handler, my_graph:finish),
    router(review_router, my_graph:route_review)
].
```

An action handler is called as:

```prolog
Handler(+State, +Context, -NodeResult)
```

A router is called as:

```prolog
Router(+State, -RouteKey)
```

The compiler rejects references that do not exist in the trusted registry.

## Compile-time validation

`graph_compile/4` validates before any node executes:

- state-field keys are unique;
- node names are unique;
- `start` and `end` cannot be node names;
- exactly one edge leaves `start`;
- `end` has no outgoing edge;
- every node has exactly one outgoing edge definition;
- edge targets exist or are `end`;
- conditional route keys are unique;
- router IDs exist in the trusted registry;
- action and subgraph IDs exist in the trusted registry;
- every node is reachable from `start`;
- every node has at least one structural path to `end`.

A structurally cyclic graph is allowed when it can still reach `end`. Runtime
budgets prevent a router from looping forever.

## Node results

A normal update:

```prolog
update(_{attempts:1, log:[analyzed]})
```

A dict patch may also be returned directly.

An interrupt:

```prolog
interrupt(needs_approval,
          _{log:[waiting_for_approval]})
```

Interrupts apply their patch, resolve the outgoing edge, persist the next node,
and return a paused result. Resume therefore continues from the next node
rather than repeating the interrupting side effect.

## Runtime bounds

Defaults are reported by `default_graph_options/1`. Execution supports:

```prolog
[
    max_steps(128),
    max_visits_per_node(32),
    time_limit(30.0),
    backend(Backend),
    event_handler(my_stream:event),
    cancellation_token(Token),
    run_id(my_run)
]
```

`max_steps` bounds total node executions. `max_visits_per_node` independently
bounds loops concentrated on one node. `time_limit` uses a hard wall-time
boundary and can interrupt a blocking node.

## Checkpoint backends

### Memory

```prolog
graph_backend_open(memory, Backend).
```

Useful for one-process resumability and tests. State disappears when the backend
is closed.

### Persistent journal

```prolog
graph_backend_open(persist('/var/lib/my-app/graph.db'), Backend).
```

The persistent backend uses SWI-Prolog `library(persistency)`. It stores only
ground graph snapshots and ordered events; executable registry closures are not
persisted.

A host restart therefore follows this contract:

1. load the graph definition and trusted registry again;
2. compile the graph;
3. attach the same persistent journal;
4. inspect the saved checkpoint if desired;
5. call `graph_resume/6` with the run ID.

The deterministic CI suite proves this with **two different `swipl` processes**:
process one pauses and exits; process two loads the graph code from scratch,
reattaches the journal and resumes to completion.

Only one persistent journal is attached to the `rlm_graph_persist` module at a
time. Applications that need many independent journals should serialize access
or introduce a higher-level persistence service.

## Resume

Example:

```prolog
graph_run(Compiled,
          _{},
          [ backend(Backend),
            run_id(review_42)
          ],
          ok(Paused)),

Paused.status = paused(needs_approval),

graph_resume(Compiled,
             Backend,
             review_42,
             approved,
             [],
             ok(Completed)).
```

A resume value is available to the resumed node as `Context.resume`.

A resume may also atomically patch graph state:

```prolog
resume(approved,
       _{approved:true})
```

Only paused runs can be resumed, and the persisted `graph_id` must match the
compiled graph.

## Events and history

Execution emits ordered events such as:

- `run_started`
- `node_started`
- `node_completed`
- `edge_selected`
- `interrupted`
- `resumed`
- `run_completed`

Events are written to the configured checkpoint backend and may additionally be
streamed to a trusted host callback:

```prolog
[event_handler(my_module:graph_event)]
```

Before persistence or streaming, event payload dicts are recursively
canonicalized to fixed dict tags. This prevents otherwise-ground JSON-style
anonymous dict tags from becoming non-ground persisted terms.

`graph_history/3` returns events in sequence order.

## Cancellation

```prolog
graph_cancellation_token(Token),
graph_run(Compiled,
          State,
          [cancellation_token(Token)],
          Outcome).
```

Another thread may call:

```prolog
graph_cancel(Token).
```

Cancellation signals the thread currently executing that graph. Nested inline
subgraphs share the same token and use reference-counted thread registration, so
a subgraph cannot accidentally unregister its parent's cancellation boundary.

## Subgraphs

Declare a subgraph node:

```prolog
subgraph(enrich, enrichment_graph)
```

and register the compiled child graph:

```prolog
subgraph(enrichment_graph, CompiledChild)
```

The child runs inline with the same cancellation token. Its resulting state is
converted back into reducer-aware deltas before being applied to the parent.
For example, a child moving a `sum` field from 2 to 5 contributes `3`, not `5`,
when merged into the parent.

An inline subgraph must complete; a paused child produces a structured
`subgraph_interrupted` failure rather than silently hiding a nested checkpoint.

## Acceptance coverage

Deterministic CI covers:

- conditional branching and bounded loops;
- unreachable-node rejection;
- structural no-path-to-end rejection;
- per-node visit exhaustion;
- state type validation and reducer behavior;
- memory checkpoint interrupt/resume;
- persistent detach/reattach resume;
- persistent resume across two fresh SWI processes;
- ordered event streaming/history;
- hard wall-time interruption;
- active cancellation of a blocking node;
- subgraph execution with reducer-aware state deltas.
