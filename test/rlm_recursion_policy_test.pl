:- begin_tests(rlm_recursion_policy).

:- use_module('../prolog/rlm_recursion_policy').

budgeted(Signals0, Signals) :-
    put_dict(_{remaining_calls:4,
               remaining_tokens:8000,
               current_depth:0},
             Signals0,
             Signals).

has_route(Candidates, Route) :-
    member(Candidate, Candidates),
    get_dict(route, Candidate, CandidateRoute),
    CandidateRoute == Route,
    !.

test(easy_retrieval_stays_direct) :-
    budgeted(_{task_complexity:0.10,
               context_chars:1200,
               uncertainty:0.10,
               branch_diversity:0.0},
             Signals),
    recursion_route(Signals, [], ok(Decision)),
    assertion(Decision.policy == direct_continuation),
    assertion(Decision.reason == easy_direct_continuation),
    assertion(Decision.trace.selected_policy == direct_continuation),
    assertion(Decision.budget_remaining.calls =:= 4).

test(long_context_hierarchical_task_selects_depth_one_recursion) :-
    budgeted(_{task_complexity:0.82,
               context_chars:180000,
               uncertainty:0.72,
               branch_diversity:0.35},
             Signals),
    recursion_route(Signals, [], ok(Decision)),
    assertion(Decision.policy == recursive_rlm),
    assertion(Decision.reason == long_context_recursive_decomposition),
    assertion(Decision.signals.remaining_depth =:= 1),
    assertion(Decision.expected_value > 0.0).

test(context_heavy_low_uncertainty_prefers_deterministic_context_work) :-
    budgeted(_{task_complexity:0.30,
               context_chars:90000,
               uncertainty:0.18,
               branch_diversity:0.0},
             Signals),
    recursion_route(Signals, [], ok(Decision)),
    assertion(Decision.policy == deterministic_context),
    assertion(Decision.reason == context_operation_dominates).

test(cheap_submodel_route_is_available_when_explicitly_enabled) :-
    budgeted(_{task_complexity:0.72,
               context_chars:12000,
               uncertainty:0.42,
               branch_diversity:0.05,
               deterministic_context_available:false,
               cheap_submodel_available:true},
             Signals),
    recursion_route(Signals, [], ok(Decision)),
    assertion(Decision.policy == cheap_submodel),
    member(Candidate, Decision.candidates),
    Candidate.route == cheap_submodel,
    assertion(Candidate.estimated_cost > 0.0).

test(delegated_subagent_is_a_bounded_candidate_when_available) :-
    budgeted(_{task_complexity:0.9,
               context_chars:30000,
               uncertainty:0.7,
               branch_diversity:0.95,
               cheap_submodel_available:true,
               delegated_subagent_available:true},
             Signals),
    recursion_candidates(Signals, [max_candidates(5)], ok(Candidates)),
    member(Candidate, Candidates),
    Candidate.route == delegated_subagent,
    assertion(Candidate.rationale == use_agent_harness_when_branching_or_tools_dominate),
    assertion(length(Candidates, 5)).

test(duplicate_subcall_removes_recursive_candidate) :-
    budgeted(_{task_complexity:0.95,
               context_chars:200000,
               uncertainty:0.9,
               branch_diversity:0.5,
               duplicate:true},
             Signals),
    recursion_candidates(Signals, [], ok(Candidates)),
    assertion(\+ has_route(Candidates, recursive_rlm)).

test(no_progress_subcall_removes_recursive_candidate) :-
    budgeted(_{task_complexity:0.95,
               context_chars:200000,
               uncertainty:0.9,
               branch_diversity:0.5,
               progress:0.01},
             Signals),
    recursion_candidates(Signals, [min_progress(0.05)], ok(Candidates)),
    assertion(\+ has_route(Candidates, recursive_rlm)).

test(explicit_duplicate_guard_rejects_fingerprint) :-
    recursion_fingerprint(call_tool(search, query{q:"same"}), Fingerprint),
    recursion_guard(Fingerprint,
                    [Fingerprint],
                    1.0,
                    [],
                    error(Error)),
    assertion(Error.detail == duplicate_subcall(Fingerprint)).

test(explicit_progress_guard_rejects_no_progress) :-
    recursion_fingerprint(rlm(plan([], final(done)), out), Fingerprint),
    recursion_guard(Fingerprint,
                    [],
                    0.01,
                    [min_progress(0.10)],
                    error(Error)),
    assertion(Error.detail == no_progress(0.01, 0.1)).

test(depth_greater_than_one_is_disabled_by_default) :-
    Signals = _{task_complexity:0.95,
                context_chars:200000,
                uncertainty:0.9,
                branch_diversity:0.4,
                current_depth:1,
                remaining_calls:4,
                remaining_tokens:8000},
    recursion_candidates(Signals,
                         [max_recursion_depth(4)],
                         ok(Candidates)),
    assertion(\+ has_route(Candidates, recursive_rlm)).

