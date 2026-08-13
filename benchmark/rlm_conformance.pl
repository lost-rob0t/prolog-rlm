:- module(rlm_conformance,
          [ deterministic_conformance/1,
            deterministic_cases/1
          ]).

/** <module> Deterministic cross-runtime conformance suite

Each case executes a production subsystem, converts native traces/results into
rlm_benchmark metrics, and reports failures as data. Fixed budgets are applied
after observation so CI receives a complete report even when one case regresses.
*/

:- use_module('../prolog/rlm_benchmark').
:- use_module('../prolog/rlm_context').
:- use_module('../prolog/rlm_recursion_runtime').
:- use_module('../prolog/rlm_plan').
:- use_module('../prolog/rlm_agent').
:- use_module('../prolog/rlm_graph').
:- use_module('../prolog/rlm_mcp').
:- use_module('../prolog/rlm_mcp_v2025_11_25').
:- use_module('../prolog/rlm_mcp_v2026_07_28').

/* Public suite ----------------------------------------------------------- */

deterministic_conformance(Report) :-
    deterministic_cases(Cases0),
    maplist(apply_case_budget, Cases0, Cases),
    benchmark_report(deterministic, Cases, Report).

deterministic_cases(Cases) :-
    CasePredicates = [
        context_peek_case,
        context_search_case,
        context_partition_case,
        context_map_case,
        context_reduce_case,
        direct_depth_0_case,
        rlm_depth_1_case,
        rlm_depth_2_case,
        structured_plan_rejection_case,
        agent_backpressure_case,
        agent_parent_cancel_case,
        agent_logical_fanout_case,
        graph_checkpoint_resume_case,
        mcp_2025_adapter_case,
        mcp_2026_adapter_case,
        mcp_dual_facade_case
    ],
    maplist(run_named_case, CasePredicates, Cases).

run_named_case(Predicate, Case) :-
    case_identity(Predicate, Name, Category),
    safe_case(Name, Category, Predicate, Case).

safe_case(Name, Category, Predicate, Case) :-
    get_time(Start),
    catch((   call(Predicate, Quality, Metrics0, Details0)
          ->  Observation = success(Quality, Metrics0, Details0)
          ;   Observation = failed
          ),
          Exception,
          Observation = exception(Exception)),
    get_time(End),
    ElapsedMs is max(0, round((End-Start)*1000)),
    observation_case(Observation,
                     Name,
                     Category,
                     ElapsedMs,
                     Case).

observation_case(success(Quality, Metrics0, Details),
                 Name,
                 Category,
                 ElapsedMs,
                 Case) :-
    ensure_latency_metric(Metrics0, ElapsedMs, Metrics),
    benchmark_case(Name,
                   Category,
                   pass,
                   Quality,
                   Metrics,
                   Details,
                   Case).
observation_case(failed, Name, Category, ElapsedMs, Case) :-
    benchmark_case(Name,
                   Category,
                   fail,
                   0.0,
                   _{latency_ms:ElapsedMs},
                   _{reason:fixture_failed_without_exception},
                   Case).
observation_case(exception(Exception), Name, Category, ElapsedMs, Case) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    benchmark_case(Name,
                   Category,
                   fail,
                   0.0,
                   _{latency_ms:ElapsedMs},
                   _{reason:exception, exception:Safe},
                   Case).

ensure_latency_metric(Metrics0, _, Metrics0) :-
    get_dict(latency_ms, Metrics0, _),
    !.
ensure_latency_metric(Metrics0, ElapsedMs, Metrics) :-
    put_dict(latency_ms, Metrics0, ElapsedMs, Metrics).

case_identity(context_peek_case, context_peek, context).
case_identity(context_search_case, context_search, context).
case_identity(context_partition_case, context_partition, context).
case_identity(context_map_case, context_map, context).
case_identity(context_reduce_case, context_reduce, context).
case_identity(direct_depth_0_case, direct_depth_0, recursion).
case_identity(rlm_depth_1_case, rlm_depth_1, recursion).
case_identity(rlm_depth_2_case, rlm_depth_2, recursion).
case_identity(structured_plan_rejection_case,
              structured_plan_rejection,
              structured_plan).
