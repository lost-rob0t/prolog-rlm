# prolog-rlm research

This directory stores durable numbered architecture/research records. The structure is inspired by the useful research-record discipline in `starintel-auto-research`, but this repository is independent and uses its own naming and conclusions.

Each record should contain:

- stable ID and title;
- explicit research question;
- primary sources and retrieval dates;
- findings separated from inference;
- implementation implications;
- rejected/avoided alternatives;
- open questions;
- acceptance experiments or tests.

## Approval metadata

Every tracked `research/*.org` record, including records migrated from older
layouts, must place exactly this block immediately after its `#+title` and
lifecycle `#+status` keywords:

```org
#+approval_schema: prolog-rlm.research-approval.v1
#+approval_state: PENDING
#+approval_actor: NONE
#+approval_evidence: NONE
#+approval_base_commit: NONE
#+approval_base_blob: NONE
#+approval_decided_at: NONE
```

`#+approval_state` is the only machine-readable approval state. Its values are
exactly `PENDING`, `APPROVED`, and `REJECTED`. A pending record must use `NONE`
for every other approval field. A decided record must name a human actor and
durable evidence, identify the exact reviewed commit and file blob with 40-hex
object IDs, use an RFC 3339 timestamp, and satisfy:

```sh
git rev-parse --verify BASE_COMMIT:research/RECORD.org
```

The result must equal `approval_base_blob`. Lifecycle `#+status` remains a
separate field; `RESEARCHING`, `RESEARCHED`, `VERIFIED`, `DONE`, and
`accepted-for-realization` do not approve a record. Prose, design references,
Auto-RAGE decisions, and checkboxes are not approval evidence.

Use [`../docs/research-record-template.org`](../docs/research-record-template.org)
for new records. Validate the current checkout with:

```sh
make research-approval
```

The repository-owned validator enumerates tracked files through Git, reports
filename/line/reason diagnostics, rejects legacy approval layouts and checked
approval boxes, checks state-dependent values and commit/blob bindings, and
reports duplicate filename research IDs and `:ID:` values. It has no dependency
on personal Emacs or dotfiles configuration.

## Migration audit

The tracked records were migrated without inferring approval:

| Historical layout | Classification | Migration |
| --- | --- | --- |
| `#+STATUS: accepted-for-realization` in `RLM-RESEARCH-026` | lifecycle status, not approval | retain the value as lowercase `#+status`; approval remains `PENDING` |
| `RESEARCHING`, `RESEARCHED`, `VERIFIED`, and `DONE` statuses | lifecycle status, not approval | retain as lifecycle values; approval remains independent and `PENDING` |
| legacy `#+approval`, `#+approved`, `#+approval_status`, approval properties, or checked `APPROVE`/`REJECT` boxes | noncanonical approval layout | none were present in the tracked records on the migration base; the validator rejects them if introduced |
| approved-for-design prose, design references, `Decision: GO`, Auto-RAGE decisions, or other model-authored prose | non-authoritative evidence | preserve prose; never translate it into approval metadata |

Six UI records had no lifecycle status header; they received `#+status:
RESEARCHED` as a neutral lifecycle migration, not an approval decision. All
migrated records retain independent `PENDING` approval values unless a later
human approval is recorded through the canonical schema.

The cross-branch audit found two distinct records reusing numeric identity 010:

- `origin/main`: `RLM-RESEARCH-010-symbolic-prompt-compiler.org`;
- PR #58 branch `agent/rrlm-control-plane-research`: `RLM-RESEARCH-010-logic-native-control-plane.org`.

Neither history is rewritten. They must not be merged together as-is. The
smallest history-preserving resolution is to retain the established main record
as 010, move the control-plane record to a newly assigned unused ID in a
separate reconciliation commit, and require a fresh approval because the path
and reviewed blob changed. The PR #58 approval remains scoped to its original
path and does not authorize that rename.

Issue #219 is a separate human-gated E1 design decision. Its design comment is
not approval for PR #58, this record, implementation, or merge.

## Index

- `RLM-RESEARCH-000-foundations.org` — original RLM model and core invariants.
- `RLM-RESEARCH-001-prolog-runtime-design.org` — mapping RLM execution onto Prolog.
- `RLM-RESEARCH-002-agentic-harness.org` — RLM + harness + ReAct/CodeAct architecture boundary.
- `RLM-RESEARCH-003-typed-symbolic-execution.org` — lambda-RLM and bounded executable plan language.
- `RLM-RESEARCH-004-prologmcp-repair-loop.org` — structured Prolog execution, diagnostics, trace and repair.
- `RLM-RESEARCH-005-swi-agent-runtime.org` — engines, queues, bounded workers and supervision.
- `RLM-RESEARCH-006-mcp-dual-version-runtime.org` — compatibility architecture for MCP `2025-11-25` and `2026-07-28`.
- `RLM-RESEARCH-007-langchain-langgraph-port.org` — minimum useful Prolog-native chain/graph semantics.
- `RLM-RESEARCH-008-adaptive-recursion.org` — depth/cost evidence and adaptive recursion policy.
- `RLM-RESEARCH-009-durable-artifact-context.org` — fresh reasoning roots, blackboards and durable task state.
- `RLM-RESEARCH-010-symbolic-prompt-compiler.org` — progressive disclosure, symbolic capability routing, dependency closure, bounded context compilation, and explainable selection.
- `RLM-RESEARCH-011-managed-context-tool-discovery.org` — managed rolling-context integration, one shared token solver, contextual activation/deactivation, bounded model discovery, MCP metadata, and child-agent scope narrowing.
- `RLM-RESEARCH-020-prolog-agent-ui-contract.org` — OpenCode black-box functionality, layout, frontend protocol and cross-client UI semantics.
- `RLM-RESEARCH-021-javascript-ui.org` — TypeScript/OpenTUI/Solid reference TUI and Ink comparison.
- `RLM-RESEARCH-022-common-lisp-ui.org` — Common Lisp standalone TUI research, preferring Tuition with Old Norse as a lower-level alternative.
- `RLM-RESEARCH-023-nim-ui.org` — Nim UI research comparing pure-Nim Illwill with OpenTUI C-ABI bindings.
- `RLM-RESEARCH-024-emacs-ui.org` — full Emacs chat/coding UI, asynchronous process transport, optional Sweep bindings and native diff/editor integration.
- `RLM-RESEARCH-025-lem-ui.org` — Lem editor UI and a reusable Common Lisp PrologAgent client shared with the standalone CL frontend.
- `RLM-RESEARCH-026-task-deadlines.org` — deadline propagation and bounded task timing semantics.
- `RLM-RESEARCH-027-lambda-rlm-realization.org` — deep ARARD for a first-class proof-carrying λ-RLM strategy on the prolog-rlm v1 runtime.

The gaps are deliberate. New records must not reuse an ID already present in an open branch or PR merely because it is absent from canonical `main`.

## Rule

Research records are evidence, not executable specifications. Promote conclusions into README/TODO/code only when the record states a bounded implementation implication and an acceptance test.
