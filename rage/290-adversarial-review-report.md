# ADVERSARIAL REVIEW — SPEC/PLAN architecture rewrite (issue #290 slice)

- Reviewed head: `5bb2817` (branch `docs/spec-seeded-symbolic-plans`), diff base `main` (`7165680`), slice commits `88bca2e` → `2a2f050` → `5bb2817` (diff range `b8c963b..HEAD`).
- Method: full read of the design record, gate, KB, CI/roadmap diffs; module-by-module schema verification against `git show main:...`; BASE fidelity check against `git show rage/288-spec-plan-graph-executor:prolog/rlm_plan_graph.pl`; gate executed and line-by-line audited; mutation experiments in a scratch clone (`/tmp/opencode/review-scratch`, never this worktree); full deterministic suites plus the paid live OpenRouter lane.
- Prior v1 blockers (spec/2 root, dual diff grammars, undefined `change_spec`/`content_ref`/`delete_target`, arity-conflating `signature`, missing dataflow): **verified fixed**. The rewrite adopts the merged `rlm_spec_lang` grammar verbatim, defines ONE diff-side grammar, defines every referenced type, and adds a typed dataflow round trip. That part of the rewrite succeeds.

## Verification evidence (claims that CHECKED OUT)

Ran and passed: `swipl -q -s scripts/design_gate.pl` (all checks green — but see M-count below), `test/check_runtime.pl`, `test/load_all.pl`, `test/run_tests.pl` (1061/1061), `benchmark/run.pl -- deterministic` (16/16), `bin/prolog-rlm.pl -- demo --json`, `git diff --check`. Paid live lane with `OPENROUTER_TEST_MODEL=z-ai/glm-5.3-flash`: 10/11 live tests pass against the real provider (see m7 for the one failure).

Verified against merged code, exactly as cited:

- `rlm_spec_lang` form table (doc §3.1) matches `git show main:prolog/rlm_spec_lang.pl` (spec symbols at lines 66–110, root `spec(Forms)` line 137). No new top-level forms invented.
- `rlm_plan` closed AST `context/3, model/4, rlm/2, tool/3, parallel/2, retry/3, checkpoint/1, final/1` and expressions `input/1, var/1, field/2, literal/1, list/1, object/1` — main:112–133, main:280–288. `plan_validate/4`, `plan_execute/4`, `runtime_budget{steps,model_calls,tool_calls,context_ops,output_bytes}` — main:4–7, main:833.
- `rlm_tool` cited capability shapes `tool/network/filesystem/process/model/mcp` — main:123–135.
- `rlm_spec` `frozen_spec{ref:spec_ref{series,version,fingerprint}}`, `spec_fingerprint/2`, `normalize_frozen_spec/2`, `severity:required` — main:39–126, main:203–226.
- **Closed metadata claim VERIFIED**: `normalize_metadata/2` allows exactly `[verifier,collector,evidence_policy,verify_time_limit,latency,argument_schema,description]` (main `rlm_assertion.pl:149–176`) — no capability field, so the doc §10.3 claim is true, and the gate registry's metadata (including `description`) is schema-legal.
- `canonical_data` retags assertion-arg dicts to `assertion_args` — main `rlm_assertion.pl:244` (doc §11.7 claim true).
- `rlm_evidence`: closed observation keys, trust classes `trusted/observed/model_claim/derived/unresolved`, `indeterminate/1` — main:165–230, 358–362.
- `rlm_verify` `spec_verify/4`, `spec_observe/5`, `spec_observe_async/5`, `spec_observe_execute/5` — main:3–6. `rlm_spec_workflow` prepare→execute→observe→verify→repair→finish, `spec_plan_bind/4`, fingerprint-bound graph id — main:3–142.
- `rlm_authority` tiers `approve_diff < allow_once < allow_session < dangerous`, no `yolo` — main:70–73.
- `rlm_graph_persist` API `graph_persist_open/1, put_checkpoint/3, get_checkpoint/3, close/0` — main:2–5. `rlm_conversation_persist` monotone `next_sequence/2` — main:96–131 (doc §12.2 claim true).
- `rlm_outcome` `plan_outcome/5, plan_repair/6`; `rlm_result_accept`, `rlm_recursion_policy` `direct_continuation`; `rlm_project_source`, `rlm_tree_sitter`, `rlm_conversation_warm` all exist in main.

BASE fidelity vs `rage/288-spec-plan-graph-executor` (lens 2), all EXACT matches:

- Op vocabulary `plan_graph_op/1` (288:63–74) — all 12 ops/arities match doc §6.2 table.
- Capability pairing `plan_capability_required/2` (288:81–84; `delegate/2 → tool(spawn_agent)`) matches.
- Effect classes `op_effect_class/2` (288:90–101) match the doc table row-for-row.
- Desugar target `plan([tool(ToolName, literal(Args), Bind), final(var(Bind))])` (288:1024) matches doc §8.3/§6.2.
- Ready-step semantics, `abandoned` terminal (288:35, 1197), JSON keys `{"id","op","args","bind"}` / `{"step","requires"}`, JSON caps restricted to `tool(Name)` (288:443–458), delegate narrowing (288:756–768) — all as claimed. D6-3's "JSON key `source` unchanged from BASE" is correct (288:340–344 uses key `source` with term `read(path(A))`).
- `plan_graph_execute/5` exists (288:863) as doc §3.3 states.

Gate honesty (lens 3): the layer labeling (gate header, design_gate.pl:13–37) is accurate and the BASE is really loaded from the git object, not a copy, failing loudly (halt 1) when missing — both verified. Every check goal is a self-contained helper, so the clause-level-variable-sharing failure mode is structurally prevented. The TDD checks run through the real `spec_verify/4` pipeline with registry identity binding — genuine.

---

## Findings

### BLOCKER

**B1. The CI-wired design gate fails on every canonical CI run — the BASE ref is unresolvable in CI.**
`scripts/design_gate.pl:72–102` extracts the BASE via
`git cat-file blob rage/288-spec-plan-graph-executor:prolog/rlm_plan_graph.pl` — a bare ref name that only resolves against `refs/heads/...` (DWIM). That branch exists **only as a local branch** in this worktree; it is not a head on the GitHub remote (`git ls-remote --heads github | grep 288` → no match). In a fresh clone (including `actions/checkout@v6` with `fetch-depth: 0`, which creates only `refs/remotes/origin/*`):

```
$ git clone --no-checkout <repo> scratch && cd scratch
$ git cat-file blob 'rage/288-spec-plan-graph-executor:prolog/rlm_plan_graph.pl'
fatal: invalid object name 'rage/288-spec-plan-graph-executor'.
```

The gate then prints "adoption input missing" and `halt(1)`, so the new required step `.github/workflows/ci.yml` ("Run SPEC/PLAN design gate", after research-approval validation) fails every push/PR run. Failing loudly is honest; wiring a step that cannot pass into required CI is a merge blocker. Fix in the workflow (`git fetch origin rage/288-spec-plan-graph-executor` + pin the object id) or resolve via `refs/remotes/...` fallbacks in `extract_unmerged_base/1`.

### MAJOR

**M1. `capability_unchanged` is vacuous; a load-bearing authority claim rests on it.**
`design_gate.pl:702–716` proves "compiling an HTTP-required spec leaves the environment capability set unchanged" by comparing `base_all_caps(EnvCaps0)` with `base_all_caps(EnvCaps1)` — both read the same static fact (`design_gate.pl:495–498`). The compilation outcome cannot influence the comparison, so the equality can never fail. The doc cites this check as proof (§14, capability_safety_checks) and the KB cites `gate:capability_unchanged` as evidence for the *validated* decision `dec_spec_grants_nothing` (`research/spec-plan-refinement-kb-state.pl:52, 80–81`). The real invariant — the closed `assertion_provider/6` metadata schema carries no capability field and compilation never touches the environment — is true in merged code, but this check does not test it. Related weakness: `http_observe_denied_without_cap` (design_gate.pl:721–739) constructs the payload *already carrying* `status:indeterminate(policy_denied)` and merely confirms `observation_normalize/2` preserves it; the host-refusal path ("if the observer lacks network(observation)...", doc §10.3) is never exercised, and `environment_allows/3` (741–744) tests the gate's own helper against itself.

**M2. The dropped-obligation rule is gameable by a no-op `run` step; `satisfies` is forgeable.**
`establishing_op/1` accepts `edit, create, delete, run` with no causal-linkage requirement (design_gate.pl:1612–1615; doc §11.2). Mutation experiment (scratch clone, gate in probe mode):

```
plan_graph(steps([step(fake_work, run, run(command(argv([true]))), noop),
                  step(check_spec, validate, validate(spec(fingerprint(FP))), verified)]),
           depends_on([depends_on(check_spec, [fake_work])]),
           obligations([obligation(step:fake_work, satisfies:foo_behavior_x)]))
```