case_identity(agent_backpressure_case, agent_backpressure, agent).
case_identity(agent_parent_cancel_case, agent_parent_cancel, agent).
case_identity(agent_logical_fanout_case, agent_logical_fanout, agent).
case_identity(graph_checkpoint_resume_case, graph_checkpoint_resume, graph).
case_identity(mcp_2025_adapter_case, mcp_2025_adapter, mcp).
case_identity(mcp_2026_adapter_case, mcp_2026_adapter, mcp).
case_identity(mcp_dual_facade_case, mcp_dual_facade, mcp).

/* Context cases --------------------------------------------------------- */

context_peek_case(1.0, Metrics, Details) :-
    make_long_text(Text),
    with_text_context(Text,
                      context_peek_observation,
                      Metrics,
                      Details).

context_peek_observation(Handle, Metrics, Details) :-
    context_peek(Handle, head(80), [max_bytes(256)], ok(Result)),
    ensure(nonempty_string(Result.value), empty_peek_result),
    context_result_metrics(Result, Metrics),
    Details = _{operation:peek,
                truncated:Result.truncated,
                native_trace:Result.trace}.

context_search_case(1.0, Metrics, Details) :-
    make_long_text(Text),
    with_text_context(Text,
                      context_search_observation,
                      Metrics,
                      Details).

context_search_observation(Handle, Metrics, Details) :-
    context_search(Handle,
                   "needle",
                   [max_results(5), max_bytes(2048)],
                   ok(Result)),
    length(Result.value, Count),
    ensure(Count =:= 5, search_result_count(Count)),
    context_result_metrics(Result, Metrics),
    Details = _{operation:search,
                matches:Count,
                truncated:Result.truncated,
                native_trace:Result.trace}.

context_partition_case(1.0, Metrics, Details) :-
    make_long_text(Text),
    with_text_context(Text,
                      context_partition_observation,
                      Metrics,
                      Details).

context_partition_observation(Handle, Metrics, Details) :-
    context_partition(Handle,
                      fixed(80),
                      [max_results(3), max_bytes(512)],
                      ok(Result)),
    length(Result.value, Count),
    ensure(Count =:= 3, partition_count(Count)),
    context_result_metrics(Result, Metrics),
    Details = _{operation:partition,
                partitions:Count,
                truncated:Result.truncated,
                native_trace:Result.trace}.

context_map_case(1.0, Metrics, Details) :-
    Terms = [alpha(1), beta(2), gamma(3), delta(4)],
    with_term_context(Terms,
                      context_map_observation,
                      Metrics,
                      Details).

context_map_observation(Handle, Metrics, Details) :-
    context_map(Handle, uppercase, [max_results(4)], ok(Result)),
    ensure(Result.value == ["ALPHA(1)",
                            "BETA(2)",
                            "GAMMA(3)",
                            "DELTA(4)"],
           unexpected_map_result(Result.value)),
    context_result_metrics(Result, Metrics),
    Details = _{operation:map,
                result_count:4,
                native_trace:Result.trace}.

context_reduce_case(1.0, Metrics, Details) :-
    Terms = [alpha(1), beta(2), gamma(3), delta(4)],
    with_term_context(Terms,
                      context_reduce_observation,
                      Metrics,
                      Details).

context_reduce_observation(Handle, Metrics, Details) :-
    context_reduce(Handle, count, [], ok(Result)),
    ensure(Result.value =:= 4, unexpected_reduce_result(Result.value)),
    context_result_metrics(Result, Metrics),
    Details = _{operation:reduce,
                value:Result.value,
                native_trace:Result.trace}.

with_text_context(Text, Goal, Metrics, Details) :-
    context_register(text(Text), [], ok(Ref)),
    setup_call_cleanup(
        true,
        call(Goal, Ref.handle, Metrics, Details),
        context_delete(Ref.handle, _)).

