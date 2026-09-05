/* Persisted state for the SPEC/VALIDATE/PLAN research/design KB.
 * Written by spec_plan_refinement_kb update predicates; regenerable.
 *
 * Design-pass tasks d01..d14 are done WITH completion evidence (design
 * document section + design-gate check id + merged/unmerged source).
 * Implementation slices s00..s11 remain pending until their slices land.
 * A bare status(done) with no evidence/validated decision is a gate
 * violation (kb_violation/1), so this file must always pair them.
 *
 * Evidence refs are machine-checked by the design gate
 * (kb_evidence_refs_resolve): every gate:<Id> ref names a check id the
 * gate defines; every design:spec-plan-authority#<anchor> ref names an
 * anchor parsed from the design record's headings.
 */
:- assertz(spec_plan_refinement_kb:kb_status(d01, done)).
:- assertz(spec_plan_refinement_kb:kb_status(d02, done)).
:- assertz(spec_plan_refinement_kb:kb_status(d03, done)).
:- assertz(spec_plan_refinement_kb:kb_status(d04, done)).
:- assertz(spec_plan_refinement_kb:kb_status(d05, done)).
:- assertz(spec_plan_refinement_kb:kb_status(d06, done)).
:- assertz(spec_plan_refinement_kb:kb_status(d07, done)).
:- assertz(spec_plan_refinement_kb:kb_status(d08, done)).
:- assertz(spec_plan_refinement_kb:kb_status(d09, done)).
:- assertz(spec_plan_refinement_kb:kb_status(d10, done)).
:- assertz(spec_plan_refinement_kb:kb_status(d11, done)).
:- assertz(spec_plan_refinement_kb:kb_status(d12, done)).
:- assertz(spec_plan_refinement_kb:kb_status(d13, done)).
:- assertz(spec_plan_refinement_kb:kb_status(d14, done)).
:- assertz(spec_plan_refinement_kb:kb_status(s00, done)).

