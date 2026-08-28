# Final adversarial review: #288 plan-graph executor (HEAD 496e48f)

- Reviewer: final adversarial review pass, current branch, HEAD `496e48f` ("feat(plan-graph): closed project-op vocabulary and ready_step dependency-graph executor").
- Scope: implementation commit at HEAD vs design `docs/research/plan-graph-executor-design.md`, prior review `rage/288-review-research-report.md` (REQUIRED CHANGES 1-7), docs `docs/plan-graph-runtime.md`, AGENTS.md invariants, issue #288 body.
- Nothing outside this report was modified. Full suite and live-provider gates were NOT run (per instructions). Focused suite, contract gate, `check_runtime`, `load_all`, and adversarial SWI probes were run (log below).

## VERDICT

**sound-with-changes.**

The authority core is sound: model data never reaches `call/1` as a goal, the closed-vocabulary-before-desugar ordering holds empirically against every collision I could construct, `rlm_plan` remains the only step executor, and there is one async submission with same-Future await. Cancellation (prior REQUIRED CHANGE 1) is verified end-to-end through the Future with the exact token. The aggregate budget feed-forward (REQUIRED CHANGE 2) is implemented and structurally sound for completed steps. However, there are four must-fix findings: validation **fails silently (no structured outcome at all)** for several model-triggerable inputs, the aggregate-budget **exhaustion semantics deviate from the documented `aborted`/reason-`budget` contract**, the **JSON args-level closed key set is not enforced**, and **8 of 24 tests still emit "Test succeeded with choicepoint"** with a latent contradictory-on-backtrack error-classification bug behind them. None is an authority or effect-boundary breach; all are fixable without design change.

## CRITICAL FINDINGS (blocking)

None. Specifically verified as absent:

- No path from model data to `call/1` as a goal. `grep -n "call(" prolog/rlm_plan_graph.pl` returns **zero** call-sites; the only model-data `call` is `rlm_plan`'s trusted `call(Handler, Args, ToolResult)` (`prolog/rlm_plan.pl:944-948`) with the handler resolved from the host registry by exact atom match (`rlm_plan.pl:1358-1360`).
- No new external-effect path: the module performs no filesystem/network/process I/O; shipped handlers in tests/fixtures are pure host closures; effect classes are declared (`op_effect_class/2`, `prolog/rlm_plan_graph.pl:90-101`) with the durable-boundary obligation documented.
- No cancellation loss: cancellation aborts the graph and rethrows the exact token through the Future in all three shapes I could exercise (see verification log C1-C3).

## MAJOR FINDINGS (must-fix before merge)

### M1 — Validation fails SILENTLY (no outcome) for model-triggerable inputs

For several adversarial inputs, `plan_graph_run*` produces **no outcome at all**: the submitted goal simply fails, and the awaiting facade observes only the opaque `error(async_error{kind:goal_failed, ...})` (`prolog/rlm_async.pl:285-291`). This violates `docs/plan-graph-runtime.md:53` ("`Outcome` is `ok(...)` or `error(plan_graph_error{phase, kind, detail})`") and the design's §5 "first fault wins" error catalogue. Fail-closed (no step executes) but unstructured, and diagnostics are destroyed. Confirmed cases:

1. **Known op with a malformed scalar arg value.** `{"op":"index","args":{"scope":42}}` → the decoder builds the sentinel `invalid_args(index, Dict)` where `Dict` is the raw JSON dict **with an unbound tag** (SWI `atom_json_dict/3` default) → the sentinel is not ground → `ground(Args)` in `valid_step_shape` (`prolog/rlm_plan_graph.pl:544`) fails inside `forall` → `check_structure` fails silently (`prolog/rlm_plan_graph.pl:527-535`) → `plan_graph_validate_`'s conjunction fails instead of raising `invalid_args`. Verified: `args NOT ground (sentinel carries unbound-tag dict)`; `check_structure FAILED silently`. The implementation log (`rage/288-spec-plan-graph-executor.org`, "empty-dict variable tags broke ground/1") shows this trap was known and only partially fixed.
2. **`depends_on` entry naming a non-existent step with non-empty `requires`** (e.g. `{"step":"ghost","requires":["s1"]}`) → `edges_consistent` (`prolog/rlm_plan_graph.pl:558-574`) uses plain failure inside `forall` instead of `graph_fault(structure, invalid_graph(...))` → silent failure. Verified: `ghost_dep_nonempty => async_error{kind:goal_failed}`.
3. **Duplicate `depends_on` entries for the same step** (two edges vs concatenated requires) → same silent `edges_consistent` failure. Verified.
4. **Malformed host capabilities** (non-list caps argument) → `capabilities_narrow(Caps0, Caps0, ...)` fails rather than returning an error outcome (`prolog/rlm_plan_graph.pl:520-521` has no else-branch) → silent failure. Verified: `bad_caps => async_error{kind:goal_failed}`. (Host-side input, but the docs promise a structured outcome for everything the facade returns.)

### M2 — Aggregate-budget exhaustion semantics deviate from the documented contract

Docs (`docs/plan-graph-runtime.md:169-173`) and design §7 promise: a step that cannot be funded → graph aborts, remaining steps `abandoned`, outcome `status:aborted` with reason `budget`. Observed instead (probe `exhaust12`: three independent steps, `max_total_output_bytes:12`, tiny step-1 result):

- s1 completes and consumes the entire aggregate output allowance (`Agg.output_bytes = 0`).
- `admit_step` only checks `tool_calls < 1` and the deadline (`prolog/rlm_plan_graph.pl:922-935`) — it does not check the other feed-forward classes, so the unfundable step is admitted.
- The derived step budget carries `max_output_bytes:0`; `rlm_plan`'s `validate_budget_values` rejects 0 for `max_output_bytes` (`prolog/rlm_plan.pl:402`) as `plan_validation(invalid_budget_field(...))`, mapped to `plan_error{phase:validate, kind:invalid_plan, detail:invalid_budget_field(...)}` (generic `validation_fault`, `prolog/rlm_plan.pl:1470-1474`).
- `budget_exhaustion/1` (`prolog/rlm_plan_graph.pl:1045-1050`) matches only `kind:budget_exhausted` or `kind:budget_exceeded` with `phase:budget` — so this is classified as an **ordinary step failure**. Result: `status=failed reason=none`, steps marked `failed` (not `abandoned`), and the loop keeps admitting further unfundable steps (s3 also failed the same way).

Mitigating (why not critical): fail-closed on effects — the unfundable steps' handlers are never invoked (verified `calls=[index]` only), and the aggregate tool-call bound is structurally guaranteed by the static check `StepCount ≤ max_total_tool_calls` (`prolog/rlm_plan_graph.pl:763-765`) combined with the one-tool-call desugar shape, so no budget escape exists. But the terminal state and reasons contradict the documented guarantee, and this path is untested.

Related doc nuance: `docs/plan-graph-runtime.md:168` says budget is deducted "after each step"; the implementation charges only **completed** steps (`classify_step`, `prolog/rlm_plan_graph.pl:1020-1031`; the error branches at 1032-1040 do not charge). With the current desugar this cannot be exploited (failed step ⇒ its final never ran ⇒ only its single tool call is uncharged, which is structurally bounded per above), but the doc wording overstates the mechanism.

### M3 — JSON args-level closed key set is not enforced

Design §4: "each op's arg-shape table names its JSON keys and closed-term constructor; anything outside the key set or the closed value domain is a `phase:normalize, kind:invalid_args` error." The per-op decoders (`decode_known_args/*`, `prolog/rlm_plan_graph.pl:347-389`) only **read** the keys they need; extra keys in the args object are silently ignored:

- `read` with `args:{"source":{"path":"x"},"evil":1}` → graph **completed** (probe `read_extra_key`).
- `create` with an extra `"smuggled":{"deep":[1,2,3]}` key → parse returns **ok** (probe `create_extra_args`).

No authority impact (the handler receives only the decoded closed term; smuggled keys are dropped), but a documented validation guarantee does not hold, and model mistakes are silently masked. Nested wrapper objects (`source`, `symbol`, `ref`, `span`) DO enforce exact keys (`require_exact_keys`) — the gap is only at the args-object level.