with_term_context(Terms, Goal, Metrics, Details) :-
    context_register(terms(Terms), [], ok(Ref)),
    setup_call_cleanup(
        true,
        call(Goal, Ref.handle, Metrics, Details),
        context_delete(Ref.handle, _)).

context_result_metrics(Result,
                       _{context_ops:1,
                         latency_ms:Trace.elapsed_ms,
                         context_bytes_inspected:Trace.bytes_inspected,
                         context_items_inspected:Trace.items_inspected}) :-
    Trace = Result.trace.

make_long_text(Text) :-
    findall(Line,
            ( between(1, 400, N),
              format(string(Line),
                     "row-~d needle deterministic payload for context benchmark\n",
                     [N])
            ),
            Lines),
    atomics_to_string(Lines, "", Text).

nonempty_string(Value) :-
    string(Value),
    string_length(Value, Length),
    Length > 0.

/* Direct vs recursive execution ---------------------------------------- */

direct_depth_0_case(1.0, Metrics, Details) :-
    benchmark_task_execution(0, Execution),
    ensure(Execution.selected_policy == direct_continuation,
           selected_route(Execution.selected_policy)),
    ensure(Execution.result == answer(42),
           unexpected_answer(Execution.result)),
    execution_metrics(Execution, Metrics),
    Details = _{task:shared_long_context_reasoning,
                depth:0,
                route:Execution.selected_policy,
                fixed_budget:_{remaining_calls:4,
                               remaining_tokens:8000}}.

rlm_depth_1_case(1.0, Metrics, Details) :-
    benchmark_task_execution(1, Execution),
    ensure(Execution.selected_policy == recursive_rlm,
           selected_route(Execution.selected_policy)),
    ensure(Execution.result == answer(42),
           unexpected_answer(Execution.result)),
    ensure(Execution.next_depth =:= 1,
           unexpected_depth(Execution.next_depth)),
    execution_metrics(Execution, Metrics),
    Details = _{task:shared_long_context_reasoning,
                depth:1,
                route:Execution.selected_policy,
                fixed_budget:_{remaining_calls:4,
                               remaining_tokens:8000}}.

rlm_depth_2_case(1.0, Metrics, Details) :-
    benchmark_task_execution(2, Execution),
    ensure(Execution.selected_policy == recursive_rlm,
           selected_route(Execution.selected_policy)),
    ensure(Execution.result == answer(42),
           unexpected_answer(Execution.result)),
    ensure(Execution.next_depth =:= 2,
           unexpected_depth(Execution.next_depth)),
    execution_metrics(Execution, Metrics),
    Details = _{task:shared_long_context_reasoning,
                depth:2,
                route:Execution.selected_policy,
                fixed_budget:_{remaining_calls:4,
                               remaining_tokens:8000}}.

benchmark_task_execution(Depth, Execution) :-
    Subject = benchmark_task(shared_long_context_reasoning),
    Request = _{subject:Subject,
                parent_identity:benchmark_root,
                direct_continuation:rlm_conformance:direct_benchmark_handler,
                recursive_rlm:rlm_conformance:recursive_benchmark_handler},
    benchmark_signals(Depth, Signals),
    benchmark_depth_options(Depth, Options),
    recursion_execute(Signals, Request, Options, ok(Execution)).

benchmark_signals(0,
                  _{task_complexity:0.9,
                    context_chars:180000,
                    uncertainty:0.75,
                    branch_diversity:0.3,
                    current_depth:0,
                    remaining_calls:4,
                    remaining_tokens:8000}).
benchmark_signals(1,
                  _{task_complexity:0.9,
                    context_chars:180000,
                    uncertainty:0.75,
                    branch_diversity:0.3,
                    current_depth:0,
                    remaining_calls:4,
                    remaining_tokens:8000}).
benchmark_signals(2,
                  _{task_complexity:0.9,
                    context_chars:180000,
                    uncertainty:0.75,
                    branch_diversity:0.3,
                    current_depth:1,
                    remaining_calls:4,
                    remaining_tokens:8000}).

