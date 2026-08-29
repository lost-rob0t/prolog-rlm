# WORK ORDER — close the #290 adversarial-review findings

Input: `rage/290-adversarial-review-report.md` (verdict NEEDS-CHANGES, head
`5bb2817`, branch `docs/spec-seeded-symbolic-plans`). Execute every finding
below in order. This is still the DESIGN slice: no production runtime
implementation beyond what the findings require. TDD throughout — each new
gate check is written first, confirmed to fail against the current state,
then made to pass. AGENTS.md governs.

## 0. Baseline (before touching anything)

- `swipl -q -s scripts/design_gate.pl` → expect 46 checks green.
- `test/check_runtime.pl`, `test/load_all.pl`, `test/run_tests.pl`
  (1061/1061), `benchmark/run.pl -- deterministic`, `bin/prolog-rlm.pl -- demo --json`.
- Record the two known-red items: `live_conversation_scale_openrouter_test`
  (m6) and B1's unresolvable BASE ref in CI.

## 1. B1 — make the BASE ref resolvable in canonical CI (BLOCKER, first)

- `extract_unmerged_base/1` must resolve the BASE through an explicit
  candidate list in order: pinned object id, `refs/heads/<branch>`,
  `refs/remotes/origin/<branch>`, `refs/remotes/github/<branch>`; fail with
  the resolved candidate list in the fault message.
- Pin the current BASE commit id as a constant next to the resolver and cite
  it in the design record §6.2 (BASE = branch @ <id>).
- ci.yml: before the gate step, `git fetch origin
  rage/288-spec-plan-graph-executor` (non-fatal if the remote branch
  appears later; the pinned id remains the authority).
- NEW gate check `base_ref_resolvable`: resolves and asserts the pinned id
  (test written first: it must fail while the resolver still uses the bare
  ref).

## 2. M1 — replace vacuous capability-safety checks

- NEW `metadata_capability_rejected`: build a registry whose provider
  metadata attempts a `capability` field; assert merged
  `rlm_assertion:normalize_metadata/2` rejects it. This, not a static-fact
  comparison, is the evidence for "SPEC compilation grants nothing".
- Rewrite `capability_unchanged` to derive both sides from an actual API
  surface (e.g., assertion-registry catalog → required observation
  capabilities side table → environment set) or delete it and fold into the
  new check.
- NEW `host_observation_refusal`: drive the real collector/observer ABI with
  the required capability absent from the environment and assert the
  observation is conservative-indeterminate through the actual refusal path —
  never by pre-setting `status:indeterminate(policy_denied)` in the payload.
- Update `dec_spec_grants_nothing` evidence refs to the new check ids.

## 3. M2 — make obligation coverage ungameable

- `obligation_causal_link`: an establishing step satisfies an obligation only
  if it is transitively required by (or otherwise causally connected to) a
  `validate/1` step of the bound spec in the dependency graph.
- For `plan_established` kinds whose evidence contract is code-change
  (tdd_evidence), restrict establishing ops to `edit|create` (doc §9).
- `patch_full_chain`: after `d6_apply_patch/3`, re-run parse + graph
  validation + compat (incl. dangling-input re-check) on the patched graph —
  the gate currently runs compat only.
- Add the report's mutation graph as a permanent negative check.

## 4. M3 — one dangling grammar that includes environment inputs

- `d6_resolvable/5` becomes `d6_resolvable/6` (or equivalent): `input(Name)`
  resolves from environment inputs FIRST, then dependency-closure binds —
  exactly doc D6-1 and §11 item 5. Thread `Environment.inputs` through
  `d6_check_closure`, `d6_compat_dangling`, and the round trip.
- Fix `d6_compat_spec_inputs` inversion: a required SPEC input missing from
  `Environment.inputs` is a fault regardless of any step reference (the
  expr-reference escape hatch is removed; §11 item 7 is the rule).
- NEW `spec_input_env_dataflow`: positive round trip — a step consuming
  `expr(input(<spec_input>))` validates when present in environment inputs,
  faults `missing_spec_input` when absent, independent of step references.

## 5. M4 — fix the IMPLEMENTED/UNMERGED classification

- Doc §2.1: move `model_step_handler` + native charge-back to §2.2
  (adoption via S10); fix the self-contradiction at §8.2's "merged native
  model_step_handler" sentence.
- Note the branch's `capability_shape(spec/1)`/`plan/1` additions in §2.2.
- Gate header wording: the "IMPLEMENTED layer" loads this checkout's
  modules; state explicitly that branch-only features are validated as
  UNMERGED-adoption surface, not merged main.

