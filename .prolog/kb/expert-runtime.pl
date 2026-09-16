/* First canonical local expert substrate, issue #421. */

expert_runtime_surface(rlm_expert,
                       [registry_create, register, catalog, select, invoke, call]).
expert_runtime_boundary(registration, trusted_host_handler).
expert_runtime_boundary(goal_and_context, inert_data).
expert_runtime_boundary(selection, no_provider_call).
expert_runtime_boundary(invocation, explicit_capability_preflight).
expert_runtime_exclusion(plan_native, [sync_remote/1, run/1, index/1, delete/1]).
expert_runtime_limit(local_handler, inference_count(100000)).
expert_runtime_limit(local_handler, wall_seconds(5)).
expert_runtime_evidence(test('test/rlm_expert_test.pl'), issue(421)).
