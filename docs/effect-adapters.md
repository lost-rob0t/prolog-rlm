# Effect adapter integration

`rlm_effect_executor` is the reusable execution boundary for effectful provider
and tool libraries. Provider-specific code translates a normalized runtime
request to the remote protocol; it does not own a second generic effect ledger.

For unresolved attempts migrated from the PR #78 store schema, trusted adapter
identity may come from the immutable operator-reviewed binding described in
[effect-migration.md](effect-migration.md). It is equivalent to code-owned
identity for reconciliation matching, cannot be overridden by request or
correlation metadata, and is never inferred during migration.

Adapters are static code-owned multifile hooks:

```prolog
:- multifile rlm_effect_executor:effect_adapter_submit/4.
:- multifile rlm_effect_executor:effect_adapter_reconcile/4.
:- multifile rlm_effect_executor:effect_adapter_cancel/4.
```

They are deliberately not dynamic model-writable facts.

## Canonical request contract

Callers of an effect adapter must prepare with:

```prolog
effect_prepare(Adapter, Kind, Request, Options, Decision).
```

The executor overwrites the reserved `executor_identity` semantics and metadata
with the code-selected adapter. That identity participates in the executable
fingerprint and is recorded with the attempt. Do not prepare adapter work by
calling `rlm_effect_prepare/4` directly.

The request passed to adapters is the canonical normalized executable request
produced beneath `effect_prepare/5`, not the caller's pre-normalization term.
The same canonical representation is persisted with the logical call and is
used again for later reconciliation.

Therefore, for one admitted attempt:

```text
caller request
  -> normalize once for executable identity
  -> ticket.request
  -> submit/cancel adapter

persisted call.request
  -> reconciliation adapter
```

`ticket.request` and `call.request` are required to be identical canonical
representations. Submit, cancellation, and reconciliation must not acquire
separate interpretation contracts from superficial caller representation such
as dict construction order. Normalization preserves semantics-bearing values;
semantics-bearing options participate in the executable fingerprint.

## Outcomes

Submit and reconciliation distinguish three cases:

- `observed(Observation)`: an authoritative terminal remote outcome is known;
- `in_progress(Detail)`: the provider positively knows the original attempt is
  still running, so the existing dispatching attempt remains authoritative;
- `indeterminate(Reason)`: the provider cannot safely determine the remote
  outcome.

Known progress is not collapsed into uncertainty, and neither case is permission
to create another submit.

## Submit

Submit runs only after the attempt is durably `dispatching`.

```prolog
rlm_effect_executor:effect_adapter_submit(my_provider, Attempt, Request,
                                          observed(Observation)) :-
    provider_submit(Request,
                    _{idempotency_key:Attempt.idempotency_key},
                    Response),
    Observation = observation{
        status:succeeded,
        value:Response,
        usage:usage{units:1},
        provenance:my_provider
    }.
```

A provider that cannot determine the remote result returns:

```prolog
indeterminate(provider_outcome_unknown)
```

A normal exception raised by adapter code after dispatch is also treated
conservatively as indeterminate. A transport exception is not evidence that the
remote service did nothing.

## Reconciliation

Providers with an idempotency lookup, operation lookup, or equivalent remote
query implement `effect_adapter_reconcile/4`:

```prolog
rlm_effect_executor:effect_adapter_reconcile(my_provider, Attempt, Request,
                                             Outcome) :-
    provider_lookup(Attempt.idempotency_key, Request, Remote),
    remote_observation(Remote, Outcome).
```

If the provider confirms the original job is still running, return for example:

```prolog
in_progress(remote_job(JobId))
```

If no reconciliation hook exists, an unresolved dispatched attempt remains
indeterminate. The executor does not silently resubmit.

Reconciliation first checks the adapter against the trusted identity persisted
with the attempt. A mismatch returns `adapter_identity_mismatch` without
invoking any provider callback. If an authoritative local observation already
exists, it is returned directly and no remote reconciliation hook is called.

## Cancellation

A provider may implement `effect_adapter_cancel/4`. Confirmed remote
cancellation should return `observed(Observation)` with status `cancelled`.
Unknown cancellation returns `indeterminate(Reason)`.

Caller/Future cancellation is never interpreted as proof that the remote effect
did not happen.

## Authority composition

The effect executor consumes an already trusted authority reference. Code that
uses #53 should build the exact authority operation with
`rlm_effect_authority:effect_authority_operation/4` or
`effect_authorize/6` before admission.

