:- module(rlm,
          [ rlm_version/1,
            rlm_ready/0,
            rlm_completion/4,
            rlm_completion_async/4,
            llm_query/3,
            llm_query_async/3,
            rlm_query/4,
            rlm_query_async/4,
            rlm_cancellation_token/1,
            rlm_cancel/1,
            default_completion_budget/1,
            default_context_policy/1,
            context_policy/2,
            token_count_text/3,
            context_section/5,
            context_pack/4,
            conversation_store_open/2,
            conversation_store_close/2,
            conversation_create/3,
            conversation_open/3,
            conversation_list/3,
            conversation_append/3,
            conversation_message/3,
            conversation_messages/4,
            conversation_search/4,
            conversation_stats/2,
            conversation_export/3,
            conversation_context_pack/3,
            conversation_token_ledger/3,
            conversation_turn/4,
            default_warm_policy/1,
            warm_context_schema/1,
            conversation_warm_derive/4,
            conversation_warm_publish/5,
            conversation_warm_list/4,
            conversation_warm_context_units/5,
            rlm_async_ready/0,
            rlm_async_submit/2,
            rlm_async_submit/3,
            rlm_future_status/2,
            rlm_future_await/2,
            rlm_future_await/3,
            rlm_future_cancel/2,
            rlm_future_destroy/1,
            rlm_future_all/2,
            rlm_future_then/3,
            rlm_future_on_complete/2,
            rlm_future_metadata/2,
            rlm_authority/2,
            rlm_set_authority_if_unset/3,
            rlm_set_authority/3,
            rlm_authority_narrow/3,
            rlm_authority_child/4,
            rlm_pending_approval/3,
            rlm_pending_approvals/2,
            rlm_pending_resolution_async/2,
            rlm_pending_resolution/2,
            rlm_authority_events/2,
            rlm_approve/2,
            rlm_deny/3,
            rlm_edit/3,
            model_complete_async/3,
            model_stream_async/4,
            chain_invoke_async/4,
            chain_stream_async/5,
            default_recursion_policy/1,
            recursion_route/3,
            recursion_candidates/3,
            recursion_guard/5,
            recursion_fingerprint/2,
            recursion_execute/4,
            recursion_execution_context/4,
            default_deep_experiment_policy/1,
            deep_experiment_run/2,
            deep_experiment_promotion/2,
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
            agent_spawn_async/5,
            agent_send/5,
            agent_send_async/5,
            agent_pump/4,
            agent_pump_async/4,
            agent_status/3,
            agent_children/3,
            agent_cancel/4,
            agent_cancel_async/4,
            agent_trace/2,
            agent_tool_handler/4,
            default_graph_options/1,
            graph_compile/4,
            graph_backend_open/2,
            graph_backend_close/1,
            graph_run/4,
            graph_run_async/4,
            graph_resume/6,
            graph_resume_async/6,
            graph_checkpoint/3,
            graph_history/3,
            graph_cancellation_token/1,
            graph_cancel/1,
            benchmark_case/7,
            benchmark_report/3,
            benchmark_budget_check/3,
            benchmark_json/2,
            benchmark_human_summary/2,
            demo/2,
            demo_all/1,
            demo_context/1,
            demo_tool/1,
            demo_recursion/1,
            demo_agent/1,
            demo_graph/1,
            demo_mcp/1,
            trace_envelope/3,
            trace_json/2,
            trace_jsonl/2,
            trace_write/5,
            trace_read/3,
            trace_view/2,
            trace_view_file/3,
            trace_encode/2,
            cli_run/2,
            cli_usage/1
          ]).

/** <module> prolog-rlm entrypoint

Load this module to initialize the public runtime namespaces.

Depth greater than one is an experimental public-API boundary. Supplying a
larger recursion budget does not by itself enable it: callers must also pass
`experimental_deep_recursion(true)`. That flag is only an opt-in; it grants no
capabilities and does not widen any normal budget.

Latency-bearing completion/query, provider/chain, tool/MCP, agent, and graph
surfaces follow one direction: canonical execute semantics -> async Future ->
sync await. The recursion gate is evaluated before completion scheduling, and
even a rejected completion request is represented by a Future on the async
surface. No public async task calls its public synchronous predicate, and
internal canonical async work uses execute ABIs instead of nested Future waits.

Authority setters and approve/deny/edit are trusted host/library APIs. They are
ordinary immediate state transitions, not model-callable tools. Human approval
latency is represented by a deferred pending-operation Future; no shared
`rlm_async` worker waits for a person.
*/

