:- module(rlm_benchmark,
          [ rlm_benchmark_ready/0,
            benchmark_case/7,
            benchmark_report/3,
            benchmark_budget_check/3,
            benchmark_json/2,
            benchmark_human_summary/2
          ]).

/** <module> Canonical benchmark and conformance metrics

Runtime-specific fixtures collect native traces and normalize them into cases
here. Measurement policy stays separate from provider, agent, graph, MCP, and
context execution so the benchmark layer reuses existing instrumentation.
*/

:- use_module(library(http/json)).
:- use_module(library(lists)).

rlm_benchmark_ready.

benchmark_case(Name,
               Category,
               Status,
               Quality0,
               Metrics0,
               Details,
               Case) :-
    require_atom(Name, name),
    require_atom(Category, category),
    require_status(Status),
    unit_score(Quality0, quality, Quality),
    normalize_metrics(Metrics0, Metrics),
    require_ground(Details, details),
    Case = benchmark_case{
               name:Name,
               category:Category,
               status:Status,
               quality:Quality,
               metrics:Metrics,
               details:Details
           }.

benchmark_report(Suite, Cases, Report) :-
    require_atom(Suite, suite),
    require_cases(Cases),
    length(Cases, Count),
    include(case_passed, Cases, PassedCases),
    include(case_failed, Cases, FailedCases),
    include(case_skipped, Cases, SkippedCases),
    length(PassedCases, Passed),
    length(FailedCases, Failed),
    length(SkippedCases, Skipped),
    case_quality_sum(Cases, QualitySum),
    mean_or_zero(QualitySum, Count, MeanQuality),
    aggregate_metrics(Cases, Totals, Maxima),
    report_status(Failed, Status),
    Report = benchmark_report{
                 schema_version:1,
                 suite:Suite,
                 status:Status,
                 case_count:Count,
                 passed:Passed,
                 failed:Failed,
                 skipped:Skipped,
                 mean_quality:MeanQuality,
                 totals:Totals,
                 maxima:Maxima,
                 cases:Cases
             }.

benchmark_budget_check(Case, Budget, Outcome) :-
    require_case(Case),
    require_dict(Budget, budget),
    budget_regressions(Case.metrics, Budget, Regressions),
    (   Regressions == []
    ->  Outcome = ok
    ;   Outcome = error(benchmark_budget_error{
                            case:Case.name,
                            regressions:Regressions,
                            message:"benchmark case exceeded one or more fixed budgets"
                        })
    ).

benchmark_json(Report, Json) :-
    require_report(Report),
    with_output_to(string(Json),
                   json_write_dict(current_output,
                                   Report,
                                   [width(0)])).

benchmark_human_summary(Report, Summary) :-
    require_report(Report),
    format(string(Summary),
           "~w: ~w — ~d/~d passed, ~d failed, ~d skipped; quality ~2f; calls ~d model/~d tool; tokens ~d; cost $~6f; latency ~d ms; max depth ~d; context ~d bytes",
           [ Report.suite,
             Report.status,
             Report.passed,
             Report.case_count,
             Report.failed,
             Report.skipped,
             Report.mean_quality,
             Report.totals.model_calls,
             Report.totals.tool_calls,
             Report.totals.total_tokens,
             Report.totals.cost_usd,
             Report.totals.latency_ms,
             Report.maxima.recursion_depth,
             Report.totals.context_bytes_inspected
           ]).

/* Metrics ---------------------------------------------------------------- */

