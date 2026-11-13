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

% Base-core readiness audit at HEAD ea137b61a91101444323b8f3cd9cd6e7fad0f7a8.
% Source: read-only subagent audit 2026-11-13 (OpenCode session) of the
% issue-574 worktree. Classifications: absent | partial_substrate | present.
% rlm_swarm and pswarm do not exist anywhere in prolog/ bin/ docs/.
swarm_readiness(1, configuration_and_cli, partial_substrate, 'rlm_cli.pl hand-rolled parser; no shared config schema; required swarm flags -c -n --min-agents --max-agents --rate --spend-rate --kb --enable-gaurdrail --web --console --backround --deamon all absent').
swarm_readiness(2, shared_cost_request_and_spend_rate_admission, partial_substrate, 'rlm_completion.pl budget_usage_check/3 enforces per-run max_cost_usd (default 0.25); no request rate limiter; no time-based spend quota; no cross-agent shared ledger').
swarm_readiness(3, scoped_identity_and_discovery, absent, 'agent ids are gensym(agent_) scoped to one rlm_agent runtime; no cross-runtime registry, incarnation or peer concept').
swarm_readiness(4, peer_and_group_messaging, partial_substrate, 'rlm_agent.pl agent_send/5 + bounded mailboxes with mailbox_full backpressure; single runtime only; no groups, broadcast, cross-runtime peers or sender authentication').
swarm_readiness(5, durable_searchable_message_board, absent, 'no board module; closest durable-searchable stores are rlm_conversation_persist.pl and rlm_artifact_persist.pl (library(persistency) pattern)').
swarm_readiness(6, gated_domain_extensible_shared_kb, absent, 'no shared mutable fact KB with admission policy; adjacent inert substrates: rlm_assertion.pl closed registry, rlm_strange_loop.pl snapshot discipline, rlm_tool.pl capability gating').
swarm_readiness(7, policy_gated_peer_and_child_creation, partial_substrate, 'creation gating strong in rlm_agent.pl spawn_locked/7 (max_agents, authority_widening_denied), rlm_subagent.pl and rlm_delegation_runtime.pl; shared cross-agent accounting absent').
swarm_readiness(8, adaptive_recursive_delegation, partial_substrate, 'rlm_recursion_policy.pl + rlm_recursion_runtime.pl route direct/deterministic/cheap/recursive with depth+cost traces; depth-aware recursive subagent binding explicitly fails closed today').
swarm_readiness(9, guardrails_and_host_authority_integration, absent, 'no expert-KB guardrail module; authority tiers approve_diff/allow_once/allow_session/dangerous live in rlm_authority.pl').
swarm_readiness(10, task_lifecycle_and_evidence_backed_acceptance, partial_substrate, 'rlm_evidence.pl policy vocabulary, rlm_verify.pl spec_verify/4, rlm_result_accept.pl acceptance gate (not wired into every supervised-child trace yet)').
swarm_readiness(11, durable_service_stop_drain_restart_and_resume, partial_substrate, 'restart/resume coverage strong (effect/artifact/graph restart phases, graph_resume/6); drain/quiesce API absent from rlm_async.pl; agent_runtime_destroy/1 is immediate destroy').
swarm_readiness(12, core_conformance_failure_fixtures_and_packaging, absent, 'no swarm conformance fixtures; existing deterministic runner/test corpus is substrate-only').
swarm_scheduler_invariant(rlm_async_is_only_scheduler, confirmed, 'raw thread primitives only in rlm_async.pl worker pool, rlm_agent.pl bounded per-runtime pool + mailboxes, rlm_authority.pl one-slot approval gate; all higher modules route through rlm_async_submit').

% Required follow-on scope; not yet honestly sized into implementation slices.

swarm_follow_on_scope(full_herdr_host_pty_and_remote_parity, not_yet_sized).
swarm_follow_on_scope(web_and_agentprolog_console, not_yet_sized).
swarm_follow_on_scope(native_desktop_and_mobile_clients, not_yet_sized).
swarm_follow_on_scope(post_core_differentiated_research, gated_on_verified_core).

% Destination decision, user-decided 2026-11-13 (supersedes the earlier
% separate-fork idea): the swarm implementation lives in nsaspy/prolog-rlm
% itself, reusing the retained issue-574 worktree checkout; project name
% rlm-swarm. A long-lived feat/rlm-swarm branch is the integration branch:
% slice PRs base onto it, and it merges into main once the core is done.
% No separate starintel-labs fork is created.
swarm_destination(574, repo, 'nsaspy/prolog-rlm').
swarm_destination(574, same_checkout, '/home/unseen/git/worktrees/prolog-rlm-issue-574').
swarm_destination(574, no_separate_fork, confirmed_by_user_2026_11_13).
swarm_project_name(574, 'rlm-swarm').
swarm_branch_strategy(574, integration_branch('feat/rlm-swarm')).
swarm_branch_strategy(574, slice_pr_base('feat/rlm-swarm')).
swarm_branch_strategy(574, merge_to_main_only_after_core_complete).

