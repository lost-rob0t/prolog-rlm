# Generic configuration-space evolution kernel

Issue: #142

## Decision

**GO** for a small, domain-neutral configuration-space evolution library. The pure candidate kernel is stable, and latency-bearing evaluation now composes with the existing bounded Future runtime. **HOLD** model-weight/parameter-space ES. **REJECT** DeepSeek Harness, Cordis, coding-agent, frontend, or product genotype types in core.

The library remains provider-free. It gives downstream callers a stable typed candidate, lineage, fitness, deterministic selection, and trusted evaluator contract without creating another scheduler, authority system, effect ledger, verifier, or executable generated-code path.

## Boundary

Core owns generic data and deterministic transforms:

- closed candidate validation against a trusted immutable constraint envelope;
- registered, code-owned mutation and crossover operators;
- deterministic candidate fingerprints;
- lineage/provenance records;
- vector fitness records;
- deterministic Pareto/non-dominated selection with an explicit tie policy.

Core also owns the bounded evaluator bridge: trusted code registers an evaluator
behind an atom ID, validated closed candidate/context data selects only that ID,
and evaluation runs through `rlm_async`.

Downstream callers own their product schema and benchmark composition. A downstream genotype may reference prompt, skill, model-policy, tool-policy, loop, verifier, context, topology, or budget profiles, but core treats those as validated data. Generated candidate data is never passed to unrestricted `call/1`.

## Candidate and constraint contract

The initial public representation is a dict:

```prolog
candidate{id:Id, genes:Genes}
```

`Genes` is a dict whose keys and allowed values are constrained by a trusted host envelope:

```prolog
constraints{
  schema:_{prompt:[p1,p2], loop:[direct,delegate]},
  immutable:_{verifier:required},
  ceilings:_{budget:100}
}
```

The first pure kernel validates only the closed `schema` vocabulary and rejects unknown genes or values. Immutable runtime constraints and ceilings are carried in the trusted constraint envelope and are not candidate dimensions. Runtime integration must continue to enforce Frozen Spec, verifier requirements, authority/capability ceilings, cancellation, effect identity, confinement, and budgets independently of evolutionary data.

## Operators

Mutation/crossover accepts only registered code-owned operator IDs. The initial operators are intentionally small and deterministic:

- `set(Key, Value)` mutates one allowed gene after validation;
- `take(Key, left|right)` constructs a crossover candidate by selecting the named gene from one validated parent.

No model/KB-generated callable is executed. Future operator registration must preserve this closed-dispatch invariant.

## Fitness and selection

Fitness is a dict of objective values plus explicit direction metadata supplied by trusted selection policy. The initial selector computes non-dominated candidates over a fixed objective list such as:

```prolog
[objective(correctness,max), objective(cost,min)]
```

It preserves the full vector instead of collapsing correctness, verification, cost, latency, and robustness into one magic scalar. Ties are resolved deterministically by candidate fingerprint/id order. Promotion remains separate from evaluation/selection.

## Lineage and evidence

Every transform returns lineage data containing parent IDs, operator ID, and resulting candidate fingerprint. Evaluator results retain the trusted evaluator ID, canonical candidate ID, objective vector, evidence, and usage. Benchmark identity and persistent trace/evidence references remain caller-owned inputs to later fitness/lifecycle records.

## Evaluator integration

`evolution_evaluate_async/5` validates and canonicalizes the candidate,
constraints, and context before scheduler admission. It resolves only a trusted
`evolution_evaluator_register/2` registration, submits one operation to
`rlm_async`, and records candidate/evaluator correlation in Future metadata.
Evaluator output must be closed `evaluation{candidate,objectives,evidence,usage}`
data for the same candidate. Cyclic, non-ground, malformed, or mismatched output
fails closed. Ordinary evaluator exceptions become ground structured failures;
cancellation and other control exceptions retain the canonical Future semantics.

`evolution_evaluate/5` is the synchronous facade over that exact Future and
destroys it with cleanup protection. Effectful evaluator internals must still
cross the existing authority/effect boundaries. Subagent results may be one
evaluator input, not a new evolution scheduler.

## Remaining work

Persistence, benchmark composition, promotion/rollback, and skill-experiment
orchestration remain separate follow-up layers. Model-weight evolution remains
outside this library.
