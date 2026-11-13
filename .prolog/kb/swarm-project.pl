/* User-scoped swarm project; proposed decomposition, not design approval.
   Source: nsaspy/prolog-rlm#574 and OpenCode ses_e2d8a4662ffeWFuIrPvEK6hmdx.
   User requested durable Prolog TODOs and a separate continuing project tree.
*/

swarm_project_goal(574, configurable_rlm_swarm_and_pswarm_then_full_herdr_parity).
swarm_project_source(574, 'https://git.starintel.actor/nsaspy/prolog-rlm/issues/574').
swarm_project_scope(574, branch('issue-574')).
swarm_worktree_retention('/home/unseen/git/worktrees/prolog-rlm-issue-574', explicit_user_approval_required_for_removal).
swarm_worktree_retention_applies(574, even_after_merge_or_task_completion).
swarm_project_boundary(574, reuse_canonical_runtime_not_second_scheduler).
swarm_project_boundary(574, runtime_core_first_client_parity_remains_required).
swarm_project_boundary(574, novelty_research_after_verified_base_core_only).
swarm_project_boundary(574, explicit_research_and_design_approvals_not_inferred).
swarm_project_boundary(574, upstream_tui_cli_parser_audit_not_default_next_work).
swarm_project_boundary(574, expert_definitions_remain_dotfiles_owned).

% Estimated coherent core implementation slices, pending design review.
% These are proposed deliverables, not assertions that behavior exists.
swarm_core_slice(1, configuration_and_cli, proposed).
swarm_core_slice(2, shared_cost_request_and_spend_rate_admission, proposed).
swarm_core_slice(3, scoped_identity_and_discovery, proposed).
swarm_core_slice(4, peer_and_group_messaging, proposed).
swarm_core_slice(5, durable_searchable_message_board, proposed).
swarm_core_slice(6, gated_domain_extensible_shared_kb, proposed).
swarm_core_slice(7, policy_gated_peer_and_child_creation, proposed).
swarm_core_slice(8, adaptive_recursive_delegation, proposed).
swarm_core_slice(9, guardrails_and_host_authority_integration, proposed).
swarm_core_slice(10, task_lifecycle_and_evidence_backed_acceptance, proposed).
swarm_core_slice(11, durable_service_stop_drain_restart_and_resume, proposed).
swarm_core_slice(12, core_conformance_failure_fixtures_and_packaging, proposed).

swarm_slice_dependency(2, 1).
swarm_slice_dependency(3, 1).
swarm_slice_dependency(4, 3).
swarm_slice_dependency(5, 3).
swarm_slice_dependency(6, 3).
swarm_slice_dependency(7, 2).
swarm_slice_dependency(7, 3).
swarm_slice_dependency(8, 7).
swarm_slice_dependency(9, 1).
swarm_slice_dependency(10, 7).
swarm_slice_dependency(10, 9).
swarm_slice_dependency(11, 2).
swarm_slice_dependency(11, 4).
swarm_slice_dependency(11, 5).
swarm_slice_dependency(11, 6).
swarm_slice_dependency(11, 8).
swarm_slice_dependency(11, 10).
swarm_slice_dependency(12, 11).

swarm_core_slice_count(Count) :-
    findall(Id, swarm_core_slice(Id, _, _), Ids),
    length(Ids, Count).

% Required follow-on scope; not yet honestly sized into implementation slices.
swarm_follow_on_scope(full_herdr_host_pty_and_remote_parity, not_yet_sized).
swarm_follow_on_scope(web_and_agentprolog_console, not_yet_sized).
swarm_follow_on_scope(native_desktop_and_mobile_clients, not_yet_sized).
swarm_follow_on_scope(post_core_differentiated_research, gated_on_verified_core).
