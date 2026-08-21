:- begin_tests(rlm_nested_usage).

:- use_module('../prolog/rlm_plan').
:- use_module('../prolog/rlm_completion').

model_response(Id, Prompt, Completion, Cost,
               model_response{
                   response_id:Id,
                   metadata:metadata{http_status:200,
                                     response_received:true},
                   usage:usage{prompt_tokens:Prompt,
                               completion_tokens:Completion,
                               total_tokens:Total,
                               cost:Cost}
               }) :-
    Total is Prompt+Completion.

empty_exec_state(
    exec_state{
        vars:vars{},
        model_responses:[],
        transitions:[],
        sequence:0,
        checkpoints:[],
        remaining:runtime_budget{
            steps:20,
            model_calls:20,
            tool_calls:20,
            context_ops:20,
            output_bytes:65536
        }
    }).

completion_budget(MaxTokens,
                  completion_budget{
                      max_iterations:20,
                      max_recursion_depth:2,
                      max_concurrent_subcalls:1,
                      max_model_calls:10,
                      max_tool_calls:10,
                      max_context_ops:10,
                      max_total_tokens:MaxTokens,
                      max_cost_usd:1.0,
                      max_output_bytes:65536,
                      time_limit:10.0
                  }).

planner_usage(Prompt, Completion, Cost,
              usage_summary{
                  model_calls:1,
                  prompt_tokens:Prompt,
                  completion_tokens:Completion,
                  total_tokens:Total,
                  cost_usd:Cost,
                  cost_known:true,
                  tokens_known:true
              }) :-
    Total is Prompt+Completion.

test(model_response_ledger_survives_nested_scope_and_preserves_order) :-
    model_response(r1, 7, 3, 0.001, R1),
    model_response(r2, 13, 7, 0.002, R2),
    model_response(r3, 19, 11, 0.003, R3),
    empty_exec_state(S0),
    rlm_plan:record_model_response(R1, S0, S1),
    rlm_plan:record_model_response(R2, S1, S2),
    rlm_plan:record_model_response(R3, S2, S3),
    rlm_plan:finalize_execution(final(done, S3), ok(Result)),
    assertion(Result.model_responses == [R1,R2,R3]).

test(plan_usage_counts_all_recorded_nested_responses) :-
    model_response(r1, 7, 3, 0.001, R1),
    model_response(r2, 13, 7, 0.002, R2),
    model_response(r3, 19, 11, 0.003, R3),
    Result = plan_result{
                 vars:vars{root:R1, leaf:R3},
                 model_responses:[R1,R2,R3]
             },
    rlm_completion:plan_usage(Result, Usage),
    assertion(Usage.model_calls =:= 3),
    assertion(Usage.prompt_tokens =:= 39),
    assertion(Usage.completion_tokens =:= 21),
    assertion(Usage.total_tokens =:= 60),
    assertion(abs(Usage.cost_usd-0.006) < 1.0e-12),
    assertion(Usage.tokens_known == true),
    assertion(Usage.cost_known == true).

test(hidden_nested_usage_can_trip_completion_token_budget) :-
    model_response(r1, 7, 3, 0.001, R1),
    model_response(r2, 13, 7, 0.002, R2),
    model_response(r3, 19, 11, 0.003, R3),
    Result = plan_result{
                 vars:vars{root:R1, leaf:R3},
                 model_responses:[R1,R2,R3]
             },
    rlm_completion:plan_usage(Result, Usage),
    completion_budget(59, Budget),
    rlm_completion:budget_usage_check(Budget, Usage, Outcome),
    Outcome = error(Error),
    assertion(Error.kind == token_budget_exceeded),
    assertion(Error.used =:= 60),
    assertion(Error.limit =:= 59).

test(legacy_plan_result_without_ledger_keeps_visible_response_fallback) :-
    model_response(r1, 7, 3, 0.001, R1),
    model_response(r2, 13, 7, 0.002, R2),
    Result = plan_result{vars:vars{first:R1, duplicate:R1, second:R2}},
    rlm_completion:plan_usage(Result, Usage),
    assertion(Usage.model_calls =:= 2),
    assertion(Usage.total_tokens =:= 30),
    assertion(abs(Usage.cost_usd-0.003) < 1.0e-12).

test(completion_error_preserves_executed_model_usage) :-
    model_response(r1, 7, 3, 0.001, R1),
    model_response(r2, 13, 7, 0.002, R2),
    planner_usage(2, 1, 0.0005, PlannerUsage),
    Planner = planner_result{usage:PlannerUsage},
    PlanError = plan_error{
                    phase:execute,
                    kind:tool_error,
                    message:"tool failed after model calls",
                    model_responses:[R1,R2]
                },
    completion_budget(100, Budget),
    rlm_completion:completion_after_execution(error(PlanError),
                                               Planner,
                                               plan([]),
                                               recursion_stats{},
                                               [],
                                               Budget,
                                               unused_token,
                                               error(Error)),
    assertion(get_dict(phase, Error, execute)),
    assertion(get_dict(kind, Error, tool_error)),
    assertion(get_dict(usage, Error, Usage)),
    assertion(Usage.model_calls =:= 3),
    assertion(Usage.prompt_tokens =:= 22),
    assertion(Usage.completion_tokens =:= 11),
    assertion(Usage.total_tokens =:= 33),
    assertion(abs(Usage.cost_usd-0.0035) < 1.0e-12),
    assertion(\+ get_dict(budget_violation, Error, _)).

test(completion_error_reports_budget_violation_without_hiding_cause) :-
    model_response(r1, 7, 3, 0.001, R1),
    model_response(r2, 13, 7, 0.002, R2),
    planner_usage(2, 1, 0.0005, PlannerUsage),
    Planner = planner_result{usage:PlannerUsage},
    PlanError = plan_error{
                    phase:execute,
                    kind:tool_error,
                    message:"tool failed after model calls",
                    model_responses:[R1,R2]
                },
    completion_budget(32, Budget),
    rlm_completion:completion_after_execution(error(PlanError),
                                               Planner,
                                               plan([]),
                                               recursion_stats{},
                                               [],
                                               Budget,
                                               unused_token,
                                               error(Error)),
    assertion(get_dict(phase, Error, execute)),
    assertion(get_dict(kind, Error, tool_error)),
    assertion(get_dict(usage, Error, Usage)),
    assertion(Usage.total_tokens =:= 33),
    assertion(get_dict(budget_violation, Error, BudgetViolation)),
    assertion(BudgetViolation.phase == budget),
    assertion(BudgetViolation.kind == token_budget_exceeded),
    assertion(BudgetViolation.used =:= 33),
    assertion(BudgetViolation.limit =:= 32).

:- end_tests(rlm_nested_usage).