with the real frozen fingerprint → `plan_validate_against_spec_gate` returns `ok(spec_compat_report{...})`. A model-authored patch can satisfy a `tdd_evidence` obligation with a step that does nothing, and §9's "edit/create steps that implement the requirement must record obligations" is not enforced — any op in the set counts, disconnected from the requirement's evidence. Also: the gate runs only the compat layer on patched graphs; §11.1's promised full chain (parse → graph validation → compat) is not re-run on the patched graph (design_gate.pl:807–824 uses `d6_apply_patch` + compat only).

**M3. Environment-input resolution: the gate's normative grammar contradicts the doc, and the SPEC-input dataflow is untestable under the gate's own rules.**
Doc D6-1 (lines 378–393) and §11 item 5 (805–806) say `input(Name)` "resolves from the execution input dict, else from the result of a completed step". The gate's static validator ignores environment inputs entirely: `d6_check_closure(Steps, Deps, _{})` discards the inputs argument and `d6_resolvable/5` only accepts dependency-closure step binds (design_gate.pl:1379–1407, 1238–1247). Mutation: a graph step `create(path('out/payload.txt'), content(expr(input(user_payload))))` — the canonical way to consume a SPEC-declared `input_decl` — is rejected by `d6_validate_graph` even when `plan_environment.inputs` contains `user_payload`. Consequences: (a) the doc's grammar and the gate's grammar disagree on what is dangling; (b) no gate check can exercise the positive SPEC-input→plan dataflow (the `input_decl` machinery of §3.3 is only ever tested negatively); (c) `d6_compat_spec_inputs` (1653–1668) has inverted logic — a required SPEC input missing from `Environment.inputs` is excused if any step references it, while §11 item 7 says presence in `Environment.inputs` is the requirement.

**M4. §2.1 misclassifies branch-only `rlm_plan` features as IMPLEMENTED (merged main).**
Doc line 90 lists "native `model_step_handler` with charge-back" under §2.1 IMPLEMENTED. `git show main:prolog/rlm_plan.pl` contains neither `model_step_handler` nor `charge_native_model_execution/2`; both exist only in this branch's unmerged runtime work (`prolog/rlm_plan.pl:758–780, 1130, 1191` here). §8.2 line 527 even says "the merged native `model_step_handler` (provided by UNMERGED `rlm_direct_model_step/10` once S10 merges)" — self-contradictory. The gate compounds this: its "IMPLEMENTED layer" loads modules "from this checkout" (design_gate.pl:19–23), i.e., the branch's `rlm_plan.pl`/`rlm_tool.pl`, not merged main. Per the design's own classification discipline, these belong in §2.2 UNMERGED (adoption via S10). Note `rlm_tool.pl` also differs: the branch adds `capability_shape(spec/1)` and `capability_shape(plan/1)` absent from main.

**M5. Undefined capability shape `project(read)` in §4.2, contradicting the closed capability model and the gate's own side table.**
Doc lines 236–238: "`symbol_exists` / `symbol_kind` / `symbol_owner` / `public_api_compatible` observers use the project index (S2) — `project(read)` capability." Merged `rlm_tool` `capability_shape/1` is closed over `rlm|parallel|retry|checkpoint|tool|context|model|graph|persistence|network|filesystem|process|mcp` — there is no `project/1` shape anywhere. The gate's own `observer_required_capabilities/2` side table instead requires `filesystem(observation)` for `symbol_exists` (design_gate.pl:335). Doc-vs-code and doc-vs-gate contradiction on the same capability claim; the gate's side table also omits entries for `locate`/`search`/`diff`/`sync_remote`/`validate`/`delegate` observers entirely.

**M6. `expert_contract.inner_capabilities` is referenced but does not exist in the §8.1 schema.**
D6-8 (doc line 418) and §8.2 (line 526) require `expert_contract{}` records "whose `inner_capabilities` (e.g. `model(P)`) must be a subset of environment-granted capabilities", but the §8.1 contract (lines 491–501) defines no such field — only `capabilities`. The gate's `expert_contract_ok/2` (design_gate.pl:1741–1760) checks the closed key set (no `inner_capabilities`) and additionally never validates `model_policy{provider, max_iterations}` shape (any dict passes), `budget_policy`, `completion`, or `failure` values. This is the same class of undefined-field contradiction that failed v1, at smaller scale.

