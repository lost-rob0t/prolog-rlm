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

If no reconciliation hook exists, an unresolved dispatched attempt remains
indeterminate. The executor does not silently resubmit.

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