## 6. M5 — remove the undefined `project(read)` shape

- Doc §4.2: replace `project(read)` with capability shapes that exist in the
  closed merged model (`filesystem(observation)` for registry reads; declare
  a future index-observation capability as a NEW DESIGN TARGET if needed).
- Complete `observer_required_capabilities/2` for ALL observer kinds or
  document the deliberate omissions; align doc §4.2 rows with the side
  table.

## 7. M6 — `inner_capabilities` must exist in the schema it is used by

- §8.1 `expert_contract{}` gains `inner_capabilities:[capability]`
  (⊆ environment grants, checked at preflight; distinct from the op's own
  required capability).
- `expert_contract_ok/2` validates it, plus `model_policy{provider,
  max_iterations > 0}`, `budget_policy`, `completion`/`failure` condition
  values (closed atoms), per report item 7.
- Doc D6-8 and §8.2 wording updated to reference the same field name.

## 8. M7 — KB evidence must resolve

- Fix the four dangling refs in `research/spec-plan-refinement-kb-state.pl`:
  `gate:d6_dataflow_ok` → `gate:d6_dataflow_round_trip`; `gate:http_schema_ok`
  and `gate:http_malformed_rejected` → the actual `spec_compile_http_ok` /
  `http_reject_*` ids; `gate:design_gate_passes` → an id the gate defines
  (or the KB-consistency check id).
- NEW gate check `kb_evidence_refs_resolve`: every `gate:<Id>` ref names a
  check id the gate defines; every `design:<anchor>` ref names an existing
  document anchor (parse anchors from the doc's headings).
- For `dec_forward_projection` (d12) and `dec_multi_run_state` (d06): add
  design-level checks that exercise the data model (snapshot
  `covers:[event_lo,event_hi]` + boundary summary id range; mode table
  re-projection obligations) and cite them — or downgrade both decisions to
  `candidate`. Do not leave them validated on self-authored refs. Fix the
  d06 anchor (`#s7-3-...` for §7.3, not `#s8-...`).

## 9. M8 — declare the two undeclared BASE deltas

- D6-9: diff sides gain `revision(revision_ref)` (BASE sides are
  `path|ref|span` only, 288:744–754).
- D6-10: `symbol_kind` is enforced as the closed 13-atom set at
  reconciliation (BASE `json_symbol_ref/2` accepts any non-empty atom kind,
  288:447–449).
- NEW checks `symbol_kind_closed` and `diff_revision_side` (accept/reject).

## 10. Minors

- m1: doc §14 — real check/group counts (recount after this work).
- m2: delete `require_ok/2` and `environment_allows/3` allowed-branch, or
  use them; either call `d6_args_shape_resolved/2` inside the round trip on
  the resolved args (preferred — upgrade the equality-only check) or delete
  it and fix the comment.
- m3: `docs/typed-plans.md` — `rlm/3` → `rlm/2`; replace the phantom
  `strategy_select/3` reference with `strategy_mode/2` (§7.1); align with
  `rlm_spec_strategy`'s actual mode atoms (`direct|typed_plan`).
- m4: `path_template_name/2` must accept paths containing embedded
  templates (e.g. `/users/{id}`), not only whole-template paths; add a
  positive http contract example with a path param.
- m5: one reconciling sentence in §4.2 for the observer side table.
- m6 (branch runtime, NOT a doc issue): diagnose
  `live_conversation_scale_openrouter_test` failing 3/3 with
  `z-ai/glm-5.3-flash` (HTTP 200 both rounds; retrieval/acceptance
  assertion mismatch). Use the debug-io skill to pull the per-generation
  payloads; fix the runtime or the test honestly. Do NOT skip, xfail, or
  weaken it. Note: the correct OPENROUTER_TEST_MODEL value is
  `z-ai/glm-5.3-flash` (no `openrouter/` prefix).

## 11. Closing the slice

- Re-run: gate (all checks incl. the new ones), deterministic suites,
  benchmark, demo, live lane. Update §14 counts/anchors; refresh KB evidence
  refs to the final check ids; `git diff --check`.
- Reconcile the review report: append a "resolution" column or a follow-up
  section mapping each finding id to the closing commit.
- Commit in coherent slices (gate checks; doc/KB; ci.yml; live-lane fix),
  push to `github/docs/spec-seeded-symbolic-plans`. Do NOT merge.
