:- begin_tests(rlm_conformance).

:- use_module('../benchmark/rlm_conformance').

case_named(Report, Name, Case) :-
    member(Case, Report.cases),
    Case.name == Name,
    !.

report_failures(Report) :-
    (   Report.status == pass
    ->  true
    ;   forall(( member(Case, Report.cases),
                 Case.status == fail
               ),
               format(user_error,
                      'CONFORMANCE FAILURE ~w: ~q~n',
                      [Case.name, Case.details]))
    ).

test(deterministic_suite_reports_all_required_families) :-
    deterministic_conformance(Report),
    report_failures(Report),
    assertion(Report.status == pass),
    assertion(Report.case_count =:= 16),
    assertion(Report.failed =:= 0),
    assertion(Report.maxima.recursion_depth =:= 2),
    assertion(Report.totals.context_bytes_inspected > 0),
    Required = [context_peek,
                context_search,
                context_partition,
                context_map,
                context_reduce,
                direct_depth_0,
                rlm_depth_1,
                rlm_depth_2,
                structured_plan_rejection,
                agent_backpressure,
                agent_parent_cancel,
                agent_logical_fanout,
                graph_checkpoint_resume,
                mcp_2025_adapter,
                mcp_2026_adapter,
                mcp_dual_facade],
    forall(member(Name, Required),
           ( case_named(Report, Name, Case),
             assertion(Case.status == pass)
           )).

test(direct_and_recursive_cases_are_comparable_and_metered) :-
    deterministic_conformance(Report),
    case_named(Report, direct_depth_0, Direct),
    case_named(Report, rlm_depth_1, Depth1),
    case_named(Report, rlm_depth_2, Depth2),
    assertion(Direct.details.task == shared_long_context_reasoning),
    assertion(Depth1.details.task == Direct.details.task),
    assertion(Depth2.details.task == Direct.details.task),
    assertion(Direct.details.fixed_budget == Depth1.details.fixed_budget),
    assertion(Depth1.details.fixed_budget == Depth2.details.fixed_budget),
    assertion(Direct.metrics.model_calls =:= 1),
    assertion(Depth1.metrics.model_calls =:= 2),
    assertion(Depth2.metrics.model_calls =:= 3),
    assertion(Direct.metrics.total_tokens =:= 32),
    assertion(Depth1.metrics.total_tokens =:= 64),
    assertion(Depth2.metrics.total_tokens =:= 96),
    assertion(Direct.metrics.cost_usd > 0.0),
    assertion(Depth1.metrics.cost_usd > Direct.metrics.cost_usd),
    assertion(Depth2.metrics.cost_usd > Depth1.metrics.cost_usd).

test(context_cases_report_native_inspection_metrics) :-
    deterministic_conformance(Report),
    forall(member(Name,
                  [context_peek,
                   context_search,
                   context_partition,
                   context_map,
                   context_reduce]),
           ( case_named(Report, Name, Case),
             assertion(Case.metrics.context_ops =:= 1),
             assertion(Case.metrics.context_bytes_inspected >= 0),
             assertion(Case.metrics.context_items_inspected >= 0),
             assertion(Case.metrics.latency_ms >= 0)
           )).

:- end_tests(rlm_conformance).
