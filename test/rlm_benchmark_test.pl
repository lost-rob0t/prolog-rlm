:- begin_tests(rlm_benchmark).

:- use_module('../prolog/rlm_benchmark').
:- use_module('../benchmark/rlm_live_benchmark').

test(case_normalizes_missing_metrics_to_zero) :-
    benchmark_case(example,
                   core,
                   pass,
                   1.0,
                   _{model_calls:2, total_tokens:24},
                   _{fixture:deterministic},
                   Case),
    assertion(Case.metrics.model_calls =:= 2),
    assertion(Case.metrics.total_tokens =:= 24),
    assertion(Case.metrics.tool_calls =:= 0),
    assertion(Case.metrics.cost_usd =:= 0.0).

test(report_aggregates_totals_and_maxima) :-
    benchmark_case(first,
                   recursion,
                   pass,
                   1.0,
                   _{model_calls:1,
                     total_tokens:20,
                     recursion_depth:0,
                     context_bytes_inspected:100},
                   _{},
                   First),
    benchmark_case(second,
                   recursion,
                   pass,
                   0.8,
                   _{model_calls:2,
                     total_tokens:30,
                     recursion_depth:2,
                     context_bytes_inspected:40},
                   _{},
                   Second),
    benchmark_report(deterministic, [First, Second], Report),
    assertion(Report.status == pass),
    assertion(Report.case_count =:= 2),
    assertion(Report.totals.model_calls =:= 3),
    assertion(Report.totals.total_tokens =:= 50),
    assertion(Report.totals.context_bytes_inspected =:= 140),
    assertion(Report.maxima.model_calls =:= 2),
    assertion(Report.maxima.recursion_depth =:= 2),
    assertion(Report.mean_quality =:= 0.9).

test(failed_case_fails_report) :-
    benchmark_case(bad,
                   plan,
                   fail,
                   0.0,
                   _{},
                   _{reason:unexpected_success},
                   Case),
    benchmark_report(deterministic, [Case], Report),
    assertion(Report.status == fail),
    assertion(Report.failed =:= 1).

test(fixed_budget_accepts_case_within_limits) :-
    benchmark_case(ok_case,
                   provider,
                   pass,
                   1.0,
                   _{model_calls:2,
                     total_tokens:80,
                     latency_ms:25},
                   _{},
                   Case),
    Budget = _{max_model_calls:2,
               max_total_tokens:100,
               max_latency_ms:30},
    benchmark_budget_check(Case, Budget, ok).

test(fixed_budget_reports_all_regressions) :-
    benchmark_case(regressed,
                   provider,
                   pass,
                   1.0,
                   _{model_calls:3,
                     total_tokens:120,
                     latency_ms:40},
                   _{},
                   Case),
    Budget = _{max_model_calls:2,
               max_total_tokens:100,
               max_latency_ms:30},
    benchmark_budget_check(Case, Budget, error(Error)),
    assertion(length(Error.regressions, 3)),
    findall(Metric,
            ( member(Regression, Error.regressions),
              Metric = Regression.metric
            ),
            Metrics),
    assertion(Metrics == [model_calls,total_tokens,latency_ms]).

test(json_and_human_summary_are_stable_outputs) :-
    benchmark_case(serialized,
                   context,
                   pass,
                   1.0,
                   _{context_ops:1,
                     context_bytes_inspected:42},
                   _{operation:search},
                   Case),
    benchmark_report(deterministic, [Case], Report),
    benchmark_json(Report, Json),
    assertion(sub_string(Json, _, _, _, "\"schema_version\":1")),
    assertion(sub_string(Json, _, _, _, "\"context_bytes_inspected\":42")),
    benchmark_human_summary(Report, Summary),
    assertion(sub_string(Summary, _, _, _, "deterministic: pass")),
    assertion(sub_string(Summary, _, _, _, "context 42 bytes")).

test(live_quality_exact_token_in_text_is_full_pass) :-
    Response = _{text:"PROLOG_RLM_BENCHMARK_OK",
                 reasoning:"",
                 tool_calls:[]},
    rlm_live_benchmark:response_quality(Response,
                                        Quality,
                                        Status,
                                        Details),
    assertion(Quality =:= 1.0),
    assertion(Status == pass),
    assertion(Details.expected_token == true),
    assertion(Details.assistant_output == true).

test(live_quality_exact_token_in_reasoning_is_full_pass) :-
    Response = _{text:"",
                 reasoning:"analysis PROLOG_RLM_BENCHMARK_OK",
                 tool_calls:[]},
    rlm_live_benchmark:response_quality(Response,
                                        Quality,
                                        Status,
                                        Details),
    assertion(Quality =:= 1.0),
    assertion(Status == pass),
    assertion(Details.expected_token == true).

test(live_quality_usable_output_without_token_is_partial_pass) :-
    Response = _{text:"",
                 reasoning:"I produced a valid assistant response.",
                 tool_calls:[]},
    rlm_live_benchmark:response_quality(Response,
                                        Quality,
                                        Status,
                                        Details),
    assertion(Quality =:= 0.5),
    assertion(Status == pass),
    assertion(Details.expected_token == false),
    assertion(Details.assistant_output == true).

test(live_quality_without_assistant_output_fails) :-
    Response = _{text:"", reasoning:"", tool_calls:[]},
    rlm_live_benchmark:response_quality(Response,
                                        Quality,
                                        Status,
                                        Details),
    assertion(Quality =:= 0.0),
    assertion(Status == fail),
    assertion(Details.expected_token == false),
    assertion(Details.assistant_output == false).

:- end_tests(rlm_benchmark).