### M4 — Choicepoint warnings remain (8/24 tests) with a contradictory-on-backtrack root cause

The verification bar for this review explicitly requires zero "Test succeeded with choicepoint" warnings in the new suite. **8 tests warn** (24/24 do pass): `rejects_unknown_op`, `vocabulary_validated_before_desugar`, `rejects_unknown_dependency`, `rejects_cycle`, `rejects_duplicate_step_id`, `budget_bounds_step_count`, `capability_denied_per_op`, `delegate_narrows_capabilities` — exactly the tests that take the graph_fault recovery path.

Root cause (isolated by probe): `graph_exception/3`'s graph_fault clause (`prolog/rlm_plan_graph.pl:173-177`) lacks a cut, so clause 3 (generic exception, line 178-181) remains an alternative; additionally `fault_kind/2`'s catch-all `fault_kind(_, invalid_input)` (line 207) matches beneath every specific clause. Consequences:

- Every fault recovery leaves a choicepoint (PlUnit warnings);
- On backtracking, the SAME fault yields **different, contradictory classifications**: verified `graph_exception(validate, graph_fault(structure, duplicate_step_id), O)` produces `kind:duplicate_step_id`, then `kind:invalid_input`, then `kind:exception` across solutions. The first solution is correct, but any caller that backtracks into a returned outcome observes a different error for the same graph — nondeterministic error semantics in a module whose headline property is deterministic scheduling.

One-line-class fix (cut the fault clause / make `fault_kind` specific clauses final), plus the tests then re-run warning-free.

## MINOR FINDINGS

1. **Malformed non-text scalar values leak raw `type_error` with wrong phase.** `{"op":"read","args":{"source":{"path":{"deep":1}}}}` → `atom_string/2` in `require_atom_key` (`prolog/rlm_plan_graph.pl:134-139`) throws `type_error`; because `plan_graph_execute_` calls the un-wrapped `plan_graph_parse_` directly (`prolog/rlm_plan_graph.pl:822`), it surfaces as `phase:execute, kind:exception, detail:exception_data(type_error(...))` instead of the documented `kind:invalid_args` (docs `plan-graph-runtime.md:127-134`, design §4/§5). Also note `plan_graph_execute`'s outcomes for parse faults are misphased (execute, not parse).
2. **Phase mislabeling from shared helpers.** `require_dict_key`/`must_list` always throw `graph_fault(structure, ...)` even when invoked during decode/normalize (e.g. `args` = JSON array → `phase:structure, kind:invalid_structure, detail:missing_key(source)`; docs promise a `normalize` phase for decode faults).
3. **Per-step output double-charge.** The desugared plan consumes the tool result's bytes twice — once at bind (`bind_value`→`consume_output`, `prolog/rlm_plan.pl:1101-1117`) and again at `final(var(Bind))` (`prolog/rlm_plan.pl:999`). Effective per-step output cost is 2× the value bytes (verified: budget=6 with a 6-byte result aborts at s1's final). Design §8 implies a single charge. Fail-closed; only makes budgets stricter.
4. **`plan_graph_cancel/1` + `cancellation_token/1` option have no unit coverage.** The suite covers handler-thrown cancellation only; the exported token plumbing (state flip, worker registration, `thread_signal`) is exercised by no test. Verified manually that both paths work (log C2/C3) — the gap is coverage, not behavior. The contract gate pins only the export (`scripts/plan_graph_contract_check.pl:117-118`).
5. **Docs slightly overclaim the delegate spawn re-check.** `docs/plan-graph-runtime.md:86-87` says child caps are validated at validation and "the spawn path re-checks." In this slice, a `delegate/2` step desugars to a plain `tool(spawn_agent, literal(delegate(task,caps)), Bind)` step executed by the host-supplied handler (verified: handler receives `delegate(task(t), caps([tool(read)]))`, not `agent_spawn_request{}`); `rlm_plan` does not route `tool(spawn_agent, ...)` through the canonical `rlm_agent` spawn/narrowing path. Any re-check at execution is the host handler's obligation. Also note the args-shape mismatch a canonical spawn handler would see.
6. **Design deviations not recorded as corrections:**
   - Design §6 mandates unwrapping BOTH cancellation shapes (thrown + `plan_outcome/5`-folded). The implementation calls `plan_execute/4` directly (never `plan_outcome/5`), so the folded shape cannot occur; `step_throw` (`prolog/rlm_plan_graph.pl:1005-1009`) covers thrown + thread-signal shapes. Justified, but not recorded as a deviation in the design record.
   - Design §10 metadata ("task kind `plan_graph`, step count, capability count") vs implemented `async_metadata{operation:plan_graph_run, graph_id, graph_run_id, trace_id, session_id}` (`prolog/rlm_plan_graph.pl:1220-1228`) — no step/capability counts. Cosmetic.
   - Design §2.1 types `plan_graph_execute/5` as taking `+ValidatedGraph`; implementation takes raw `+Input` and validates inside the worker — consistent with design §10 and docs; the §2.1 wording is the stale half.
