# Generic configuration-space evolution kernel

Issue: #142

## Decision

**GO** for a small, pure, domain-neutral configuration-space evolution kernel. **HOLD** latency-bearing evaluator/Future integration until the pure data contract is executable and stable. **HOLD** model-weight/parameter-space ES. **REJECT** DeepSeek Harness, Cordis, coding-agent, frontend, or product genotype types in core.

The first slice is deliberately provider-free. It gives downstream callers a stable typed candidate, lineage, fitness, and deterministic selection contract without creating another scheduler, authority system, effect ledger, verifier, or executable generated-code path.

## Boundary

Core owns generic data and deterministic transforms:

- closed candidate validation against a trusted immutable constraint envelope;
- registered, code-owned mutation and crossover operators;
- deterministic candidate fingerprints;
- lineage/provenance records;
- vector fitness records;
- deterministic Pareto/non-dominated selection with an explicit tie policy.

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

Every transform returns lineage data containing parent IDs, operator ID, and resulting candidate fingerprint. Evaluator integration will later attach benchmark identity, trace/result/evidence references, and usage to fitness records through existing RLM Future/outcome contracts.

## Next slice

After this pure kernel is green, add `evolution_evaluate_async` by composing the existing `rlm_async`/Future execution direction. Do not add a second scheduler. Effectful evaluators must cross existing authority/effect boundaries. #144/#147 subagent results may become one evaluator input, not a new evolution scheduler.
