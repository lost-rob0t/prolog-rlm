# Durable effect identity

Prolog search may backtrack. External effects must not be repeated merely
because later logic failed.

`prolog-rlm` therefore separates a logical call, its normalized executable
fingerprint, admitted attempts, and immutable authoritative observations. It
prevents implicit duplicate execution; it does not claim generic exactly-once
execution across external protocols.

## Identity

- `store_id`: a durable random namespace created once for a new ledger and
  preserved when that ledger is reopened.
- `call_id`: stable logical operation identity within one store epoch. An
  explicit `logical_key` may keep one logical job identity across edited
  executable payloads.
- `fingerprint`: SHA-256 over normalized effect kind, request, and explicit
  semantics. Trace/session metadata is excluded.
- `attempt_id`: one admitted execution attempt.
- `parent_attempt`, `sequence`, `mode`: explicit retry/resample lineage.
- `idempotency_key`: stable provider key derived from the attempt, distinct from
  the call ID and fingerprint.

Changed commands, targets, provider requests, arguments, and mutation payloads
produce new executable fingerprints. Re-entering the same explicit retry or
resample resolves to the same deterministic child attempt instead of creating
another attempt through backtracking.

Durable boundaries require ground, acyclic supported values. Dict key ordering
is normalized before hashing. Non-ground, cyclic, and unsupported runtime values
are rejected.

### Raw ticket integrity

`effect_ticket` values are constructor-produced execution records, not trusted
merely because a caller supplies a dict with the right fields. Admission and
pre-claim cancellation validate the complete ticket shape and recompute the
identity-bearing relationships before the ticket may create an attempt.

Validation covers the normalized request and semantics, executable fingerprint,
logical call ID and logical key, durable store namespace and execution epoch,
retry/resample mode, parent attempt, sequence, attempt ID, and provider
idempotency key. The recomputed call must also match an existing durable call
record created by `rlm_effect_prepare/4`.

A fabricated ticket with stale or altered request/semantics, fingerprint,
attempt ID, lineage, or idempotency key therefore cannot manufacture trusted
execution identity. Host authority remains a separate boundary; a valid ticket
is not itself an authority grant.

## Lifecycle

```text
prepared
  -> admitted
  -> dispatching
  -> observed

prepared -> cancelled_before_claim
admitted -> cancelled_pre_dispatch
dispatching -> cancellation_requested -> indeterminate
indeterminate -> observed               (reconciliation)
indeterminate -> retry_authorized       (trusted host resolution)
indeterminate -> abandoned              (trusted host resolution)
```

Admission is the atomic local ownership claim. `dispatching` is durably written
**before** provider/tool code may cross the external boundary.

Attempts use append-only durable revisions. Observations are immutable. The
observation is persisted before the final `observed` attempt revision, so a
crash between those two local writes still leaves the authoritative observation
available on restart.

Attempt revisions and observations are authoritative state. Lifecycle events
are an idempotently repairable projection with deterministic event IDs. Reads
and reconciliation repair either crash window: observation durable before the
final attempt revision, or final attempt revision durable before its event.

## Crash between remote effect and observation

The mandatory case is:

```text
admitted -> dispatching -> remote effect accepted -> local process dies
```

A fresh process that sees `dispatching` without a terminal observation returns
reconciliation-required state. It never treats the missing observation as
permission to submit again.

If the provider supports reconciliation/idempotency, its adapter uses the
stable attempt idempotency key or remote operation ID to recover the original
result and records that observation. If the remote outcome cannot be determined,
the attempt becomes `indeterminate`; automatic retry is refused until trusted
host policy explicitly resolves it.

## Replay, retry, resample

- Replay returns the existing observation and performs no external effect.
- Retry is an explicit new attempt linked to its parent.
- Resample is an explicit fresh execution with a mode distinct from retry.
- A changed payload is a new executable fingerprint, not a retry of the old
  exact operation.
