/* Persisted state for the SPEC/VALIDATE/PLAN research/design KB.
 * Written by spec_plan_refinement_kb update predicates; regenerable.
 *
 * Design-pass tasks d01..d14 are done WITH completion evidence (design
 * document section + design-gate check id + merged/unmerged source).
 * Implementation slices s00..s11 remain pending until their slices land.
 * A bare status(done) with no evidence/validated decision is a gate
 * violation (kb_violation/1), so this file must always pair them.
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

:- assertz(spec_plan_refinement_kb:kb_evidence(d01, 'design:spec-plan-authority#s2-inventory')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d02, 'design:spec-plan-authority#s3-canonical-spec-language')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d02, 'gate:spec_reject_spec2')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d02, 'source:prolog/rlm_spec_lang.pl')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d03, 'design:spec-plan-authority#s5-reference-grammar')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d03, 'gate:plan_reject_bad_ref')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d03, 'source:rage288:prolog/rlm_plan_graph.pl')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d04, 'design:spec-plan-authority#s6-canonical-plan-language')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d04, 'gate:plan_base_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d04, 'gate:plan_reject_unknown_op')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d04, 'gate:plan_reject_bad_arity')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d05, 'design:spec-plan-authority#s8-3-dataflow')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d05, 'gate:d6_dataflow_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d05, 'gate:d6_dangling_rejected')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d05, 'source:prolog/rlm_plan.pl:resolve_expr')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d06, 'design:spec-plan-authority#s8-experts-and-loop')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d06, 'gate:edit_action_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d06, 'gate:expert_contract_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d07, 'design:spec-plan-authority#s4-spec-domains')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d07, 'gate:spec_compile_domain_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d08, 'design:spec-plan-authority#s9-tdd-evidence')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d08, 'gate:tdd_red_green')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d08, 'gate:tdd_not_red_rejected')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d09, 'design:spec-plan-authority#s10-http-model')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d09, 'gate:http_schema_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d09, 'gate:http_malformed_rejected')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d10, 'design:spec-plan-authority#s10-3-network-authority')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d10, 'gate:capability_unchanged')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d10, 'gate:http_observe_denied_without_cap')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d11, 'design:spec-plan-authority#s11-plan-spec-compatibility')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d11, 'gate:replan_drop_rejected')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d11, 'gate:replan_preserve_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d11, 'gate:spec_compat_foreign_ref')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d12, 'design:spec-plan-authority#s12-durability')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d12, 'gate:resume_snapshot_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d12, 'gate:kb_discipline_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d13, 'design:spec-plan-authority#s13-implementation-dag')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d13, 'gate:dag_ok')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d14, 'design:spec-plan-authority#s14-design-gate')).
:- assertz(spec_plan_refinement_kb:kb_evidence(d14, 'gate:design_gate_passes')).

:- assertz(spec_plan_refinement_kb:kb_decision(d02, dec_no_spec2,
    'Keep merged spec(Forms) root; spec identity belongs to frozen_spec.ref only; no spec(Id,Forms)', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d04, dec_plan_base,
    'Adopt rage/288 closed op vocabulary and ready-step executor as PLAN BASE; reconciliation slice owns every D6 delta', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d04, dec_rename_not_op,
    'rename is an internal write-engine primitive, not a plan-visible op', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d04, dec_generate_not_op,
    'model generation is owned by expert inner loops; no plan-visible generate op', validated)).
:- assertz(spec_plan_refinement_kb:kb_decision(d05, dec_admission_binding,
    'expr leaves resolve at step admission from inputs plus dependency-closure step binds; desugared rlm_plan AST unchanged', validated)).
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

:- assertz(spec_plan_refinement_kb:kb_open_question(d08, 'tdd_evidence pre-revision snapshot materialization cost on large repositories (checkout vs overlay) - measure in S6')).
:- assertz(spec_plan_refinement_kb:kb_open_question(d09, 'schema_ref registry governance for HTTP schemas (who registers, review path) - decide before S7')).
:- assertz(spec_plan_refinement_kb:kb_open_question(d09, 'bounded inline cap for HTTP response bodies (default 4096 bytes) - confirm with operators')).
:- assertz(spec_plan_refinement_kb:kb_open_question(d07, 'whether public_api_compatible needs per-language visibility rules beyond the 13-atom symbol_kind set - revisit after S2')).
