:- begin_tests(rlm_live_deep_budget).

:- use_module('../benchmark/rlm_live_deep_experiment').

budget_for_depth(Depth, Budget) :-
    rlm_live_deep_experiment:live_depth_budget(Depth, Budget).

test(depth_budget_scales_with_expected_provider_calls) :-
    budget_for_depth(0, Depth0),
    budget_for_depth(1, Depth1),
    budget_for_depth(2, Depth2),
    assertion(Depth0.max_total_tokens < Depth1.max_total_tokens),
    assertion(Depth1.max_total_tokens < Depth2.max_total_tokens).

test(depth_two_budget_covers_three_live_provider_calls) :-
    budget_for_depth(2, Budget),
    assertion(Budget.max_total_tokens >= 6000).

test(depth_budgets_remain_finite) :-
    forall(between(0, 2, Depth),
           ( budget_for_depth(Depth, Budget),
             assertion(integer(Budget.max_total_tokens)),
             assertion(Budget.max_total_tokens > 0),
             assertion(Budget.max_total_tokens =< 12000)
           )).

:- end_tests(rlm_live_deep_budget).
