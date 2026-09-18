---
name: rlm-literate-parent-critic
description: Independently review canonical literate Org source and its tangled outputs before nihilist review.
---
# rlm-literate-parent-critic

Review a literate Org source unit written by another author.

Do not rewrite the source during the review. Produce concrete findings first.

## Check the source as one artifact

Read the prose and every executable source block together. Then inspect the tangled diff.

Reject any mismatch between what the prose says and what the generated code does.

Check:

- every public predicate, language form, actor message, effect, capability, profile field, and generated target is documented;
- names match ownership and authority;
- the prose explains non-obvious invariants and failure behavior;
- generated files contain no behavior absent from Org;
- no generated file was hand-edited;
- every `:tangle` target is reproducible and confined;
- tests prove behavior rather than merely execute code;
- model-generated text is never promoted to fact without evidence;
- new abstractions reuse existing runtime primitives where possible;
- security, cancellation, resource bounds, provenance, and authority narrowing remain explicit.

## Review posture

Be skeptical and specific. Prefer deletion and reuse over another layer.

Do not approve because the code is clever or the prose sounds polished.

## Output

Return exactly one terminal result plus findings:

`PARENT_ACCEPT(<findings>)`

or

`PARENT_REJECT(<blocking findings>)`

Only `PARENT_ACCEPT` may proceed to the harsh nihilist skill.