- `abandoned` is terminal bookkeeping, not authorization to retry. A trusted
  `retry_authorized` resolution is required before a retry or resample child is
  admitted.

Ordinary Prolog backtracking reuses the ledger observation. It does not resubmit.

## Authority

`rlm_effect_authority` composes #57 identity into the existing #53 operation
fingerprint. The authority tiers remain exactly `approve_diff`, `allow_once`,
`allow_session`, and `dangerous`; there is no public `yolo`.

Because the exact effect fingerprint and attempt ID are authority inputs,
`allow_once` cannot leak to a retry or changed payload. Correlation metadata is
not authority identity. `dangerous` skips interactive approval only; it does not
bypass identity, validation, capability checks, budgets, confinement,
accounting, tracing, cancellation, or persistence.

Executor identity is executable identity. Code using an adapter must prepare
through `rlm_effect_executor:effect_prepare/5`; the trusted adapter identity is
included in the fingerprint and persisted attempt metadata. Consequently an
`allow_once` grant, call, attempt, or provider key for one adapter cannot be
reused by another adapter.

An edited proposal must rebuild the effect ticket and trusted continuation from
the edited normalized request before execution.

## Async and cancellation

The #54 direction remains one implementation:

```text
effect_execute_execute/6 -> bounded rlm_async Future -> sync await
```

Repeated awaits/status calls and callback/continuation registration observe the
same Future and do not create another attempt.

Cancellation before claim or before dispatch is terminal without a remote
submission. Cancellation after dispatch records `cancellation_requested`; it is
not proof that the remote effect stopped. Confirmed provider cancellation may be
recorded as an observation. Unknown cancellation remains indeterminate.

## Accounting and trajectory

Durable events record admitted/dispatched attempts and observations. A
dispatched attempt remains visible even if later Prolog logic or its enclosing
plan fails. Observation events retain usage and provenance for #44 to consume
without creating a second accounting ledger. Attempt parent/sequence/mode data
is authoritative lineage for #45 trajectory work.

## Persistence and retention

The default backend uses SWI-Prolog persistency with synchronous journal writes.
Competing admission inside one Prolog runtime is serialized by the effect-state
mutex.

The executor holds a store execution lease across preparation, dispatch, remote
submission, and local observation. While a lease exists, closing the attached
store or switching to another store fails closed. This prevents an in-flight
adapter callback from completing against a different ledger.

This persistent backend enforces **one cooperating writer using local OS
advisory locking** on a dedicated sidecar for the canonical store path. A second
cooperating process opening the same store fails closed. Normal close releases
the lock, and process death releases the OS-owned lock so a fresh process may
attach and reconcile existing dispatched work.

This backend does **not** provide:

- distributed consensus;
- arbitrary multi-host compare-and-swap;
- universal exactly-once external execution;
- safety on filesystems whose locking semantics do not support this contract.

Pruning is explicit and refuses active, dispatching, cancellation-uncertain, or
indeterminate attempts. Successful prune first durably advances that logical
call's execution epoch and only then deletes its old records. Preparing the
same logical operation after prune therefore creates new call, attempt, and
provider idempotency identities; a pre-prune ticket is rejected as stale.

New stores use schema version 2. A non-empty legacy store without durable
namespace metadata fails closed with
`legacy_effect_store_requires_migration`; it is never silently assigned a new
namespace, because doing so could make an old provider operation look new.

Downstream applications such as media-gen should use this generic boundary
rather than implement another once-only ledger. Domain job IDs remain useful,
but they do not solve the narrower crash before the job ID/observation is saved.
Canonical provider/tool/MCP/process adoption is a separate integration slice
tracked by #79.

The precise guarantee is:

> `prolog-rlm` prevents implicit duplicate execution and provides durable
> attempt/observation identity with explicit reconciliation for uncertain
> external outcomes **when externally effectful execution is routed through
> this boundary**.
