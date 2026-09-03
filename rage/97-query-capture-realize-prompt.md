# WORK ORDER — #97 Realize phase (ADADR RAGE slice, fresh worker)

Consumed issue: lost-rob0t/prolog-rlm#97. Epic: #93. Branch:
`rage/97-query-capture-apis` (worktree `~/git/worktrees/prolog-rlm-issue-97`,
reuse-if-exists — verify branch, fetch from the `github` remote
(`origin`/Forgejo SSH times out), fast-forward only).

Mode is **ADADR**. Research **and** design are already approved and bound:

- Research record: `research/tree-sitter-query-capture.org`
  (`RLM-RESEARCH-012`, `APPROVED`, base commit
  `4ab728553c65b574c440066f02aadbf9e9893225`, blob
  `1974058b0ad9b1ed0d1596a09810e5f2523eb837`).
- Design: `rage/97-query-capture-apis.org` §Design phase (`APPROVED`,
  decided `2026-09-02T20:35:55Z`).
- Durable evidence on the issue:
  <https://github.com/lost-rob0t/prolog-rlm/issues/97#issuecomment-5515955977>.

Implementation is authorized **within the approved design only**. If
implementation evidence contradicts the design, stop, record the
contradiction in the run log, and restart the canonical ADADR loop as a new
iteration — do not code around it. Research approval validator gate:
`make research-approval` must stay PASS (do not weaken record fields).

## 0. Start evidence (before any implementation)

1. Reuse the worktree `~/git/worktrees/prolog-rlm-issue-97` on
   `rage/97-query-capture-apis`. Confirm branch and read the run log
   (`rage/97-query-capture-apis.org`) — it already contains run identity
   (immutable start SHA `156bfe9b2caffa1b967e77bee51263ee9e85fb50`),
   baseline, Prolog verification evidence, operator inputs, and the approved
   design. Append your phases; never rewrite history there.
2. Verify gates at your candidate head: `make research-approval`, full
   baseline (`test/check_runtime.pl`, `test/load_all.pl`,
   `test/run_tests.pl` — expect 96+ suites / 1179+ tests / 0 failed),
   `benchmark/run.pl -- deterministic`, `bin/prolog-rlm.pl -- demo --json`,
   `git diff --check`.

## 1. Realize exactly this design (summary; full text in the run log)

- C: new `c/rlm_tree_sitter_query.c` + `internal.h` + registration —
  query blob (retains `rlm_ts_language_resource`, immutable, cross-thread
  use, idempotent close) and thread-affine cursor blob. **v0.20.8 API only**
  (verified list in the run log Analyze section; the 5 newer functions are
  forbidden unguarded). `PL_handle_signals()` between cursor steps.
  Compile errors: `TSQueryError` kind + byte offset; Prolog derives
  row/column from the query source.
- `prolog/rlm_tree_sitter.pl` additions: `ts_query_compile/3` (Source
  strictly atom/string — callable ⇒ data-type error), metadata
  (`ts_query_capture_name/3`, `_quantifier/4`, `ts_query_predicates/3`,
  counts), `ts_query_cursor_*` and `ts_query_next_match/2` /
  `ts_query_next_capture/3` projecting `ts_match(Id, PatternIndex,
  [ts_capture(CaptureId, Node), ...])` (native order/multiplicity
  preserved — repeated capture names stay distinct ordered entries).
- New `prolog/rlm_project_query.pl`: inert `project_query_pack_register/6`
  (strict validation, structured faults, sha256 per source), trusted
  `project_query_pack_activate/4` / `_deactivate/3`, and extraction with
  the canonical async direction (`project_query_extract_execute/6` →
  Future → `_await` facade). Admission → hash validation →
  **generation reuse only when provably the same generation** (latest
  admitted parse is `current` + exact content hash) → else fresh bounded
  `project_source_tree_parse` → predicate-bearing packs rejected
  `unsupported_predicate` → compile (cache keyed
  `(Language, GrammarRef, SHA256)`, max 32 FIFO, process-lifetime) →
  language mismatch = structured failure → bounded cursor run
  (`timeout_seconds` 30.0 default, `max_matches` 10000, `max_captures`
  50000, `byte_range`/`point_range`/`subtree(Node)` same-generation only)
  → parent-walk projection to closed `syntax_node(Parse, Path)` identities
  (no full CST materialization) → atomic publication under lock order
  (source-registry mutex → `rlm_project_query` mutex) → `setup_call_cleanup`
  tree close. New extraction generation on pack replacement; prior facts
  `stale`, never silently current.