An explicit retry/resample has a different attempt identity and therefore a new
authority fingerprint. A changed normalized request has a new executable
fingerprint. `allow_once` cannot silently carry across either boundary.
Changing the adapter also changes the executable and authority fingerprints,
call ID, attempt ID, and provider idempotency key.

If an `approve_diff` proposal is edited, the edit validator must normalize the
edited request again, obtain the new #57 ticket/fingerprint, and construct the
new trusted continuation from that ticket. Do not execute an edited payload with
the old attempt ticket.

## Sync and async

Applications should call either:

```prolog
effect_execute_async(Adapter, Kind, Request, Options, Authority, Future).
```

or the synchronous facade:

```prolog
effect_execute(Adapter, Kind, Request, Options, Authority, Outcome).
```

The sync facade starts the same canonical async execution and awaits its Future.
Do not build another synchronous business-logic implementation around an
adapter.

When authority must bind an already prepared ticket, use the trusted prepared
execution ABI instead of preparing again:

```prolog
effect_execute_prepared(Adapter, Ticket, Authority, Outcome).
```

It acquires the same #57 effect-store execution lease and validates, admits,
dispatches, observes, cancels, and preserves uncertainty through the canonical
executor path. It never substitutes a freshly prepared ticket for the ticket
that was authorized.

## Fresh reads

The effect runtime is not indiscriminate memoization. Pure logical predicates do
not need this boundary, and freshness-sensitive reads may explicitly resample
or use a read policy appropriate to their semantics. Use durable effect identity
for work whose accidental repetition matters.

## Canonical tool adapter

Effectful `rlm_tool` execution no longer jumps from #53 authority directly to
`perform_tool_effect`. The canonical path is:

```text
normalize executable operation (schema + preflight)
-> capability / hard-policy / confinement
-> rlm_effect_executor:effect_prepare(rlm_tool, tool, Request, Options, execute(Ticket A))
-> #53 authority fingerprints Ticket A
-> authorized continuation carries the ground Ticket A
-> rlm_effect_executor:effect_execute_prepared(rlm_tool, Ticket A, Authority, Outcome)
-> validate/admit Ticket A under the #57 execution lease
-> durable dispatch of Ticket A
-> effect_adapter_submit(rlm_tool, Attempt, Request, Outcome)
-> perform_tool_effect (the trusted tool handler boundary)
-> authoritative observation OR conservative uncertainty
```

There is no second preparation after authority. If the store namespace,
execution epoch, call identity, fingerprint, attempt identity, mode, or parent
lineage represented by Ticket A is stale at execution time, admission fails
closed. Authority over Ticket A is never permission to prepare and execute a
replacement Ticket B.

Read tools (`effect:read`) retain the direct fresh-read path; they are not
memoized through the effect ledger merely because the ledger exists. Imported
effectful MCP tools inherit the same canonical tool path when they declare a
non-read effect.

The tool adapter is the static code-owned multifile hook
`rlm_effect_executor:effect_adapter_submit(rlm_tool, ...)`. Adapter identity
`rlm_tool` identifies that generic boundary, not the concrete trusted tool
implementation behind it.

For effectful tools, #57 executable semantics additionally contain a stable
code-owned tool-executor digest derived from the trusted preflight and handler
predicate entrypoints, together with the trusted effect class and effective
execution limits. The digest is non-callable, contains no secrets, memory
addresses, or runtime object IDs, and changes when the trusted execution binding
materially changes. Semantics-bearing configuration hidden in a closure must be
surfaced by trusted preflight into the normalized request/details rather than
encoded as an ephemeral runtime handle.

This stable tool-executor identity is deliberately distinct from:

- the model-facing tool name and normalized arguments;
- adapter identity `rlm_tool`;
- the ephemeral `registry_N` live-registry allocation;
- observational effect metadata.

The ephemeral registry identity remains metadata only so the adapter can locate
the live callable at dispatch time. It does not participate in durable
executable identity, and the callable itself is never serialized into the
ledger or exposed to the model.

Editing a pending effectful tool proposal normalizes and preflights the edited
payload, prepares a new ticket, composes a new #53 authority operation, and
builds a continuation carrying that new ticket. The old ticket is not retained
as an executable fallback.

The continuation that runs after `approve_diff` approval calls the trusted
`effect_execute_prepared/4` ABI directly. It never nests a Future wait inside an
already-scheduled async worker, preserving the #54 single canonical execution
direction.

If no effect store is open, an effectful tool fails closed with
`effect_store_required` rather than bypassing #57. Other #57 preparation
failures retain their own structured cause instead of being mislabeled as a
missing store. The legacy pre-v2 store fence remains fail-closed; effectful tool
execution cannot bypass it.