benchmark_depth_options(0,
                        [candidate_selector(rlm_conformance:prefer_direct)]).
benchmark_depth_options(1,
                        [candidate_selector(rlm_conformance:prefer_recursive)]).
benchmark_depth_options(2,
                        [max_recursion_depth(2),
                         allow_deep_recursion(true),
                         deep_recursion_capability(true),
                         candidate_selector(rlm_conformance:prefer_recursive)]).

prefer_direct(_, Candidates, Selected) :-
    member(Selected, Candidates),
    Selected.route == direct_continuation,
    !.

prefer_recursive(_, Candidates, Selected) :-
    member(Selected, Candidates),
    Selected.route == recursive_rlm,
    !.

direct_benchmark_handler(_, _,
                         ok(answer(42),
                            _{actual_cost:0.0012,
                              usage:usage{model_calls:1,
                                          prompt_tokens:24,
                                          completion_tokens:8,
                                          total_tokens:32},
                              child_identity:direct_model_call})).

recursive_benchmark_handler(Decision, _,
                            ok(answer(42), Metadata)) :-
    CurrentDepth = Decision.signals.current_depth,
    (   CurrentDepth =:= 0
    ->  Metadata = _{actual_cost:0.0036,
                     usage:usage{model_calls:2,
                                 prompt_tokens:48,
                                 completion_tokens:16,
                                 total_tokens:64},
                     child_identity:recursive_depth_1}
    ;   Metadata = _{actual_cost:0.0068,
                     usage:usage{model_calls:3,
                                 prompt_tokens:72,
                                 completion_tokens:24,
                                 total_tokens:96},
                     child_identity:recursive_depth_2}
    ).

execution_metrics(Execution,
                  _{model_calls:ModelCalls,
                    prompt_tokens:PromptTokens,
                    completion_tokens:CompletionTokens,
                    total_tokens:TotalTokens,
                    cost_usd:Cost,
                    recursion_depth:Execution.next_depth}) :-
    Usage = Execution.actual_usage,
    get_dict(model_calls, Usage, ModelCalls),
    get_dict(prompt_tokens, Usage, PromptTokens),
    get_dict(completion_tokens, Usage, CompletionTokens),
    get_dict(total_tokens, Usage, TotalTokens),
    Cost = Execution.actual_cost.

/* Structured plan rejection -------------------------------------------- */

structured_plan_rejection_case(1.0,
                               _{model_calls:0,
                                 tool_calls:0,
                                 recursion_depth:0},
                               Details) :-
    Plan = plan([call(shell('id')), final(literal(done))]),
    plan_validate(Plan, [], default, error(Error)),
    ensure(Error.phase == validate, unexpected_phase(Error.phase)),
    ensure(Error.kind == invalid_plan, unexpected_kind(Error.kind)),
    Details = _{rejected:call/1,
                phase:Error.phase,
                kind:Error.kind,
                detail:Error.detail}.

/* Agent conformance ----------------------------------------------------- */

agent_backpressure_case(1.0, _{}, Details) :-
    setup_call_cleanup(
        agent_runtime_create([mailbox_size(1), send_timeout(0.0)], Runtime),
        agent_backpressure_observation(Runtime, Details),
        agent_runtime_destroy(Runtime)).

agent_backpressure_observation(Runtime, Details) :-
    Runtime = agent_runtime(RunId),
    agent_spawn(Runtime, none, agent_spec(root), [], ok(Root)),
    agent_send(Runtime, Root, checkpoint(RunId, first), [], ok(_)),
    agent_send(Runtime, Root, checkpoint(RunId, second), [], error(Error)),
    ensure(Error.kind == mailbox_full, unexpected_kind(Error.kind)),
    agent_pump(Runtime, Root, [], ok(_)),
    agent_send(Runtime, Root, checkpoint(RunId, second), [], ok(_)),
    Details = _{behavior:bounded_mailbox_backpressure,
                error_kind:Error.kind}.

