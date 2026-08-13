:- module(rlm,
          [ rlm_version/1,
            rlm_ready/0,
            rlm_completion/4,
            llm_query/3,
            rlm_query/4,
            rlm_cancellation_token/1,
            rlm_cancel/1,
            default_completion_budget/1,
            default_recursion_policy/1,
            recursion_route/3,
            recursion_candidates/3,
            recursion_guard/5,
            recursion_fingerprint/2,
            recursion_execute/4,
            recursion_execution_context/4,
            plan_outcome/5,
            goal_outcome/3,
            plan_inspect/4,
            predicate_inspect/2,
            outcome_trace/3,
            plan_repair/6,
            default_outcome_limits/1,
            artifact_store_open/2,
            artifact_store_close/2,
            artifact_put/7,
            artifact_get/3,
            artifact_latest/4,
            artifact_list/4,
            artifact_ref_status/3,
            artifact_context_pack/4,
            artifact_context_refs/4,
            artifact_trace/3,
            artifact_namespace/2,
            agent_artifact_publish/8,
            agent_artifact_refs/3,
            agent_artifact_context/5,
            artifact_graph_schema_field/1,
            graph_artifact_publish/7,
            graph_artifact_context/5,
            default_agent_options/1,
            agent_runtime_create/2,
            agent_runtime_destroy/1,
            agent_runtime_status/2,
            agent_spawn/5,
            agent_send/5,
            agent_pump/4,
            agent_status/3,
            agent_children/3,
            agent_cancel/4,
            agent_trace/2,
            agent_tool_handler/4,
            default_graph_options/1,
            graph_compile/4,
            graph_backend_open/2,
            graph_backend_close/1,
            graph_run/4,
            graph_resume/6,
            graph_checkpoint/3,
            graph_history/3,
            graph_cancellation_token/1,
            graph_cancel/1
          ]).

/** <module> prolog-rlm entrypoint

Load this module to initialize the public runtime namespaces.
*/

:- use_module(rlm_chain).
:- use_module(rlm_context).
:- use_module(rlm_plan).
:- use_module(rlm_tool).
:- use_module(rlm_completion,
              [ rlm_completion/4,
                llm_query/3,
                rlm_query/4,
                rlm_cancellation_token/1,
                rlm_cancel/1,
                default_completion_budget/1
              ]).
:- use_module(rlm_recursion_policy,
              [ rlm_recursion_policy_ready/0,
                default_recursion_policy/1,
                recursion_route/3,
                recursion_candidates/3,
                recursion_guard/5,
                recursion_fingerprint/2
              ]).
:- use_module(rlm_recursion_runtime,
              [ rlm_recursion_runtime_ready/0,
                recursion_execute/4,
                recursion_execution_context/4
              ]).
:- use_module(rlm_outcome,
              [ plan_outcome/5,
                goal_outcome/3,
                plan_inspect/4,
                predicate_inspect/2,
                outcome_trace/3,
                plan_repair/6,
                default_outcome_limits/1
              ]).
:- use_module(rlm_artifact,
              [ rlm_artifact_ready/0,
                artifact_store_open/2,
                artifact_store_close/2,
                artifact_put/7,
                artifact_get/3,
                artifact_latest/4,
                artifact_list/4,
                artifact_ref_status/3,
                artifact_context_pack/4,
                artifact_context_refs/4,
                artifact_trace/3,
                artifact_namespace/2
              ]).
:- use_module(rlm_artifact_agent,
              [ rlm_artifact_agent_ready/0,
                agent_artifact_publish/8,
                agent_artifact_refs/3,
                agent_artifact_context/5
              ]).
:- use_module(rlm_artifact_graph,
              [ rlm_artifact_graph_ready/0,
                artifact_graph_schema_field/1,
                graph_artifact_publish/7,
                graph_artifact_context/5
              ]).
:- use_module(rlm_agent,
              [ rlm_agent_ready/0,
                default_agent_options/1,
                agent_runtime_create/2,
                agent_runtime_destroy/1,
                agent_runtime_status/2,
                agent_spawn/5,
                agent_send/5,
                agent_pump/4,
                agent_status/3,
                agent_children/3,
                agent_cancel/4,
                agent_trace/2,
                agent_tool_handler/4
              ]).
:- use_module(rlm_graph,
              [ rlm_graph_ready/0,
                default_graph_options/1,
                graph_compile/4,
                graph_backend_open/2,
                graph_backend_close/1,
                graph_run/4,
                graph_resume/6,
                graph_checkpoint/3,
                graph_history/3,
                graph_cancellation_token/1,
                graph_cancel/1
              ]).
:- use_module(rlm_mcp).

rlm_version('0.1.0-dev').

rlm_ready :-
    rlm_chain:rlm_chain_ready,
    rlm_context:context_backend(memory, _),
    rlm_plan:default_plan_budget(_),
    rlm_tool:capabilities_normalize([], ok([])),
    rlm_completion:default_completion_budget(_),
    rlm_recursion_policy:rlm_recursion_policy_ready,
    rlm_recursion_runtime:rlm_recursion_runtime_ready,
    rlm_outcome:default_outcome_limits(_),
    rlm_artifact:rlm_artifact_ready,
    rlm_artifact_agent:rlm_artifact_agent_ready,
    rlm_artifact_graph:rlm_artifact_graph_ready,
    rlm_agent:rlm_agent_ready,
    rlm_graph:rlm_graph_ready,
    rlm_mcp:rlm_mcp_ready.