- New `prolog/rlm_project_query_persist.pl`: `library(persistency)`
  backend mirroring `rlm_artifact_persist.pl` but `db_attach(File,
  [sync(always)])` (published extractions must survive kill -9); records
  `extraction_record(project, extraction, record)` and
  `match_record(project, extraction, sequence, match)`; KB root is trusted
  host configuration — `<$PROJECT_ROOT>/.kb/project-query/<ProjectId>.pl`;
  unresolvable/read-only root ⇒ structured `project_query_error{kind:
  kb_unwritable}`, never silent memory-only degradation.
- Compiled queries are NOT persisted (deterministic recompile; nothing
  native crosses process boundaries).

## 2. TDD (work-order §5 order — RED first, prove each fails for the
intended reason, then minimum coherent change, rerun to green)

Minimum test surface: compile OK + structured compile error (byte/point,
kind); zero/multiple matches; nested captures; repeated capture names in
one match; match grouping preserved (not a flattened stream); captures
project to #96 node identities with span + generation; wrong-grammar query
= structured failure, no crash; malformed/adversarial query text = no
crash, no Prolog execution; callable query source rejected as data-type
error; subtree/range-bounded execution; Unicode byte/point fixtures;
pack reload ⇒ new extraction generation with provenance; **kill -9 +
fresh-process `.kb` reload fixture** (provenance-complete facts,
deterministic replay) and read-only-root structured failure; three
grammars through one generic API — Python definitions, JavaScript
definitions/calls — no language-specific C code.

Reuse the Prolog verification gates from this run log (API-0.20.8-compat,
provenance completeness, acceptance coverage, query-source safety) as
development-time checks; re-prove at final head.

## 3. Environmental intelligence

- Native builds: `make tree-sitter-ffi` inside `nix develop`; grammar
  bundle via `nix flake check path:. --no-update-lock-file
  --print-build-logs`; `/usr/src/tree-sitter` in
  `scripts/build-tree-sitter-test-grammars.sh` is CI-only provisioning.
- Tree-sitter 0.20.x API compatibility is mandatory (v0.20.8 headers);
  nixpkgs currently 0.26.9 — compile against the intersection.
- Known noise: #329 singleton warnings (`rlm_skill.pl:881`,
  `rlm_prompt_compiler.pl:1941`) — do not absorb.
- Paid OpenRouter lane is stochastic (#343): on red, confirm pinning,
  replicate locally at exact head, re-run. Never weaken a gate.
- Do not absorb #98 semantic normalization or #99 incremental reparsing;
  no predicate evaluator in this slice; no `ts_query_cursor_remove_match`
  unless a test requires it.

## 4. Exact-head verification (minimum)

Full baseline + `benchmark/run.pl -- deep-experiment` + `make
research-approval`; native: `nix flake check path:. --no-update-lock-file
--print-build-logs` including the new query suites and
`test/run_tree_sitter_tests.pl` focused runs; fresh-process kill -9
fixture for the `.kb` journal; all required CI green at the exact PR head
including the pinned paid lane.

## 5. Closing

- One coherent PR from `rage/97-query-capture-apis` to `main`. **Do NOT
  merge** — the operator merges on green.
- Same-PR reconciliation: new `docs/project-query.md` + scope note in
  `docs/project-syntax.md`; `docs/prolog-agent-roadmap.md` if AgentProlog
  readiness changes; issue #97 checklist boxes with evidence; epic #93
  status comment; run-log org finalized (RED/GREEN evidence, adversarial
  results, final verification). GitHub state, roadmap state, and merged
  code must not diverge.