test(depth_greater_than_one_requires_both_opt_in_and_capability) :-
    Signals = _{task_complexity:0.95,
                context_chars:200000,
                uncertainty:0.9,
                branch_diversity:0.4,
                current_depth:1,
                remaining_calls:4,
                remaining_tokens:8000},
    Options = [max_recursion_depth(3),
               allow_deep_recursion(true),
               deep_recursion_capability(true)],
    recursion_candidates(Signals, Options, ok(Candidates)),
    assertion(has_route(Candidates, recursive_rlm)).

test(deep_opt_in_without_capability_stays_capped_at_one) :-
    Signals = _{task_complexity:0.95,
                context_chars:200000,
                uncertainty:0.9,
                current_depth:1,
                remaining_calls:4,
                remaining_tokens:8000},
    recursion_candidates(Signals,
                         [max_recursion_depth(3),
                          allow_deep_recursion(true)],
                         ok(Candidates)),
    assertion(\+ has_route(Candidates, recursive_rlm)).

test(candidate_generation_is_bounded) :-
    budgeted(_{task_complexity:0.75,
               context_chars:120000,
               uncertainty:0.6,
               cheap_submodel_available:true,
               delegated_subagent_available:true},
             Signals),
    recursion_candidates(Signals,
                         [max_candidates(2),
                          candidate_generator(
                              plunit_rlm_recursion_policy:generated_candidates)],
                         ok(Candidates)),
    assertion(length(Candidates, 2)).

test(generated_expected_value_is_recomputed) :-
    budgeted(_{task_complexity:0.2,
               context_chars:1000,
               uncertainty:0.2},
             Signals),
    recursion_candidates(Signals,
                         [cost_weight(0.5),
                          candidate_generator(
                              plunit_rlm_recursion_policy:spoof_direct_value)],
                         ok(Candidates)),
    member(Candidate, Candidates),
    Candidate.route == direct_continuation,
    assertion(Candidate.expected_utility =:= 0.5),
    assertion(Candidate.estimated_cost =:= 0.2),
    assertion(Candidate.expected_value =:= 0.4).

test(generator_cannot_enable_unavailable_route) :-
    budgeted(_{task_complexity:0.2,
               context_chars:1000,
               uncertainty:0.2,
               cheap_submodel_available:false},
             Signals),
    recursion_candidates(Signals,
                         [candidate_generator(
                              plunit_rlm_recursion_policy:unavailable_cheap)],
                         error(Error)),
    assertion(Error.detail ==
              candidate_generator_route_unavailable(cheap_submodel)).

test(candidate_selector_hook_can_choose_available_route) :-
    budgeted(_{task_complexity:0.8,
               context_chars:150000,
               uncertainty:0.65},
             Signals),
    recursion_route(Signals,
                    [candidate_selector(
                         plunit_rlm_recursion_policy:prefer_deterministic)],
                    ok(Decision)),
    assertion(Decision.policy == deterministic_context).

test(selector_cannot_escape_bounded_candidate_set) :-
    budgeted(_{task_complexity:0.1,
               context_chars:1000,
               uncertainty:0.1,
               delegated_subagent_available:true},
             Signals),
    recursion_route(Signals,
                    [max_candidates(1),
                     candidate_selector(
                         plunit_rlm_recursion_policy:escape_bounded_set)],
                    error(Error)),
    assertion(Error.detail ==
              candidate_selector_out_of_bounds(delegated_subagent)).

test(decision_exposes_expected_utility_cost_and_all_signals) :-
    budgeted(_{task_complexity:0.7,
               context_chars:100000,
               uncertainty:0.55,
               branch_diversity:0.25},
             Signals),
    recursion_route(Signals, [], ok(Decision)),
    assertion(number(Decision.expected_utility)),
    assertion(number(Decision.estimated_cost)),
    assertion(number(Decision.expected_value)),
    assertion(Decision.signals.task_complexity =:= 0.7),
    assertion(Decision.signals.context_chars =:= 100000),
    assertion(Decision.signals.uncertainty =:= 0.55),
    assertion(Decision.signals.branch_diversity =:= 0.25),
    assertion(Decision.trace.budget_remaining == Decision.budget_remaining).

generated_candidates(_, _,
                     [ _{route:cheap_submodel,
                         expected_utility:0.99,
                         estimated_cost:0.10,
                         expected_value:99.0,
                         rationale:model_generated_candidate},
                       _{route:delegated_subagent,
                         expected_utility:0.98,
                         estimated_cost:0.20,
                         expected_value:99.0,
                         rationale:model_generated_candidate}
                     ]).

spoof_direct_value(_, _,
                   [ _{route:direct_continuation,
                       expected_utility:0.5,
                       estimated_cost:0.2,
                       expected_value:99.0,
                       rationale:spoofed_value}
                   ]).

unavailable_cheap(_, _,
                  [ _{route:cheap_submodel,
                      expected_utility:0.99,
                      estimated_cost:0.01,
                      expected_value:99.0,
                      rationale:capability_escape}
                  ]).

prefer_deterministic(_, Candidates, Selected) :-
    member(Selected, Candidates),
    Selected.route == deterministic_context,
    !.

escape_bounded_set(_, _,
                   _{route:delegated_subagent,
                     expected_utility:1.0,
                     estimated_cost:0.0,
                     expected_value:1.0,
                     rationale:selector_escape}).

:- end_tests(rlm_recursion_policy).