7. **Term-form arg-shape faults surface as vocabulary faults.** `step(s1, index, not_an_index_term, b)` → `unknown_op(index/unknown_arity)` at phase `vocabulary` (second `decode_term_step` clause, `prolog/rlm_plan_graph.pl:312-318`), not `invalid_args`. Fail-closed and attributable, but the phase/kind catalogue diverges from docs for term input.
8. **Ghost `depends_on` entry with empty `requires` is silently dropped** (`dep_requires_nonempty` filter, `prolog/rlm_plan_graph.pl:489-494`) rather than rejected; inert, but untidy against "exactly step/requires keys, validated" wording.
9. **DoS hardening (low).** Validation order puts the aggregate-budget gate last (`prolog/rlm_plan_graph.pl:513-524`), so structure/duplicate/DFS checks run O(steps·edges) before an oversized graph is rejected. 1000 steps parsed+validated+executed-failed in 0.05s (probe), so practical risk is low, but a very large dense graph burns worker time before rejection. Consider an early step-count check.
10. **Unknown options are silently ignored** by `graph_option/4` (`prolog/rlm_plan_graph.pl:141-151`) — e.g. a misspelled `expertz([...])` falls back to `[]` and fails at preflight (observed), which is fail-closed, but option validation would give better diagnostics.

## VERIFICATION LOG

Baseline commands:

| Check | Result |
|---|---|
| `swipl -q -s test/rlm_plan_graph_test.pl -g run_tests` | **24/24 passed**; **8 "Test succeeded with choicepoint" warnings** (M4); tests 1-5, 10-16, 18-24 clean |
| `./scripts/plan_graph_contract_check.sh 1` | `contract: ALL REQUIREMENTS DEFINED` (exit 0); includes `module_export_run_async`, `module_export_cancel`, `module_export_cancellation_token`, exact 12-op vocabulary equality, `no_call_escape` probes |
| `swipl -q -s test/check_runtime.pl` | clean (exit 0) |
| `swipl -q -s test/load_all.pl` | clean (exit 0) |
| `grep -n "call(" prolog/rlm_plan_graph.pl` | zero matches (authority static check) |
| `grep "Test succeeded with choicepoint"` over suite | 8 hits, tests listed in M4 |

Adversarial probes (fresh SWI sessions against `prolog/rlm_plan_graph.pl`, host handlers recording invocation; "calls" = host handlers actually invoked):