:- use_module(rlm_chain).
:- use_module(rlm_context).
:- use_module(rlm_plan).
:- use_module(rlm_tool).
:- use_module(rlm_async,
              [ rlm_async_ready/0,
                rlm_async_submit/2,
                rlm_async_submit/3,
                rlm_future_status/2,
                rlm_future_await/2,
                rlm_future_await/3,
                rlm_future_cancel/2,
                rlm_future_destroy/1,
                rlm_future_all/2,
                rlm_future_then/3,
                rlm_future_on_complete/2,
                rlm_future_metadata/2
              ]).
:- use_module(rlm_authority,
              [ rlm_authority/2,
                rlm_set_authority_if_unset/3,
                rlm_set_authority/3,
                rlm_authority_narrow/3,
                rlm_authority_child/4,
                rlm_pending_approval/3,
                rlm_pending_approvals/2,
                rlm_pending_resolution_async/2,
                rlm_pending_resolution/2,
                rlm_authority_events/2,
                rlm_approve/2,
                rlm_deny/3,
                rlm_edit/3
              ]).
:- use_module(rlm_completion,
              [ llm_query/3,
                llm_query_async/3,
                rlm_cancellation_token/1,
                rlm_cancel/1,
                default_completion_budget/1
              ]).
:- use_module(rlm_context_budget,
              [ rlm_context_budget_ready/0,
                default_context_policy/1,
                context_policy/2,
                token_count_text/3,
                context_section/5,
                context_pack/4
              ]).
:- use_module(rlm_conversation,
              [ rlm_conversation_ready/0,
                conversation_store_open/2,
                conversation_store_close/2,
                conversation_create/3,
                conversation_open/3,
                conversation_list/3,
                conversation_append/3,
                conversation_message/3,
                conversation_messages/4,
                conversation_search/4,
                conversation_stats/2,
                conversation_export/3,
                conversation_context_pack/3,
                conversation_token_ledger/3,
                conversation_turn/4
              ]).
