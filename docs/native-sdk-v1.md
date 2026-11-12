# Native SDK v1 contract

This document defines the shared host/client contract for issue #466 and the
eight language SDK lanes #467-#474.

It does **not** introduce a second runtime protocol. The SDK family composes
existing Prolog-RLM contracts:

- `prolog_agent_ui_v1` for bounded snapshots, ordered events, correlated
  commands, capability negotiation, reconnect/replay, and frontend-safe state;
- `rlm_async` and issue #54 for canonical async-first execution with sync
  facades waiting on the same work;
- existing provider/tool/verifier execute ABIs for host backends;
- issue #453 A2A as an optional authenticated remote transport.

## Duplex library shape

Every SDK has two halves.

### Client

A native client can connect to a runtime, create/open/cancel work, submit a
task/prompt, consume typed events, inspect snapshots/status/usage/traces, and
resolve pending authority/questions through typed requests.

A client must not implement capability, authority, budget, effect, verification,
or retry policy locally. Those remain runtime-owned.

### Backend

A native host can register model, tool, and verifier backends. Registration is
availability only and never grants capability.

Each backend receives bounded typed requests with trusted correlation,
deadline/cancellation/budget context and returns typed progress/results/errors.
A language binding must not expose model text as executable Prolog or an ambient
shell/filesystem/network authority.

## Async law

Latency-bearing SDK operations follow one direction:

```text
native async call -> runtime operation/Future -> result
native sync facade --------------------^ waits
```

A binding may omit a sync facade when that would be unidiomatic, but it may not
implement separate sync business logic.

## Event and reconnect law

SDKs consume `prolog_agent_ui_v1` frames rather than creating language-specific
event semantics.

Required behavior:

- sequence gaps are errors requiring snapshot recovery;
- replayed/stale sequence numbers do not duplicate state;
- unknown optional extension events remain representable;
- unknown required extensions fail closed;
- reconnect obtains a fresh bounded snapshot and resumes after its sequence;
- an indeterminate external effect is distinct from success, failure, and
  cancellation.

## Native-language requirement

The wire shape is shared; public APIs are not required to resemble JSON.

Each SDK should map the contract to its language's normal idioms for:

- sum/variant types;
- structured errors;
- cancellation and deadlines;
- streams/iterators;
- resource lifetime;
- configuration;
- package layout and documentation.

The conformance manifest in
`test/fixtures/native_sdk_v1.json` is the shared minimum. Language lanes may add
tests, but may not weaken or redefine those scenarios.

## Initial language lanes

- Common Lisp — #467
- Python — #468
- TypeScript — #469
- Nim — #470
- Emacs Lisp — #471
- Kotlin/JVM/Android — #472
- Rust — #473
- Go — #474
