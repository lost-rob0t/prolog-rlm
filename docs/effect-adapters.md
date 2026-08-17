# Effect adapter integration

`rlm_effect_executor` is the reusable execution boundary for effectful provider
and tool libraries. Provider-specific code translates a normalized runtime
request to the remote protocol; it does not own a second generic effect ledger.

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

## Fresh reads

The effect runtime is not indiscriminate memoization. Pure logical predicates do
not need this boundary, and freshness-sensitive reads may explicitly resample
or use a read policy appropriate to their semantics. Use durable effect identity
for work whose accidental repetition matters.
