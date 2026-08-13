# Durable RLM artifact runtime

`rlm_artifact` is the cross-run durable state layer for recursive and staged RLM execution. It exists so a later reasoning root can consume compact, explicit state from earlier work without inheriting the earlier root's full conversation or transcript.

The core separation is:

```text
conversation/transcript
  -> model-local interaction history

checkpoint
  -> execution/thread state needed to resume a graph

artifact store
  -> selected durable summaries/findings/blackboards shared across runs
```

A graph checkpoint may contain **artifact references**, but the artifact payloads live in the artifact store. Checkpoint replay therefore does not turn an entire transcript into durable context.

## Public store API

Open an in-memory or persistent store:

```prolog
artifact_store_open(memory, Outcome).
artifact_store_open(persist(File), Outcome).
artifact_store_close(Store, Outcome).
```

Publish a new immutable artifact version:

```prolog
artifact_put(+Store,
             +Namespace,
             +Key,
             +Kind,
             +Value,
             +Provenance,
             -Outcome).
```

Read an exact historical version or the current version:

```prolog
artifact_get(+Store, +Ref, -Outcome).
artifact_latest(+Store, +Namespace, +Key, -Outcome).
artifact_list(+Store, +Namespace, +Options, -Outcome).
artifact_ref_status(+Store, +Ref, -Outcome).
```

Build bounded fresh-root context:

```prolog
artifact_context_pack(+Store, +Namespace, +Options, -Outcome).
artifact_context_refs(+Store, +Refs, +Options, -Outcome).
```

Inspect durable producer/consumer linkage:

```prolog
artifact_trace(+Store, +Namespace, -Outcome).
```

## Artifact record

Every successful publication creates a ground record shaped like:

```prolog
rlm_artifact{
    ref: artifact_ref{
        namespace: Namespace,
        key: Key,
        version: Version
    },
    namespace: Namespace,
    key: Key,
    kind: Kind,
    version: Version,
    value: Value,
    provenance: Provenance
}
```

`Namespace` is a non-empty list of atom segments. `Key` and `Kind` are non-empty atoms. `Value` and `Provenance` must be ground. Dict/list payloads are canonicalized into ground Prolog data rather than retaining mutable runtime objects.

Version allocation and the corresponding publish trace are committed under the same backend mutex. Versions are monotonically increasing per `(Namespace, Key)` and are immutable once written.

A later write to the same key **supersedes** the prior version; it does not overwrite or delete it. Exact historical refs remain readable.

## Superseded references

Use:

```prolog
artifact_ref_status(Store, Ref, Outcome).
```

Possible successful statuses include:

```prolog
current(Ref)
stale(OldRef, CurrentRef)
missing_version(OldRef, CurrentRef)
missing(Ref)
```

`artifact_context_refs/4` resolves a stale ref to the latest version for the same namespace/key and returns the supersession explicitly in `stale_refs`.

This makes stale-state handling deterministic: a fresh root receives the current artifact while retaining evidence that its checkpoint or agent state referred to an older version.

## Bounded context packs

Context handoff is explicit and bounded. Supported selection options include:

```prolog
kinds([summary, finding, blackboard])
keys([working_summary, evidence])
max_items(16)
max_chars(12000)
consumer(ConsumerIdentity)
```

A namespace pack is shaped like:

```prolog
artifact_context_pack{
    namespace: Namespace,
    entries: Entries,
    refs: Refs,
    item_count: Count,
    chars: CharacterBudgetUsed,
    truncated: Boolean
}
```

A ref-based pack additionally reports stale refs:

```prolog
artifact_ref_context_pack{
    entries: Entries,
    refs: CurrentRefs,
    stale_refs: Supersessions,
    item_count: Count,
    chars: CharacterBudgetUsed,
    truncated: Boolean
}
```

The store selects only the latest version of each key unless `history(true)` is explicitly requested from `artifact_list/4`. Fresh-root context functions never inject artifact history or conversational transcript implicitly.

## Provenance and trace linkage

Producers supply provenance when publishing. Agent and graph helpers augment it with runtime identity automatically.

Examples of producer identity fields are:

