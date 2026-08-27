# Proof-carrying result acceptance

`rlm_result_accept` separates **child completion** from **parent acceptance**. A child can complete successfully and still have its result rejected because evidence is missing/stale/untrusted or because a host-required verifier did not pass.

This is a generic runtime boundary. It is not chain-of-thought storage and it does not execute model-provided predicates.

## Result envelope

The first slice normalizes a closed typed envelope:

```prolog
rrlm_result{
    task:Task,
    status:Status,
    value:Value,
    claims:Claims,
    evidence_refs:ArtifactRefs,
    provenance:Provenance,
    verification:ChildProposedVerification,
    usage:Usage,
    trace_ref:TraceRef
}
```

Claims are explicit:

```prolog
rrlm_claim{
    id:ClaimId,
    value:Value,
    provenance_class:Class,
    evidence_refs:ArtifactRefs
}
```

The envelope is data only. Unknown fields, duplicate claim IDs, malformed artifact refs, unsupported provenance classes and nonground executable-shaped payloads are rejected structurally.

## Acceptance policy

`result_acceptance_policy_normalize/2` and `result_acceptance_policy_narrow/3` reuse the existing `rlm_evidence` policy substrate.

A policy controls:

- the canonical evidence policy (`source_classes`, `trust_classes`, freshness/coherence/state requirements);
- whether each claim must carry evidence;
- whether artifact refs must be current rather than stale;
- host-required verifier names.

Narrowing is monotonic: evidence requirements narrow through `evidence_policy_narrow/3`, booleans can only become stricter, and required verifier sets are unioned. A child cannot waive a parent/host verifier.

## Trusted acceptance context

Acceptance uses:

```prolog
result_accept(Result, Policy, TrustedContext, Outcome).
```

`TrustedContext` contains the host-owned artifact store and verifier results. This separation is intentional. The child envelope's `verification` field is only child-proposed metadata and **never** satisfies a required verifier by itself.

Required verifier results are normalized closed records with distinct terminal states:

- `passed`
- `failed`
- `error(Detail)`
- `timeout(Detail)`

Only trusted-runtime provenance classes are accepted for host verifier records.

## Evidence resolution and proof laundering

Every declared evidence ref is checked through `rlm_artifact`. Missing refs reject. Policies may reject stale refs. Current artifacts are projected into the existing `rlm_evidence` policy checker using their runtime provenance class.

A model-authored artifact therefore cannot satisfy a policy requiring observed/trusted evidence merely because a claim says it is true. Claim-local refs must also be declared by the result envelope, preventing hidden claim evidence from bypassing the result-level evidence gate.

## Security invariants

- Completion is not acceptance.
- A non-completed child result cannot be accepted.
- Child/model data never becomes a verifier callable.
- Child-proposed verification cannot waive or satisfy host-required verification.
- Artifact visibility/provenance does not grant capability or authority.
- Evidence and verifier policies narrow across delegation; they do not widen.
- Verifier failure, error and timeout are never coerced to success.
- No private reasoning transcript is required or persisted.

## Scope of this slice

This slice establishes the reusable typed envelope and deterministic acceptance gate. It does **not** yet wire acceptance as a separate event into every supervised-child trace, nor does it replace the existing Spec/Verify registry or authority/effect machinery. Later #56 slices should compose this API into canonical child supervision and trace/correlation using the existing runtime primitives.