| Probe | Input | Result |
|---|---|---|
| A1 authority: op collisions | ops `final`, `tool`, `spawn_agent`, `call`, `,`, `model` via JSON | all → `error(...phase:vocabulary, kind:unknown_op, detail:op(...))`, **zero handler calls** — vocabulary-before-desugar holds |
| A2 malformed args | `read` with `source.path` = dict / extra args key; `index` scope=42 | dict-valued → `type_error` leak (minor 1); extra keys → **silently accepted** (M3); scope=42 → **silent goal_failed** (M1) |
| A3 structure attacks | duplicate bind; self-dep; ghost dep (empty + non-empty); duplicate depends_on entries; extra step key | dup-bind → structured `duplicate_bind`; self-dep → `cycle([s1,s1,s1])`; ghost non-empty + duplicate entries → **silent goal_failed** (M1); ghost empty → silently dropped (minor 8) |
| A4 delegate caps | `network(http)`, `tool(read` , `tool(read(x))`, `tool(run)` | all rejected (`decode_json_cap` closed shape) — no cap smuggling; delegate exec probe: handler invoked with `delegate(task,caps)` args (minor 5) |
| A5 JSON oddities | duplicate JSON keys; prose-wrapped object | duplicate keys → `kind:invalid_json` (structured); prose-wrapped → parses ok |
| A6 term form | malformed args; `index(scope(call(halt)))`; `depends_on(s1, s2)` non-list; self-dep | `unknown_op(index/unknown_arity)` (minor 7); `invalid_args` (goal-shaped term correctly rejected); `not_a_list(requires)`; `cycle` |
| B1 cancellation (unit test) | handler throws `error(rlm_cancelled(tok123), _)` mid-step | throws exact token through `plan_graph_run` → Future → facade; second step never executed (`Calls == [sync_remote]`) — prior REQUIRED CHANGE 1 verified |
| B2 pre-cancelled token | `plan_graph_cancellation_token/1` + `plan_graph_cancel/1` **before** run, token via `cancellation_token(Tok)` option | THROWN `error(rlm_cancelled(<exact uuid token>), context(plan_graph_cancelled))`; zero handler calls |
| B3 mid-graph cancel | `plan_graph_cancel/1` from observer thread while step 1 sleeping | exact token observed by awaiting thread; step 2 never executed. Handler-thrown `graph_cancelled/1` (invalid scenario) correctly treated as ordinary tool error — `step_throw`'s `graph_cancelled` clause is for thread-signal delivery, not handler misuse |
| B4 async control path | — | `rlm_async` classifies `error(rlm_cancelled(_),_)` as control exception preserving `exception_term` (`prolog/rlm_async.pl:300-310, 327-328`); `rlm_future_await` rethrows the exact term (`prolog/rlm_async.pl:440-445`) |
| C1 budget feed-forward math | `charge_aggregate` vs design §7 | consumed = `StepBudget.class − plan_result.budget_remaining.class` clamped ≥ 0, per class; steps −1 per completion; runtime exhaustion `kind:budget_exhausted` → `aborted_budget` → abort ✓ (`aggregate_budget_enforced_across_steps` + probe exhaust6: `aborted/budget`, steps `abandoned`) |
| C2 aggregate bound soundness | — | static estimate enforces `StepCount ≤ max_steps` AND `StepCount ≤ max_total_tool_calls` (`prolog/rlm_plan_graph.pl:763-765`); with 1-tool-call desugar, total tool calls ≤ aggregate regardless of failed-step charging — no escape found |
| C3 exhaustion edge | aggregate output_bytes exactly consumed by step 1, 2 independent steps remain | `status=failed reason=none`, steps `failed` not `abandoned` — contradicts docs/design (M2); unfundable handlers never invoked |
| D scheduling | diamond with failing branch; never-ready chain | diamond: `[index, fail, read]`, `s2:failed, s3:completed, s4:blocked`, deterministic input order; failed seed → transitive `blocked` ✓ |
| E scale | 1000-step JSON graph | structured `budget_exceeded(max_steps,1000,64)` in 0.05s (minor 9) |
| F determinism | `call_cleanup/3` Det probes | fault-path recovery leaves choicepoint; backtracking yields `duplicate_step_id` → `invalid_input` → `exception` for the same fault (M4) |

## REQUIRED CHANGES 1-7 (prior review) — verification

