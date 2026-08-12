# Research records

This directory is the durable research notebook for `prolog-rlm`.

The workflow is adapted from the useful parts of `starintel-auto-research`: research is kept as numbered, source-backed records with explicit questions, findings, implementation consequences, and unresolved work. This repository does **not** inherit StarIntel-specific architecture, names, approval fields, or runtime dependencies.

## Naming

Use:

```text
RLM-RESEARCH-NNN-short-topic.org
```

Numbers are stable. Do not renumber old records when priorities change.

## Required sections

Each research record should contain:

- Org properties with a stable `ID`;
- title, description, status, and file tags;
- research question;
- sources with retrieval dates;
- findings separated from speculation;
- Prolog/RLM implementation mapping;
- alternatives or rejected approaches where relevant;
- open questions;
- acceptance evidence or experiments needed to settle the question;
- citations/footnotes.

Suggested status values:

```text
TODO RESEARCHING REVIEW BLOCKED | DONE REJECTED
```

## Rules

1. Prefer primary sources: papers, official repositories, official documentation, and source code.
2. Record retrieval dates because RLM/LangChain/LangGraph implementations are changing quickly.
3. Do not turn a research claim into architecture merely because it sounds plausible.
4. Preserve negative results and rejected approaches.
5. Keep implementation TODOs in `TODO.md`; use research files for evidence and design reasoning.
6. When a research record materially changes architecture, link the resulting code/design decision back to the record.

## Current records

- `RLM-RESEARCH-000-foundations.org` — what an RLM is and which properties the Prolog implementation must preserve.
- `RLM-RESEARCH-001-prolog-runtime-design.org` — initial mapping from the Python-REPL formulation to a Prolog execution environment.