agent_parent_cancel_case(1.0, _{}, Details) :-
    setup_call_cleanup(
        agent_runtime_create([], Runtime),
        agent_cancel_observation(Runtime, Details),
        agent_runtime_destroy(Runtime)).

agent_cancel_observation(Runtime, Details) :-
    agent_spawn(Runtime, none, agent_spec(parent), [], ok(Parent)),
    agent_spawn(Runtime, Parent, agent_spec(child), [], ok(Child)),
    agent_cancel(Runtime, Parent, benchmark_cancel, ok(_)),
    agent_status(Runtime, Parent, ok(ParentStatus)),
    agent_status(Runtime, Child, ok(ChildStatus)),
    ensure(ParentStatus.status == cancelled(benchmark_cancel),
           parent_not_cancelled(ParentStatus.status)),
    ensure(ChildStatus.status == cancelled(benchmark_cancel),
           child_not_cancelled(ChildStatus.status)),
    Details = _{behavior:parent_child_cancellation,
                parent_status:ParentStatus.status,
                child_status:ChildStatus.status}.

agent_logical_fanout_case(1.0, _{}, Details) :-
    setup_call_cleanup(
        agent_runtime_create([max_agents(32), worker_count(2)], Runtime),
        agent_fanout_observation(Runtime, Details),
        agent_runtime_destroy(Runtime)).

agent_fanout_observation(Runtime, Details) :-
    forall(between(1, 20, N),
           ( format(atom(Name), 'benchmark_agent_~d', [N]),
             agent_spawn(Runtime, none, agent_spec(Name), [], ok(_))
           )),
    agent_runtime_status(Runtime, Status),
    ensure(Status.agent_count =:= 20,
           unexpected_agent_count(Status.agent_count)),
    ensure(Status.worker_pool_size =:= 2,
           unexpected_worker_pool(Status.worker_pool_size)),
    ensure(Status.worker_running =:= 0,
           unexpected_running_workers(Status.worker_running)),
    Details = _{behavior:logical_agents_share_bounded_workers,
                logical_agents:Status.agent_count,
                worker_pool_size:Status.worker_pool_size}.

/* Graph checkpoint/resume ---------------------------------------------- */

graph_checkpoint_resume_case(1.0, _{}, Details) :-
    benchmark_graph_spec(Spec),
    benchmark_graph_registry(Registry),
    graph_compile(Spec, Registry, [], ok(Compiled)),
    setup_call_cleanup(
        graph_backend_open(memory, Backend),
        graph_checkpoint_observation(Compiled, Backend, Details),
        graph_backend_close(Backend)).

graph_checkpoint_observation(Compiled, Backend, Details) :-
    RunId = benchmark_graph_resume,
    graph_run(Compiled,
              _{},
              [backend(Backend), run_id(RunId)],
              ok(Paused)),
    ensure(Paused.status == paused(needs_approval),
           unexpected_graph_pause(Paused.status)),
    graph_checkpoint(Backend, RunId, Snapshot),
    ensure(Snapshot.status == paused(needs_approval),
           unexpected_checkpoint(Snapshot.status)),
    graph_resume(Compiled,
                 Backend,
                 RunId,
                 approved,
                 [],
                 ok(Completed)),
    ensure(Completed.status == completed,
           unexpected_graph_completion(Completed.status)),
    graph_history(Backend, RunId, History),
    ensure(has_event(interrupted, History), missing_event(interrupted)),
    ensure(has_event(resumed, History), missing_event(resumed)),
    ensure(has_event(run_completed, History), missing_event(run_completed)),
    length(History, EventCount),
    Details = _{behavior:checkpoint_resume,
                history_events:EventCount,
                final_log:Completed.state.log}.

benchmark_graph_spec(
    graph(benchmark_resume_graph,
          [field(log, list, [], append),
           field(approved, boolean, false, replace)],
          [node(wait, wait_handler),
           node(resume, resume_handler)],
          [edge(start, wait),
           edge(wait, resume),
           edge(resume, end)])).

