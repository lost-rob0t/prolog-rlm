# RLM frontend protocol v1

`prolog_agent_ui_v1` is the reusable frontend boundary exported by `prolog-rlm` for bundled and external agent products, renderers, and editor integrations.

The wire identifier remains `prolog_agent_ui_v1` for compatibility. Shipping an in-repo AgentProlog application and reference harness does not rename or version-bump the reusable protocol.

The protocol is deliberately smaller than the runtime. A frontend renders canonical state, sends explicit commands, and negotiates presentation capabilities. It does not execute tools, implement authority, rebuild session state from raw traces, or import runtime internals.

## Boundary

```text
bundled AgentProlog / bundled DeepSeek TUI / JS / CL / Nim / Emacs / Lem
                              |
                              | prolog_agent_ui_v1
                              | snapshots + ordered events + commands
                              v
                    prolog-rlm frontend facade
                              |
                              v
                    canonical runtime state
```

The runtime facade converts canonical agent/runtime events once into frontend-safe JSON values. Renderers should not independently translate low-level traces into domain state.

This repository now also ships `agentProlog/` application composition and `harness/` frontend consumers. They consume this boundary exactly like external clients. Reusable `prolog/` protocol/runtime code must not import those product/frontend layers.

## Reference transport

The first reference encoding is UTF-8 NDJSON: exactly one JSON object per line.

A newline is only framing. Protocol semantics do not depend on stdio, so a later Unix/local socket transport can carry the same records unchanged.

The deterministic child-process fixture is test support:

```sh
swipl -q -s test/support/prolog-agent-ui-fixture.pl
```

The bundled AgentProlog application also exposes a persistent protocol adapter:

```sh
nix run .#agentprolog-ui
```

Write one client frame per line and read one or more server frames per line.

## Common envelope

Every frame contains:

```json
{
  "protocol": "prolog_agent_ui_v1",
  "kind": "event"
}
```

The first version defines these frame kinds:

- `negotiate`
- `snapshot`
- `event`
- `command`
- `result`
- `error`

### Stable IDs

Session, snapshot, event and request identifiers are opaque stable strings. A frontend may compare or store them but must not infer meaning from their spelling.

### Sequence numbers

Only state-changing server events use `seq`.

`seq` is monotonically increasing per session and is the authoritative replay cursor. Request IDs are separate and never double as sequence numbers.

A duplicate event whose sequence is at or below the client's applied cursor is ignored. A forward gap is an error rather than permission to guess what happened.

## Negotiation

A client starts with:

```json
{
  "protocol": "prolog_agent_ui_v1",
  "kind": "negotiate",
  "request_id": "req_1",
  "payload": {
    "protocol_versions": ["prolog_agent_ui_v1"],
    "required_capabilities": ["approvals"],
    "optional_capabilities": ["mouse", "side_by_side_diff"]
  }
}
```

Unsupported required capabilities fail negotiation. Unsupported optional capabilities are omitted from the accepted set.

Presentation capabilities currently recognized by the fixture include native file buffers, side-by-side diffs, mouse input, clipboard support and multiple windows. These do not transfer execution authority to a frontend.

## Snapshot

A snapshot is bounded canonical state at one event cursor:

```json
{
  "protocol": "prolog_agent_ui_v1",
  "kind": "snapshot",
  "session_id": "session_1",
  "snapshot_id": "snapshot_42",
  "at_seq": 42,
  "state": {
    "status": "running",
    "run": {},
    "messages": [],
    "tools": [],
    "approvals": [],
    "questions": [],
    "subagents": [],
    "verification": [],
    "usage": {},
    "traces": [],
    "indeterminate_effects": [],
    "extensions": []
  }
}
```

The v1 reference validator caps a snapshot at 1 MiB and caps nested collections at 256 entries. Streaming text is reduced into message state instead of retaining one snapshot item per token/delta.

The exact bounds may be revised only with a protocol-compatible rule or a later protocol version. Frontends must not assume a snapshot contains the entire historical transcript.

## Events

An event has an authoritative sequence and stable event ID:

```json
{
  "protocol": "prolog_agent_ui_v1",
  "kind": "event",
  "session_id": "session_1",
  "seq": 43,
  "event_id": "evt_43",
  "event_type": "verification",
  "payload": {
    "name": "authority",
    "outcome": {"status": "pass"}
  }
}
```

The initial semantic set covers:

- run start/finish;
- message start, text delta and completion;
- tool start/output/finish;
- approval request/resolution;
- question request/answer;
- subagent start/finish;
- verification;
- usage;
- trace references;
- indeterminate effects.

A tool name is data, not a closed renderer enum. Unknown tools must receive a generic safe rendering.

## Commands and correlation

A frontend sends an explicit command:

```json
{
  "protocol": "prolog_agent_ui_v1",
  "kind": "command",
  "session_id": "session_1",
  "request_id": "req_77",
  "command": "approval.decide",
  "payload": {
    "approval_id": "approval_1",
    "decision": "allow_once"
  }
}
```

The immediate result carries the same `request_id`. Any semantic event caused by the command may include:

```json
{"caused_by": "req_77"}
```

This is correlation only. The event still receives its own server sequence.

Command names are application-level data inside the reusable envelope. The bundled AgentProlog adapter currently defines:

- `run.submit` — start one canonical AgentProlog/RLM execution;
- `session.poll` — inspect the state of the active asynchronous execution;
- `session.cancel` — cancel the canonical `rlm_async` Future and linked child work.

Those commands do not move execution semantics into the protocol module. Other products may define their own command vocabulary while preserving the same correlation and authority rules.

## Reconnect

Reconnect is always:

```text
negotiate
-> canonical snapshot
-> ordered events after snapshot.at_seq
```

A frontend never reconstructs canonical state from pretty logs or assumes its local projection is authoritative.

The client may provide a previous cursor as reconnect metadata. The server may choose a canonical checkpoint older than that cursor. Overlapping events are safe because already-applied sequence numbers are ignored. Missing forward sequence numbers are not safe and produce a sequence-gap error.

The first bundled `agentprolog-ui` adapter slice provides a fresh bounded snapshot at negotiation and a single active-run application session. Full durable reconnect/replay belongs to later work and must use canonical runtime state rather than frontend-local reconstruction.

## Extensions

Unknown events are allowed only when they carry an explicit extension descriptor:

```json
{
  "event_type": "future_hint",
  "extension": {
    "namespace": "example.ui",
    "required": false
  }
}
```

Optional unknown events advance the sequence and are retained as generic extension records.

An unknown event with `required: true` fails closed unless a future negotiation/version explicitly establishes support. This prevents a renderer from silently ignoring new authority or execution semantics.

## Errors

Protocol and fixture errors use structured records:

```json
{
  "protocol": "prolog_agent_ui_v1",
  "kind": "error",
  "session_id": "session_1",
  "request_id": "req_1",
  "code": "sequence_gap",
  "message": "Event stream has a sequence gap",
  "details": {}
}
```

Consumers should branch on `code`, not human prose.

## Deterministic fixture

`test/fixtures/prolog_agent_ui_v1_session.ndjson` is the polyglot golden session. It covers streaming text, normal and unknown tools, approvals, questions, a subagent, verification, usage, traces, an indeterminate effect and an optional unknown extension.

The PlUnit suite also generates 10,000 text deltas with semantic trace markers interleaved every 1,000 deltas. Replay must preserve marker order, retain the final verification event and reduce the stream into a bounded snapshot.

The bundled AgentProlog application adds deterministic product-level tests with deferred fake Futures so negotiation, request correlation, exactly-once terminal projection and cancellation can be proven without network/provider credentials.

## Clients

The bundled AgentProlog application, bundled DeepSeek TUI, and external frontends should build against this boundary rather than importing runtime internals. If a client needs hidden runtime knowledge to behave correctly, fix or explicitly version the protocol/facade instead of smuggling execution semantics into the renderer.

## Non-goals for v1 foundation

This reusable layer does not define renderer layout, execute tools in a client, persist frontend-local preferences, expose raw authority handlers, choose the final socket transport, or make any bundled harness authoritative over the runtime.