:- use_module(rlm_conversation_warm,
              [ rlm_conversation_warm_ready/0,
                default_warm_policy/1,
                warm_context_schema/1,
                conversation_warm_derive/4,
                conversation_warm_publish/5,
                conversation_warm_list/4,
                conversation_warm_context_units/5
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
:- use_module(rlm_deep_experiment,
              [ rlm_deep_experiment_ready/0,
                default_deep_experiment_policy/1,
                deep_experiment_run/2,
                deep_experiment_promotion/2
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
                agent_spawn_async/5,
                agent_send/5,
                agent_send_async/5,
                agent_pump/4,
                agent_pump_async/4,
                agent_status/3,
                agent_children/3,
                agent_cancel/4,
                agent_cancel_async/4,
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
                graph_run_async/4,
                graph_resume/6,
                graph_resume_async/6,
                graph_checkpoint/3,
                graph_history/3,
                graph_cancellation_token/1,
                graph_cancel/1
              ]).
:- use_module(rlm_benchmark,
              [ rlm_benchmark_ready/0,
                benchmark_case/7,
                benchmark_report/3,
                benchmark_budget_check/3,
                benchmark_json/2,
                benchmark_human_summary/2
              ]).
:- use_module(rlm_demo,
              [ rlm_demo_ready/0,
                demo/2,
                demo_all/1,
                demo_context/1,
                demo_tool/1,
                demo_recursion/1,
                demo_agent/1,
                demo_graph/1,
                demo_mcp/1
              ]).
:- use_module(rlm_trace,
              [ rlm_trace_ready/0,
                trace_envelope/3,
                trace_json/2,
                trace_jsonl/2,
                trace_write/5,
                trace_read/3,
                trace_view/2,
                trace_view_file/3,
                trace_encode/2
              ]).
:- use_module(rlm_cli,
              [ rlm_cli_ready/0,
                cli_run/2,
                cli_usage/1
              ]).
:- use_module(rlm_mcp).
:- use_module(rlm_mcp_server, []).
:- use_module(rlm_mcp_tool, []).

rlm_version('0.1.0-dev').

rlm_ready :-
    rlm_chain:rlm_chain_ready,
    rlm_context:context_backend(memory, _),
    rlm_plan:default_plan_budget(_),
    rlm_tool:capabilities_normalize([], ok([])),
    rlm_async:rlm_async_ready,
    rlm_authority:rlm_authority(runtime(ready_probe), approve_diff),
    rlm_completion:default_completion_budget(_),
    rlm_context_budget:rlm_context_budget_ready,
    rlm_conversation:rlm_conversation_ready,
    rlm_conversation_warm:rlm_conversation_warm_ready,
    rlm_recursion_policy:rlm_recursion_policy_ready,
    rlm_recursion_runtime:rlm_recursion_runtime_ready,
    rlm_deep_experiment:rlm_deep_experiment_ready,
    rlm_outcome:default_outcome_limits(_),
    rlm_artifact:rlm_artifact_ready,
    rlm_artifact_agent:rlm_artifact_agent_ready,
    rlm_artifact_graph:rlm_artifact_graph_ready,
    rlm_agent:rlm_agent_ready,
    rlm_graph:rlm_graph_ready,
    rlm_benchmark:rlm_benchmark_ready,
    rlm_demo:rlm_demo_ready,
    rlm_trace:rlm_trace_ready,
    rlm_cli:rlm_cli_ready,
    rlm_mcp:rlm_mcp_ready,
    rlm_mcp_server:mcp_server_definitions(_).

/* Public recursion gate -------------------------------------------------- */

rlm_completion_async(Query, Context, Options, Future) :-
    public_deep_recursion_gate(Options, Gate),
    public_completion_async_after_gate(Gate,
                                       Query,
                                       Context,
                                       Options,
                                       Future).

public_completion_async_after_gate(ok, Query, Context, Options, Future) :-
    !,
    rlm_completion:rlm_completion_async(Query, Context, Options, Future).
public_completion_async_after_gate(error(Error), _, _, _, Future) :-
    rlm_async:rlm_async_submit(rlm:public_gate_error(Error),
                               async_metadata{operation:completion_gate},
                               Future).

rlm_completion(Query, Context, Options, Outcome) :-
    rlm_completion_async(Query, Context, Options, Future),
    await_owned_future(Future, Outcome).

rlm_query_async(Query, Context, Options, Future) :-
    public_deep_recursion_gate(Options, Gate),
    public_query_async_after_gate(Gate,
                                  Query,
                                  Context,
                                  Options,
                                  Future).

public_query_async_after_gate(ok, Query, Context, Options, Future) :-
    !,
    rlm_completion:rlm_query_async(Query, Context, Options, Future).
public_query_async_after_gate(error(Error), _, _, _, Future) :-
    rlm_async:rlm_async_submit(rlm:public_gate_error(Error),
                               async_metadata{operation:query_gate},
                               Future).

rlm_query(Query, Context, Options, Outcome) :-
    rlm_query_async(Query, Context, Options, Future),
    await_owned_future(Future, Outcome).

public_gate_error(Error, error(Error)).

await_owned_future(Future, Outcome) :-
    setup_call_cleanup(
        true,
        rlm_async:rlm_future_await(Future, Outcome),
        rlm_async:rlm_future_destroy(Future)).

public_deep_recursion_gate(Options, Outcome) :-
    (   is_list(Options),
        requested_public_depth(Options, RequestedDepth),
        RequestedDepth > 1,
        \+ memberchk(experimental_deep_recursion(true), Options)
    ->  Outcome = error(completion_error{
                            phase:validate,
                            kind:experimental_deep_recursion_required,
                            requested_depth:RequestedDepth,
                            message:"depth >1 is experimental; pass experimental_deep_recursion(true) explicitly"
                        })
    ;   Outcome = ok
    ).

requested_public_depth(Options, RequestedDepth) :-
    findall(Depth,
            ( member(Option, Options),
              public_depth_option(Option, Depth) ),
            Depths),
    max_list([1|Depths], RequestedDepth).

public_depth_option(depth(Depth), Depth) :-
    integer(Depth),
    Depth >= 0.
public_depth_option(budget(Budget), Depth) :-
    is_dict(Budget),
    get_dict(max_recursion_depth, Budget, Depth),
    integer(Depth),
    Depth >= 0.