:- assertz(spec_plan_refinement_kb:kb_evidence(d01, 'design:spec-plan-authority#2-inventory-and-classification')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d02, 'design:spec-plan-authority#3-canonical-spec-language')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d02, 'gate:spec_reject_spec2')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d02, 'source:prolog/rlm_spec_lang.pl')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d03, 'design:spec-plan-authority#5-canonical-reference-grammar-one-hierarchy')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d03, 'gate:plan_reject_bad_ref')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d03, 'source:prolog/rlm_plan_graph.pl')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d04, 'design:spec-plan-authority#6-canonical-plan-language')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d04, 'design:spec-plan-authority#63-d6-deltas-each-owned-by-the-reconciliation-slice')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d04, 'gate:plan_base_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d04, 'gate:plan_reject_unknown_op')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d04, 'gate:plan_reject_bad_arity')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d04, 'gate:plan_native_set_closed_in_merged_vocabulary')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d04, 'gate:plan_native_capability_denied_fail_closed')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d04, 'gate:plan_native_capability_exact_admission')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d04, 'gate:plan_native_desugar_is_canonical_tool_step')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d05, 'design:spec-plan-authority#83-edit_action--llm-output-into-the-write-expert-closed-schema')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d05, 'gate:d6_dataflow_round_trip')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d05, 'gate:spec_input_env_dataflow')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d05, 'gate:d6_dangling_rejected')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d05, 'source:prolog/rlm_plan.pl:resolve_expr')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d06, 'design:spec-plan-authority#8-experts-dataflow-and-the-iterative-coding-loop')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d06, 'design:spec-plan-authority#73-continuous-project-state-readability-across-modes-hard-requirement')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d06, 'gate:edit_action_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d06, 'gate:expert_contract_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d06, 'gate:expert_contract_shape')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d06, 'gate:multi_run_reprojection')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d07, 'design:spec-plan-authority#4-spec-domains-via-trusted-assertion-kinds')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d07, 'gate:spec_compile_domain_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d08, 'design:spec-plan-authority#9-tdd--red-first-evidence-separate-from-final-spec')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d08, 'gate:tdd_red_green')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d08, 'gate:tdd_not_red_rejected')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d09, 'design:spec-plan-authority#10-http--network-model')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d09, 'gate:spec_compile_http_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d09, 'gate:http_reject_status_700')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d09, 'gate:http_reject_body_without_schema')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d10, 'design:spec-plan-authority#103-network-authority-closed-mapping')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d10, 'gate:capability_unchanged')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d10, 'gate:metadata_capability_rejected')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d10, 'gate:host_observation_refusal')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d11, 'design:spec-plan-authority#11-plan--spec-compatibility-one-canonical-api')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d11, 'gate:replan_drop_rejected')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d11, 'gate:obligation_causal_link')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d11, 'gate:patch_full_chain')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d11, 'gate:replan_preserve_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d11, 'gate:spec_compat_foreign_ref')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d12, 'design:spec-plan-authority#12-durability')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d12, 'design:spec-plan-authority#122-forward-projection-never-compaction')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d12, 'gate:resume_snapshot_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d12, 'gate:forward_projection_snapshot')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d12, 'gate:kb_discipline_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d13, 'design:spec-plan-authority#13-implementation-dependency-dag')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d13, 'gate:dag_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d14, 'design:spec-plan-authority#14-design-gate')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d14, 'gate:kb_discipline_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d14, 'gate:plan_graph_merged_module_loaded')).
:- assertz(spec_plan_refinement_kb:kb_evidence(s00, 'source:prolog/rlm_plan_graph.pl')).
:- assertz(spec_plan_refinement_kb:kb_evidence(s00, 'gate:plan_graph_merged_module_loaded')).
:- assertz(spec_plan_refinement_kb:kb_evidence(s00, 'gate:plan_base_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(s00, 'gate:plan_native_set_closed_in_merged_vocabulary')).

:- assertz(spec_plan_refinement_kb:kb_decision(d02, dec_no_spec2,
    'Keep merged spec(Forms) root; spec identity belongs to frozen_spec.ref only; no spec(Id,Forms)', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d04, dec_plan_base,
    'Adopt rage/288 closed op vocabulary and ready-step executor as PLAN BASE; reconciliation slice owns every D6 delta', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d04, dec_rename_not_op,
    'rename is an internal write-engine primitive, not a plan-visible op', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d04, dec_generate_not_op,
    'model generation is owned by expert inner loops; no plan-visible generate op', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d05, dec_admission_binding,
    'expr leaves resolve at step admission from environment inputs plus dependency-closure step binds; desugared rlm_plan AST unchanged', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d06, dec_expert_owned_loop,
    'iterative coding loop owned by the expert pack inside the desugared step; one rlm_async scheduler; native model_step_handler charge-back', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d08, dec_pair_evidence,
    'TDD acceptance is the red-failed+green-passed observation pair bound to revision refs, never final-spec state', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d10, dec_spec_grants_nothing,
    'SPEC compilation never widens the host capability set; observation capability never implies mutation authority', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d11, dec_patch_revalidate,
    'plan patches re-run full validation against the same frozen ref; dropping an obligation is always rejected', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d12, dec_forward_projection,
    'durability is forward projection, never compaction: append-only logs with monotone ids, cursor advances, boundary summaries carry the covered id range, prior ranges stay addressable', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d06, dec_multi_run_state,
    'no mode one-shots: every model/harness exchange re-projects current project state into the model context (direct recompiles per turn, experts retrieve before each proposal, subplans get current projections)', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d14, dec_gate_not_presence,
    'the design gate validates normative examples through real merged parsers; presence-only checks are false-green and removed', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(s00, dec_d6_11_plan_native_fold_in,
    'S0 adopts the rage/288 BASE with the D6-11 amendment folded in: sync_remote/1, run/1, index/1, delete/1 dispatch plan-natively through the canonical boundary via native_handlers and are excluded from expert mapping; edit/2 and create/2 remain write-expert-owned; the pre-adoption base_ref_resolvable pin is retired for the merged module', validated)).

:- assertz(spec_plan_refinement_kb:kb_open_question(d08, 'tdd_evidence pre-revision snapshot materialization cost on large repositories (checkout vs overlay) - measure in S6')).
:- assertz(spec_plan_refinement_kb:kb_open_question(d09, 'schema_ref registry governance for HTTP schemas (who registers, review path) - decide before S7')).
:- assertz(spec_plan_refinement_kb:kb_open_question(d09, 'bounded inline cap for HTTP response bodies (default 4096 bytes) - confirm with operators')).
:- assertz(spec_plan_refinement_kb:kb_open_question(d07, 'whether public_api_compatible needs per-language visibility rules beyond the 13-atom symbol_kind set - revisit after S2')).