benchmark_graph_registry([
    handler(wait_handler, rlm_conformance:benchmark_interrupt_node),
    handler(resume_handler, rlm_conformance:benchmark_resume_node)
]).

benchmark_interrupt_node(_, _, interrupt(needs_approval, _{log:[paused]})).
benchmark_resume_node(_, Context,
                      update(_{approved:true, log:[Context.resume]})).

has_event(Type, History) :-
    member(Event, History),
    get_dict(type, Event, Type),
    !.

/* MCP availability/conformance anchors --------------------------------- */

mcp_2025_adapter_case(1.0, _{}, Details) :-
    mcp_2025_protocol_version(Version),
    ensure(Version == '2025-11-25', unexpected_version(Version)),
    ClientInfo = _{name:"benchmark-client", version:"1.0"},
    Caps = _{},
    mcp_2025_client_state_new(ClientInfo,
                              Caps,
                              streamable_http,
                              ok(State)),
    ensure(State.phase == new, unexpected_phase(State.phase)),
    Details = _{protocol:Version,
                adapter:stateful_2025,
                phase:State.phase}.

mcp_2026_adapter_case(1.0, _{}, Details) :-
    mcp_2026_protocol_version(Version),
    ensure(Version == '2026-07-28', unexpected_version(Version)),
    ClientInfo = _{name:"benchmark-client", version:"1.0"},
    Caps = _{},
    mcp_2026_client_state_new(ClientInfo,
                              Caps,
                              streamable_http,
                              ok(State)),
    ensure(State.protocol_version == '2026-07-28',
           unexpected_version(State.protocol_version)),
    Details = _{protocol:Version,
                adapter:stateless_2026,
                state_protocol:State.protocol_version}.

mcp_dual_facade_case(1.0, _{}, Details) :-
    rlm_mcp_ready,
    mcp_command_normalize(list_tools, Canonical),
    ensure(Canonical == list_tools, unexpected_command(Canonical)),
    Details = _{facade:version_neutral,
                protocols:['2025-11-25','2026-07-28'],
                canonical_command:Canonical}.

/* Fixed deterministic budgets ------------------------------------------ */

apply_case_budget(Case0, Case) :-
    (   case_budget(Case0.name, Budget)
    ->  benchmark_budget_check(Case0, Budget, Outcome),
        apply_budget_outcome(Outcome, Budget, Case0, Case)
    ;   Case = Case0
    ).

apply_budget_outcome(ok, _, Case, Case) :- !.
apply_budget_outcome(error(Error), Budget, Case0, Case) :-
    Details = _{observation:Case0.details,
                fixed_budget:Budget,
                budget_error:Error},
    Case = Case0.put(_{status:fail,
                       quality:0.0,
                       details:Details}).

case_budget(context_peek,
            _{max_context_ops:1,
              max_context_bytes_inspected:65536}).
case_budget(context_search,
            _{max_context_ops:1,
              max_context_bytes_inspected:65536}).
case_budget(context_partition,
            _{max_context_ops:1,
              max_context_bytes_inspected:65536}).
case_budget(context_map,
            _{max_context_ops:1,
              max_context_bytes_inspected:4096}).
case_budget(context_reduce,
            _{max_context_ops:1,
              max_context_bytes_inspected:4096}).
case_budget(direct_depth_0,
            _{max_model_calls:1,
              max_total_tokens:32,
              max_cost_usd:0.0012,
              max_recursion_depth:0}).
case_budget(rlm_depth_1,
            _{max_model_calls:2,
              max_total_tokens:64,
              max_cost_usd:0.0036,
              max_recursion_depth:1}).
case_budget(rlm_depth_2,
            _{max_model_calls:3,
              max_total_tokens:96,
              max_cost_usd:0.0068,
              max_recursion_depth:2}).
case_budget(structured_plan_rejection,
            _{max_model_calls:0,
              max_tool_calls:0,
              max_recursion_depth:0}).

/* Helpers --------------------------------------------------------------- */

ensure(Goal, Detail) :-
    (   call(Goal)
    ->  true
    ;   throw(conformance_failure(Detail))
    ).
