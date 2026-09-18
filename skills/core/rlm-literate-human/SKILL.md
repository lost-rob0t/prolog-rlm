---
name: rlm-literate-human
description: Write, review, and publish canonical Org source in a human technical voice, then tangle it into generated runtime files.
---
# rlm-literate-human

Use this skill whenever code or executable configuration is added or materially rewritten in the self-hosting Prolog-RLM / Infermacs language program.

## Canonical source

The human-readable Org file is the source of truth.

Generated `.pl`, `.el`, `.kt`, `.js`, shell, configuration, or other implementation files are tangler outputs. Do not hand-edit a generated file. Change its Org source block and regenerate it.

Every executable source block that belongs in the build has an explicit `:tangle relative/path`. Documentation-only examples either omit `:tangle` or use `:tangle no`.

Keep prose and implementation adjacent. A reader should be able to understand why a block exists before reading the block.

## Writing style: Literate Engineering Voice

Write like one engineer explaining a real system to another engineer.

- Lead with the concrete problem or invariant.
- Prefer active voice.
- Use strong verbs and specific nouns.
- Give one sentence one main idea.
- Use the shortest accurate term consistently.
- Explain surprising constraints, boundaries, failure modes, and tradeoffs.
- Put rationale next to the code it justifies.
- Show real inputs and outputs instead of abstract filler.
- Assume the reader understands programming; explain this system, not Programming 101.
- Remove throat-clearing, generic conclusions, fake enthusiasm, marketing language, and phrases such as “robust”, “seamless”, “powerful”, or “leverages” unless a measurable fact requires them.
- Never describe behavior the code or tests do not prove.

Public predicates, exported language forms, actor messages, effects, capabilities, profile fields, compiler forms, and generated artifacts need human documentation.

Comments explain intent or non-obvious constraints. They do not narrate obvious syntax.

## Review pipeline

Canonicalization is deliberately adversarial.

### Pass 1 — author

The author tangles the Org source and runs focused tests.

The author records:
- source Org path;
- generated targets;
- exact tests;
- any intentionally undocumented private implementation detail and why it is private.

### Pass 2 — parent critic

A different parent/supervisor reviews the Org and generated diff. It must check:
- prose/code agreement;
- missing invariants;
- misleading names;
- accidental authority widening;
- needless abstraction;
- undocumented public behavior;
- stale or hand-edited generated outputs;
- tests that execute lines without proving behavior.

A parent critic cannot approve its own authored source.

### Pass 3 — harsh nihilist

The final reviewer assumes every abstraction, sentence, generated layer, and dependency is unnecessary until justified.

It tries to delete the design mentally before accepting it.

It rejects when:
- prose can be removed without losing meaning;
- code exists without a concrete requirement;
- two concepts can be one;
- one concept secretly owns two authorities;
- the Org source hides behavior in generated files;
- a generated target cannot be reproduced exactly;
- an LLM-authored statement is treated as fact without evidence;
- tests do not exercise the documented failure path;
- a simpler Prolog rule, fact, actor message, or existing runtime primitive would do;
- the chapter would teach something the source does not actually implement.

The only terminal votes are:

`ACCEPT_ORG_SOURCE` — the Org file may become canonical.

`REJECT_ORG_SOURCE(<specific reasons>)` — return it to the author and repeat parent + nihilist review after the fix.

No majority vote overrides a nihilist rejection. Fix the source.

## Book handoff

Only after `ACCEPT_ORG_SOURCE` and complete required test coverage should the Zara Book worker consume the file.

The book worker turns each accepted canonical Org unit into a fuller teaching chapter that:
- starts from the problem the file solves;
- teaches the Prolog/language concepts through the implementation;
- preserves the file's real invariants and failure modes;
- walks through important source blocks in dependency order;
- includes runnable examples;
- links the chapter back to the canonical Org source and generated artifacts;
- never claims planned behavior as implemented.

The chapter is downstream documentation. It never becomes the implementation authority.

## Commands

Tangle:

`swipl -q -s scripts/tangle-org-source.pl -- literate/<file>.org .`

Verify generated files are current:

`swipl -q -s scripts/tangle-org-source.pl -- --check literate/<file>.org .`

A stale or missing generated target is a failed build.