normalize_metrics(Metrics0, Metrics) :-
    require_dict(Metrics0, metrics),
    metric_number(Metrics0, model_calls, 0, integer, ModelCalls),
    metric_number(Metrics0, tool_calls, 0, integer, ToolCalls),
    metric_number(Metrics0, context_ops, 0, integer, ContextOps),
    metric_number(Metrics0, prompt_tokens, 0, integer, PromptTokens),
    metric_number(Metrics0, completion_tokens, 0, integer, CompletionTokens),
    metric_number(Metrics0, total_tokens, 0, integer, TotalTokens),
    metric_number(Metrics0, cost_usd, 0.0, number, CostUsd),
    metric_number(Metrics0, latency_ms, 0, integer, LatencyMs),
    metric_number(Metrics0, recursion_depth, 0, integer, RecursionDepth),
    metric_number(Metrics0,
                  context_bytes_inspected,
                  0,
                  integer,
                  ContextBytes),
    metric_number(Metrics0,
                  context_items_inspected,
                  0,
                  integer,
                  ContextItems),
    Metrics = benchmark_metrics{
                  model_calls:ModelCalls,
                  tool_calls:ToolCalls,
                  context_ops:ContextOps,
                  prompt_tokens:PromptTokens,
                  completion_tokens:CompletionTokens,
                  total_tokens:TotalTokens,
                  cost_usd:CostUsd,
                  latency_ms:LatencyMs,
                  recursion_depth:RecursionDepth,
                  context_bytes_inspected:ContextBytes,
                  context_items_inspected:ContextItems
              }.

metric_number(Dict, Key, Default, Kind, Value) :-
    (   get_dict(Key, Dict, Raw)
    ->  true
    ;   Raw = Default
    ),
    require_nonnegative_number(Raw, Key, Kind),
    Value = Raw.

require_nonnegative_number(Value, _, integer) :-
    integer(Value),
    Value >= 0,
    !.
require_nonnegative_number(Value, _, number) :-
    number(Value),
    Value >= 0,
    !.
require_nonnegative_number(Value, Key, Kind) :-
    throw(error(domain_error(nonnegative_metric(Kind, Key), Value),
                context(rlm_benchmark, 'invalid benchmark metric'))).

aggregate_metrics(Cases, Totals, Maxima) :-
    empty_totals(T0),
    empty_maxima(M0),
    foldl(accumulate_case, Cases, state(T0, M0), state(Totals, Maxima)).

empty_totals(benchmark_metrics{
                 model_calls:0,
                 tool_calls:0,
                 context_ops:0,
                 prompt_tokens:0,
                 completion_tokens:0,
                 total_tokens:0,
                 cost_usd:0.0,
                 latency_ms:0,
                 recursion_depth:0,
                 context_bytes_inspected:0,
                 context_items_inspected:0
             }).

empty_maxima(benchmark_maxima{
                 model_calls:0,
                 tool_calls:0,
                 context_ops:0,
                 total_tokens:0,
                 cost_usd:0.0,
                 latency_ms:0,
                 recursion_depth:0,
                 context_bytes_inspected:0
             }).

accumulate_case(Case, state(T0, M0), state(T, M)) :-
    X = Case.metrics,
    ModelCalls is T0.model_calls+X.model_calls,
    ToolCalls is T0.tool_calls+X.tool_calls,
    ContextOps is T0.context_ops+X.context_ops,
    PromptTokens is T0.prompt_tokens+X.prompt_tokens,
    CompletionTokens is T0.completion_tokens+X.completion_tokens,
    TotalTokens is T0.total_tokens+X.total_tokens,
    CostUsd is T0.cost_usd+X.cost_usd,
    LatencyMs is T0.latency_ms+X.latency_ms,
    RecursionDepth is T0.recursion_depth+X.recursion_depth,
    ContextBytes is T0.context_bytes_inspected+X.context_bytes_inspected,
    ContextItems is T0.context_items_inspected+X.context_items_inspected,
    T = benchmark_metrics{
            model_calls:ModelCalls,
            tool_calls:ToolCalls,
            context_ops:ContextOps,
            prompt_tokens:PromptTokens,
            completion_tokens:CompletionTokens,
            total_tokens:TotalTokens,
            cost_usd:CostUsd,
            latency_ms:LatencyMs,
            recursion_depth:RecursionDepth,
            context_bytes_inspected:ContextBytes,
            context_items_inspected:ContextItems
        },
    maximum(M0.model_calls, X.model_calls, MaxModelCalls),
    maximum(M0.tool_calls, X.tool_calls, MaxToolCalls),
    maximum(M0.context_ops, X.context_ops, MaxContextOps),
    maximum(M0.total_tokens, X.total_tokens, MaxTotalTokens),
    maximum(M0.cost_usd, X.cost_usd, MaxCostUsd),
    maximum(M0.latency_ms, X.latency_ms, MaxLatencyMs),
    maximum(M0.recursion_depth, X.recursion_depth, MaxRecursionDepth),
    maximum(M0.context_bytes_inspected,
            X.context_bytes_inspected,
            MaxContextBytes),
    M = benchmark_maxima{
            model_calls:MaxModelCalls,
            tool_calls:MaxToolCalls,
            context_ops:MaxContextOps,
            total_tokens:MaxTotalTokens,
            cost_usd:MaxCostUsd,
            latency_ms:MaxLatencyMs,
            recursion_depth:MaxRecursionDepth,
            context_bytes_inspected:MaxContextBytes
        }.