**M7. KB discipline is pairing-only; shipped evidence contains dangling refs, and the two NEW validated decisions have no gate backing.**
Mutation (scratch clone): `kb_mark(s05, done)` + `kb_record_evidence(s05, 'self:authored:claim')` → `kb_check` passes and `kb_task_done(s05)` is true; likewise a self-`kb_validate_decision`/1'd decision. `completion_evidence_/1` (kb.pl:156–159) accepts any self-authored evidence atom or self-validated decision; nothing external validates authenticity, and `kb_violation/1` never checks that evidence refs resolve. The shipped state file proves the point: four evidence refs cite gate check ids that do not exist — `gate:d6_dataflow_ok` (line 37; actual id `d6_dataflow_round_trip`), `gate:http_schema_ok` (49), `gate:http_malformed_rejected` (50), `gate:design_gate_passes` (64). The two NEW validated decisions added by commit 5bb2817 — `dec_forward_projection` (d12) and `dec_multi_run_state` (d06) — are backed only by self-authored refs: no gate check exercises §12.2 forward projection (cursor/id-range survival, boundary summaries) or §7.3 multi-run readability (direct-mode per-turn recompilation, expert feed-back); `dec_multi_run_state`'s cited section anchor is `#s8-experts-and-loop` (§8), but the multi-run claim is §7.3. The d06 decision's placement under d06 rather than a §7.3 task is also untracked.

**M8. Undeclared BASE divergences (lens 2).**
(a) BASE diff sides are `path|ref|span` only — `side_valid/1` (288:744–754) has no `revision/1` clause, yet doc §6.2's BASE table says `diff(L, R), sides per Section 5`, and §5 includes `revision(revision_ref)` sides. Adding revision resolution is real reconciliation work but is not declared as a D6 delta (D6-1..D6-8). (b) BASE `json_symbol_ref/2` accepts any non-empty atom `kind` (288:447–449); doc §5 mandates the closed 13-atom `symbol_kind` set — also undeclared as a delta (the gate's `symbol_ref_dict/1` enforces the closed set, so the gate is already stricter than the BASE it adopts). Neither divergence silently changes BASE semantics at runtime, but both are claimed-as-BASE features the branch does not have, which the charter defines as blocker-class; I grade them MAJOR because they are additive omissions in the delta list, not semantic rewrites.

### MINOR

