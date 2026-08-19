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
- `RLM-RESEARCH-011-managed-context-tool-discovery.org` — integration of the symbolic compiler with managed rolling context, the shared token solver, contextual activation/deactivation, bounded model discovery, MCP metadata, and child-agent scope narrowing.

## Rule

Research records are evidence, not executable specifications. Promote conclusions into README/TODO/code only when the record states a bounded implementation implication and an acceptance test.