maximum(A, B, Max) :- Max is max(A, B).

/* Fixed budget regression detection ------------------------------------- */

budget_regressions(Metrics, Budget, Regressions) :-
    findall(Regression,
            budget_regression(Metrics, Budget, Regression),
            Regressions).

budget_regression(Metrics, Budget, Regression) :-
    budget_key(BudgetKey, MetricKey),
    get_dict(BudgetKey, Budget, Limit),
    number(Limit),
    Limit >= 0,
    get_dict(MetricKey, Metrics, Actual),
    Actual > Limit,
    Regression = benchmark_regression{
                     metric:MetricKey,
                     actual:Actual,
                     limit:Limit
                 }.

budget_key(max_model_calls, model_calls).
budget_key(max_tool_calls, tool_calls).
budget_key(max_context_ops, context_ops).
budget_key(max_total_tokens, total_tokens).
budget_key(max_cost_usd, cost_usd).
budget_key(max_latency_ms, latency_ms).
budget_key(max_recursion_depth, recursion_depth).
budget_key(max_context_bytes_inspected, context_bytes_inspected).

/* Validation ------------------------------------------------------------- */

report_status(0, pass) :- !.
report_status(_, fail).

case_passed(Case) :- Case.status == pass.
case_failed(Case) :- Case.status == fail.
case_skipped(Case) :- Case.status == skipped.

case_quality_sum(Cases, Sum) :-
    findall(Quality,
            ( member(Case, Cases),
              Quality = Case.quality
            ),
            Values),
    sum_list(Values, Sum).

mean_or_zero(_, 0, 0.0) :- !.
mean_or_zero(Sum, Count, Mean) :- Mean is Sum/Count.

require_cases(Cases) :-
    (   is_list(Cases)
    ->  maplist(require_case, Cases)
    ;   throw(error(type_error(list, Cases),
                    context(rlm_benchmark, 'benchmark cases must be a list')))
    ).

require_case(Case) :-
    (   is_dict(Case, benchmark_case),
        get_dict(name, Case, _),
        get_dict(metrics, Case, Metrics),
        is_dict(Metrics, benchmark_metrics)
    ->  true
    ;   throw(error(type_error(benchmark_case, Case),
                    context(rlm_benchmark, 'invalid benchmark case')))
    ).

require_report(Report) :-
    (   is_dict(Report, benchmark_report)
    ->  true
    ;   throw(error(type_error(benchmark_report, Report),
                    context(rlm_benchmark, 'invalid benchmark report')))
    ).

require_dict(Value, _) :- is_dict(Value), !.
require_dict(Value, Name) :-
    throw(error(type_error(dict, Value), context(rlm_benchmark, Name))).

require_atom(Value, _) :- atom(Value), !.
require_atom(Value, Name) :-
    throw(error(type_error(atom, Value), context(rlm_benchmark, Name))).

require_status(Status) :- memberchk(Status, [pass, fail, skipped]), !.
require_status(Status) :-
    throw(error(domain_error(benchmark_status, Status),
                context(rlm_benchmark, 'invalid benchmark status'))).

unit_score(Value0, _, Value) :-
    number(Value0),
    Value0 >= 0.0,
    Value0 =< 1.0,
    !,
    Value is float(Value0).
unit_score(Value, Name, _) :-
    throw(error(domain_error(unit_score(Name), Value),
                context(rlm_benchmark, 'invalid benchmark score'))).

require_ground(Value, _) :- ground(Value), !.
require_ground(_, Name) :-
    throw(error(instantiation_error, context(rlm_benchmark, Name))).