1. **Cancellation propagation** — ADDRESSED and verified (B1-B4; unit test `cancellation_aborts_graph_and_rethrows_token`; `step_throw`/`classify_step`/run-loop token check; exact token through Future). Coverage gap for the exported `plan_graph_cancel/1` plumbing noted (minor 4).
2. **Aggregate graph budget** — ADDRESSED (`default_plan_graph_budget/1`, feed-forward via `plan_result.budget_remaining`, per-step `min(default, remaining)` derivation, abort-on-exhaustion test). Residual: unfundable-step classification deviation (M2).
3. **Capability terms `tool(Op)`** — ADDRESSED: single mechanical source `plan_capability_required/2` (`prolog/rlm_plan_graph.pl:76-83`), `tool(spawn_agent)` for delegate, per-op denial test, gate source-mention.
4. **Desugar shape** — ADDRESSED: `plan([tool(Op, literal(Args), Bind), final(var(Bind))])` (`prolog/rlm_plan_graph.pl:963-964`); inner capability `[tool(ToolName)]`; result plumbing through bind/final.
5. **Durable-effect-boundary direction** — ADDRESSED: design §1/§3, `op_effect_class/2` declaration, docs effect table + guarantee boundary; no new effect path (verified: no I/O in module; handlers pure closures).
6. **Async surface in the gate** — ADDRESSED: gate pins `plan_graph_run_async/4`, `plan_graph_cancel/1`, `plan_graph_cancellation_token/1`; one `rlm_async_submit` + same-Future await verified (`prolog/rlm_plan_graph.pl:1206-1228`; `call(Goal, Value)` convention `prolog/rlm_async.pl:285`); no nested Future waits.
7. **Issue-text reconciliation** — ADDRESSED: issue #288 body now states the closed-AST-world reading, exact desugar shape, `tool(Op)` terms, cancellation, aggregate budget, async surface, and abandoned-terminal; implementation log records the reconciliation.

## REQUIRED CHANGES (this review)

1. **(M4)** Make `graph_exception/3`'s graph_fault clause deterministic (add cut) and make the specific `fault_kind/2` clauses final (or invert with the catch-all guarded) so fault recovery is choicepoint-free and backtracking cannot reclassify a fault. Re-run the focused suite and confirm zero "Test succeeded with choicepoint" warnings.
2. **(M1)** Replace silent failure with structured faults: (a) build the `invalid_args` sentinel with a ground representation of the offending args (e.g. tag the JSON dict or store a quoted/term_string form) so `ground(Args)` in `valid_step_shape` cannot silently fail; (b) make `edges_consistent` raise `graph_fault(structure, invalid_graph(...))` on edge/step mismatch instead of failing; (c) map malformed host capabilities/options to `graph_fault(capability, ...)`/`invalid_expert_registry` instead of letting `capabilities_narrow` fail the validation conjunction.
3. **(M3)** Enforce the per-op args-object exact key set in the JSON decoders so extra keys produce `kind:invalid_args` per design §4.
4. **(M2)** Make aggregate unfundable-step handling conform to the documented contract: check funding at `admit_step` for all feed-forward classes (not just tool_calls/time) or classify the derived-zero-budget rejection (`invalid_budget_field`) as budget exhaustion; outcome must be `status:aborted`, reason `budget`, remaining steps `abandoned`. Add a PlUnit test for the aggregate-fully-consumed-then-next-step case (current tests only cover mid-step runtime exhaustion).
5. **(minor 1/2)** Catch decoder exceptions inside `decode_args` and map them to `invalid_args`; route parse faults in `plan_graph_execute_` through the parse-phase wrapper (or fix phase attribution) so `kind:invalid_args`/`phase:normalize` match the documented catalogue.
6. **(minor 4)** Add PlUnit coverage for `plan_graph_cancellation_token/1` + `plan_graph_cancel/1` (pre-cancelled and mid-graph signal paths), using deterministic synchronization (no sleeps) per AGENTS.md.
7. **(docs)** Correct `docs/plan-graph-runtime.md`: "after each step the consumed budget is deducted" → completed steps (or implement charging for failed steps); qualify the delegate "spawn path re-checks" sentence as a host-handler obligation in this slice; record the cancellation-shape simplification and metadata deviation in the design record.

Non-goals respected; no fixes were applied by this review. Findings M1-M4 are all contained in `prolog/rlm_plan_graph.pl` + tests + docs and do not require design changes.