- **m1.** Doc §14 line 948: "currently runs 47 checks in 10 groups" — actual run: **46 checks in 11 groups** (`grep -c '^\s*check('` = 47 including the `check/2` definition; the run prints 46 `ok`). The charter's "47/47" cannot be confirmed.
- **m2.** Dead gate helpers: `require_ok/2` (design_gate.pl:125–126) defined, never called; `d6_args_shape_resolved/2` (1296–1316) defined, never called — the adjacent comment (1321–1322) claims "the resolved value is re-validated against the strict type after admission-time substitution", but the dataflow check (650–684) only does manual equality tests; `environment_allows/3` `allowed` branch (741–742) unreachable.
- **m3.** `docs/typed-plans.md` (edited in this slice) line 221: subplans "use `rlm/3`" — merged AST and the design record's own §7.2 say `rlm/2`; line 222 cites a "`strategy_select/3` design target in `docs/research/spec-plan-authority.md`" that appears nowhere in that record (§7.1 defines `strategy_mode/2`), and the adopted `rlm_spec_strategy.pl` defines neither (its `normalize_mode/1`, line 353–354, accepts only `direct|typed_plan` and rejects `symbolic`). Three-way doc drift on the strategy boundary.
- **m4.** `path_template_name/2` (design_gate.pl:2020–2028) only matches paths that are *entirely* one template (`Rest0 == []`); a path like `"/users/{id}"` with declared `path_params` would be rejected by `http_request_ok` — stricter than the doc's "path template with `{name}` templates" concept. Latent (no gate example exercises embedded templates).
- **m5.** Doc §4.2's symbol observers vs gate side table mismatch (filesystem(observation) vs the doc's index claim) — subsumed by M5 but worth one reconciling sentence.
- **m6.** Live lane: `test/live_conversation_scale_openrouter_test.pl` (new on this branch) fails consistently (3/3 runs) with the pinned paid model `z-ai/glm-5.3-flash` — HTTP 200 both rounds, failure is in retrieval/acceptance assertions (`validate_model_retrieval`/`Turn.assistant.content == ExpectedPayload`). Repro: `OPENROUTER_TEST_MODEL=z-ai/glm-5.3-flash swipl -q -s test/run_live_openrouter.pl`. Not a design-record defect, but the branch's paid gate has a failing live test that must be resolved before merge per the repo's completion standard. (Also: the charter's suggested id `openrouter/z-ai/glm-5.3-flash` is rejected by OpenRouter itself — 400 "not a valid model ID"; the correct env value has no `openrouter/` prefix.)

### NOTES

- `d6_rejects/1` (design_gate.pl:152–156) treats a plain validation *failure* (non-throwing) as rejection; a checker that silently fails would still "pass" a negative test. Acceptable, but a thrown `gate_fault` vs silent fail distinction is worth an assertion style rule.
- `d6_apply_patch/3` implements only `op:remove`; add/replace paths are untested by the gate (declared design target; fine).
- The gate writes a transient copy of the BASE module under `prolog/design_gate_tmp_<pid>.pl` and deletes it; deleted in a cleanup and load fails loudly if extraction fails — no residue observed.
- CI placement otherwise correct: gate step runs after research-approval validation, before paid/credential lanes, uses no model calls, and the diff removes or weakens no existing gate.

---

## Verdict: **NEEDS-CHANGES**

The rewrite genuinely fixes every v1 blocker and the BASE adoption table is faithful — but the slice cannot merge as-is: B1 makes required CI permanently red, and M1–M3 mean the gate's headline guarantees ("SPEC grants nothing", "dropped obligation is unrecoverable", "typed dataflow with SPEC inputs") are vacuously proved, internally contradicted, or gameable.

## Gate checks to ADD (concrete)

1. `base_ref_resolvable` — resolve the BASE through an explicit candidate list (`refs/heads/<b>`, `refs/remotes/origin/<b>`, pinned object id) and fail with the resolved name in the fault; plus a CI workflow change fetching/pinning the ref (B1).
2. `metadata_capability_rejected` — compile a registry whose provider metadata attempts a `capability` field and assert merged `normalize_metadata/2` throws; keep `capability_unchanged` only if its env set comes from an actual API surface rather than a static fact compared to itself (M1).
3. `host_observation_refusal` — drive a real collector/observer ABI with the capability absent (not a pre-set `indeterminate` payload) and assert the outcome is conservative-indeterminate, never passed (M1).
4. `obligation_causal_link` — reject `dropped_obligation`-passing graphs where the establishing step is not transitively required by (or otherwise causally connected to) a `validate/1` step of the bound spec; for `tdd_evidence` kinds restrict establishing ops to `edit|create` per §9 (M2).
5. `patch_full_chain` — after `d6_apply_patch`, re-run parse + graph validation + compat on the patched graph, including dangling-input re-checking (M2/m).
6. `spec_input_env_dataflow` — positive round trip: a graph consuming `expr(input(<spec_input>))` validates when the input is present in `plan_environment.inputs` and is flagged `missing_spec_input` when absent, regardless of step references (M3).
7. `expert_contract_shape` — require the `inner_capabilities` field (or rename `capabilities` everywhere), validate `model_policy{provider, max_iterations>0}`, `budget_policy`, `completion`/`failure` condition values (M6).
8. `kb_evidence_refs_resolve` — every `kb_evidence/2` ref of shape `gate:<Id>` must name a check id the gate actually defines; `design:<anchor>` refs must name existing document anchors (M7).
9. `symbol_kind_closed` — a plan graph with `kind:frobnicate` in a `symbol_ref` is rejected (M8b).
10. `diff_revision_side` — accept/reject checks for `revision(head|working|committed/1|branch/1|remote/2)` diff sides, gated on the doc declaring the delta (M8a).
11. `resolved_shape_revalidated` — call `d6_args_shape_resolved/2` on the output of `d6_resolve_step_args` inside the dataflow check, or delete the dead predicate and fix the comment (m2).

Doc fixes required alongside: 47→46 checks/10→11 groups (§14 line 948); move `model_step_handler`/`charge_native_model_execution` to §2.2 UNMERGED (line 90, 527); replace `project(read)` with a defined shape or declare it a NEW DESIGN TARGET (lines 236–238); reconcile `inner_capabilities` vs `capabilities` (lines 418, 526); fix `rlm/3`→`rlm/2` and `strategy_select/3`→`strategy_mode/2` in `docs/typed-plans.md` (lines 221–222); replace the four dangling KB evidence refs; give the two new validated decisions (d12/d06) gate-backed evidence or reclassify them as candidate.