```prolog
_{ producer_type: agent,
   runtime_id: RuntimeId,
   agent_id: AgentId,
   call_id: CallId
 }

_{ producer_type: graph,
   run_id: RunId,
   graph_id: GraphId,
   node: Node,
   step: Step,
   call_id: CallId
 }
```

Each publication appends a `published` trace event containing the immutable artifact ref and producer provenance. Each context handoff appends a `consumed` event containing the current refs, consumer identity, and any stale-ref supersessions.

Persistent stores persist these trace events alongside artifact records, so producer/consumer linkage survives process restart.

## Agent integration

`rlm_artifact_agent` integrates artifact refs with the existing supervised-agent checkpoint mailbox:

```prolog
agent_artifact_publish(+Runtime,
                       +Agent,
                       +Store,
                       +Key,
                       +Kind,
                       +Value,
                       +Provenance,
                       -Outcome).

agent_artifact_refs(+Runtime, +Agent, -Outcome).
agent_artifact_context(+Runtime, +Agent, +Store, +Options, -Outcome).
```

Publishing persists the artifact first, then queues:

```prolog
checkpoint(RuntimeId, artifact(Ref))
```

through the existing typed mailbox. The normal agent pump establishes that handle in `State.checkpoints`. The helper does **not** pump the mailbox itself, so publishing cannot unexpectedly consume unrelated queued agent work.

The checkpoint contains only `artifact(Ref)`, not the artifact payload and not prior messages. A later agent/RLM call resolves those refs through `agent_artifact_context/5` and receives a bounded pack.

## Graph integration

`rlm_artifact_graph` integrates artifact refs with typed graph state:

```prolog
artifact_graph_schema_field(field(artifact_refs, list, [], append)).
```

Include that field in a graph schema. A node can publish with:

```prolog
graph_artifact_publish(Store,
                       Context,
                       Key,
                       Kind,
                       Value,
                       Provenance,
                       Outcome).
```

The successful outcome contains:

```prolog
graph_artifact{
    artifact: Artifact,
    patch: _{artifact_refs:[Ref]}
}
```

Return the patch through the ordinary graph node update/interrupt path. The ref then becomes part of typed graph state and is persisted by the existing checkpoint backend.

A later node or resumed process consumes the refs with:

```prolog
graph_artifact_context(Store, Context, State, Options, Outcome).
```

The graph helper derives producer/consumer identity from `run_id`, `graph_id`, `node`, and `step` in the canonical graph context.

## Fresh-process restart invariant

CI runs a two-process artifact restart fixture:

```text
process 1
  graph node publishes artifact
  -> persistent artifact DB contains payload + publish trace
  -> graph state stores only artifact_ref
  -> graph interrupts/checkpoints
  -> process exits

process 2
  opens graph checkpoint DB
  opens artifact DB
  -> checkpoint restores artifact_ref
  -> graph resumes at fresh node
  -> node resolves compact artifact context
  -> consume trace is persisted
  -> graph completes
```

This proves that graph restart preserves the durable artifact needed by a resumed run without preserving the producer node's transcript.

## Backends

### Memory

`memory` is process-local and intended for deterministic tests or non-durable runs. It provides the same version/ref/trace semantics as the persistent backend.

### Persist

`persist(File)` uses SWI-Prolog `library(persistency)`. Artifact records and trace events are stored separately from graph checkpoint records. The backend is accessed through the `rlm_artifact` facade so a later storage implementation can replace it without changing agents, graphs, or RLM callers.

## Failure contract

Ordinary failures return structured `error(artifact_error{...})` outcomes. The runtime fails closed for non-ground payloads/provenance, invalid namespaces, malformed refs, invalid selection budgets, closed stores, and missing refs.

An agent publication that persists successfully but cannot queue its checkpoint attachment reports `attachment_failed` and includes the already-persisted artifact ref. It never silently claims the ref entered agent state.

## Relationship to model providers and MCP

Artifacts are internal RLM state. They do not alter provider selection, direct OpenRouter completion behavior, or the canonical MCP boundary.

A fresh model root should receive only the explicitly selected artifact pack needed for the next stage. Provider message history remains provider/message history; MCP resources remain MCP resources; graph checkpoints remain graph execution state.
