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
            rlm_async_ready/0,
            rlm_async_submit/2,
            rlm_future_status/2,
            rlm_future_await/2,
            rlm_future_await/3,
            rlm_future_cancel/2,
            rlm_future_destroy/1,
            rlm_future_all/2,
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

Depth greater than one is an experimental public-API boundary.  Supplying a
larger recursion budget does not by itself enable it: callers must also pass
`experimental_deep_recursion(true)`.  That flag is only an opt-in; it grants no
capabilities and does not widen any normal budget.
*/

:- use_module(rlm_chain).
:- use_module(rlm_chain_async,
              [ model_complete_async/3,
                model_stream_async/4,
                chain_invoke_async/4,
                chain_stream_async/5
              ]).
:- use_module(rlm_context).
:- use_module(rlm_plan).
:- use_module(rlm_tool).
:- use_module(rlm_async,
              [ rlm_async_ready/0,
                rlm_async_submit/2,
                rlm_future_status/2,
                rlm_future_await/2,
                rlm_future_await/3,
                rlm_future_cancel/2,
                rlm_future_destroy/1,
                rlm_future_all/2
              ]).
:- use_module(rlm_completion,
              [ llm_query/3,
                rlm_cancellation_token/1,
                rlm_cancel/1,
                default_completion_budget/1
              ]).
:- use_module(rlm_completion_async,
              [ llm_query_async/3
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
                agent_send/5,
                agent_pump/4,
                agent_status/3,
                agent_children/3,
                agent_cancel/4,
                agent_trace/2,
                agent_tool_handler/4
              ]).
:- use_module(rlm_agent_async,
              [ agent_spawn_async/5,
                agent_send_async/5,
                agent_pump_async/4,
                agent_cancel_async/4
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
:- use_module(rlm_graph_async,
              [ graph_run_async/4,
                graph_resume_async/6
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

rlm_version('0.1.0-dev').

rlm_ready :-
    rlm_chain:rlm_chain_ready,
    rlm_context:context_backend(memory, _),
    rlm_plan:default_plan_budget(_),
    rlm_tool:capabilities_normalize([], ok([])),
    rlm_async:rlm_async_ready,
    rlm_completion:default_completion_budget(_),
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
    rlm_mcp:rlm_mcp_ready.

/* Public recursion gate -------------------------------------------------- */

rlm_completion(Query, Context, Options, Outcome) :-
    public_deep_recursion_gate(Options, Gate),
    (   Gate == ok
    ->  rlm_completion:rlm_completion(Query, Context, Options, Outcome)
    ;   Gate = error(Error),
        Outcome = error(Error)
    ).

rlm_completion_async(Query, Context, Options, Future) :-
    rlm_async:rlm_async_submit(
        rlm:public_completion_async_task(Query, Context, Options),
        Future).

public_completion_async_task(Query, Context, Options, Outcome) :-
    rlm_completion(Query, Context, Options, Outcome).

rlm_query(Query, Context, Options, Outcome) :-
    public_deep_recursion_gate(Options, Gate),
    (   Gate == ok
    ->  rlm_completion:rlm_query(Query, Context, Options, Outcome)
    ;   Gate = error(Error),
        Outcome = error(Error)
    ).

rlm_query_async(Query, Context, Options, Future) :-
    rlm_async:rlm_async_submit(
        rlm:public_query_async_task(Query, Context, Options),
        Future).

public_query_async_task(Query, Context, Options, Outcome) :-
    rlm_query(Query, Context, Options, Outcome).

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
