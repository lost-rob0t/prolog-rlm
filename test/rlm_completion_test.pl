:- begin_tests(rlm_completion).

:- use_module('../prolog/rlm_completion').
:- use_module('support/completion_test_support').

base_caps([rlm, model(openrouter)]).
base_child_caps([rlm, model(openrouter)]).

base_options(Planner, Options) :-
    base_caps(Caps),
    base_child_caps(ChildCaps),
    Options = [ planner_handler(Planner),
                capabilities(Caps),
                child_capabilities(ChildCaps)
              ].

expect_ok(ok(Result), Result) :- !.
expect_ok(Outcome, _) :-
    throw(error(unexpected_completion_outcome(Outcome),
                context(rlm_completion_test, expected_ok))).

expect_error(error(Error), Error) :- !.
expect_error(Outcome, _) :-
    throw(error(unexpected_completion_outcome(Outcome),
                context(rlm_completion_test, expected_error))).

anonymous_dict_recursive_plan(Plan, Child) :-
    Grandchild = plan([tool(secret_tool,
                            literal(_{secret:true}),
                            secret),
                       final(var(secret))]),
    Child = plan([rlm(Grandchild, grand),
                  final(var(grand))]),
    Plan = plan([rlm(Child, child),
                 final(var(child))]).

test(direct_non_recursive_completion,
     [setup(completion_test_support:reset_calls)]) :-
    base_options(completion_test_support:direct_planner, Options),
    rlm_completion("return directly",
                   text("opaque context body"),
                   Options,
                   Outcome),
    expect_ok(Outcome, Result),
    assertion(Result.value == "direct-ok"),
    assertion(Result.recursion.recursive_calls =:= 0),
    assertion(Result.recursion.max_depth =:= 0),
    assertion(Result.usage.model_calls =:= 1),
    completion_test_support:planner_calls(Calls),
    assertion(Calls =:= 1).

test(recursion_hard_max_rejects_depth_two,
     [setup(completion_test_support:reset_calls)]) :-
    base_options(completion_test_support:depth_two_planner, Base),
    append(Base,
           [budget(_{max_recursion_depth:1})],
           Options),
    rlm_completion("too deep", text("ctx"), Options, Outcome),
    expect_error(Outcome, Error),
    assertion(Error.phase == validate),
    assertion(Error.kind == recursive_plan_rejected),
    assertion(Error.detail = recursion_depth_exceeded(2, 1)).

test(duplicate_recursive_call_rejected,
     [setup(completion_test_support:reset_calls)]) :-
    base_options(completion_test_support:duplicate_recursive_planner,
                 Options),
    rlm_completion("duplicate", text("ctx"), Options, Outcome),
    expect_error(Outcome, Error),
    assertion(Error.phase == validate),
    assertion(Error.kind == recursive_plan_rejected),
    assertion(Error.detail == duplicate_recursive_call).

test(anonymous_dict_child_is_representation_nonground) :-
    anonymous_dict_recursive_plan(_, Child),
    assertion(\+ ground(Child)),
    term_hash(Child, Hash),
    assertion(var(Hash)).

test(recursive_stats_accept_anonymous_dict_tag_without_false_cycle) :-
    anonymous_dict_recursive_plan(Plan, _),
    rlm_completion:recursive_plan_stats(Plan, Stats),
    assertion(Stats.recursive_calls =:= 2),
    assertion(Stats.max_depth =:= 2),
    assertion(maplist(integer, Stats.fingerprints)).

test(anonymous_dict_tag_does_not_false_cycle,
     [setup(completion_test_support:reset_calls)]) :-
    base_options(completion_test_support:anonymous_dict_grandchild_tool_planner,
                 Base),
    append(Base,
           [budget(_{max_recursion_depth:2})],
           Options),
    rlm_completion("anonymous dict tag",
                   text("ctx"),
                   Options,
                   Outcome),
    expect_error(Outcome, Error),
    assertion(Error.phase == validate),
    assertion(Error.kind == recursive_plan_rejected),
    assertion(Error.detail == child_capability_denied(tool(secret_tool))).

test(genuinely_nonground_recursive_plan_rejected,
     [setup(completion_test_support:reset_calls)]) :-
    base_options(completion_test_support:nonground_recursive_planner,
                 Options),
    rlm_completion("nonground recursive plan",
                   text("ctx"),
                   Options,
                   Outcome),
    expect_error(Outcome, Error),
    assertion(Error.phase == validate),
    assertion(Error.kind == recursive_plan_rejected),
    assertion(Error.detail == non_ground_recursive_plan).

test(genuine_recursive_cycle_remains_rejected,
     [setup(completion_test_support:reset_calls)]) :-
    base_options(completion_test_support:cyclic_recursive_planner,
                 Base),
    append(Base,
           [budget(_{max_recursion_depth:4})],
           Options),
    rlm_completion("cyclic recursive plan",
                   text("ctx"),
                   Options,
                   Outcome),
    expect_error(Outcome, Error),
    assertion(Error.phase == validate),
    assertion(Error.kind == recursive_plan_rejected),
    assertion(Error.detail = recursive_cycle(_)).

test(child_capabilities_cannot_reuse_parent_tool,
     [setup(completion_test_support:reset_calls)]) :-
    Parent = [rlm, model(openrouter), tool(secret_tool)],
    Child = [rlm, model(openrouter)],
    Options = [ planner_handler(completion_test_support:child_tool_planner),
                capabilities(Parent),
                child_capabilities(Child)
              ],
    rlm_completion("narrow child", text("ctx"), Options, Outcome),
    expect_error(Outcome, Error),
    assertion(Error.phase == validate),
    assertion(Error.kind == recursive_plan_rejected),
    assertion(Error.detail == child_capability_denied(tool(secret_tool))).

test(planner_retry_cannot_exceed_model_call_budget,
     [setup(completion_test_support:reset_calls)]) :-
    base_options(completion_test_support:invalid_planner, Base),
    append(Base,
           [ planner_attempts(3),
             budget(_{max_model_calls:1})
           ],
           Options),
    rlm_completion("invalid planner", text("ctx"), Options, Outcome),
    expect_error(Outcome, Error),
    assertion(Error.phase == planner),
    assertion(Error.kind == model_call_budget_exhausted),
    completion_test_support:planner_calls(Calls),
    assertion(Calls =:= 1).

test(cancelled_token_stops_before_planner_side_effect,
     [setup(completion_test_support:reset_calls)]) :-
    rlm_cancellation_token(Token),
    rlm_cancel(Token),
    base_options(completion_test_support:direct_planner, Base),
    append(Base, [cancel_token(Token)], Options),
    rlm_completion("cancel me", text("ctx"), Options, Outcome),
    expect_error(Outcome, Error),
    assertion(Error.kind == cancelled),
    completion_test_support:planner_calls(Calls),
    assertion(Calls =:= 0).

test(midflight_cancellation_interrupts_pending_model,
     [setup(completion_test_support:reset_calls)]) :-
    rlm_cancellation_token(Token),
    message_queue_create(Queue),
    setup_call_cleanup(
        true,
        ( thread_create(run_pending_model(Token, Queue), Thread, []),
          thread_get_message(Queue, started),
          rlm_cancel(Token),
          thread_get_message(Queue, outcome(Outcome), [timeout(2)]),
          thread_join(Thread, _),
          expect_error(Outcome, Error),
          assertion(Error.kind == cancelled)
        ),
        message_queue_destroy(Queue)).

run_pending_model(Token, Queue) :-
    llm_query("slow",
              [ cancel_token(Token),
                model_handler(completion_test_support:slow_model_started(Queue)),
                budget(_{time_limit:5.0})
              ],
              Outcome),
    thread_send_message(Queue, outcome(Outcome)).

test(wall_time_budget_interrupts_pending_model,
     [setup(completion_test_support:reset_calls)]) :-
    llm_query("slow",
              [ model_handler(completion_test_support:slow_model),
                budget(_{time_limit:0.05})
              ],
              Outcome),
    expect_error(Outcome, Error),
    assertion(Error.kind == timeout).

test(token_budget_rejects_reported_overage,
     [setup(completion_test_support:reset_calls)]) :-
    llm_query("tokens",
              [ model_handler(completion_test_support:token_heavy_model),
                budget(_{max_total_tokens:10})
              ],
              Outcome),
    expect_error(Outcome, Error),
    assertion(Error.kind == token_budget_exceeded),
    assertion(Error.used =:= 60),
    assertion(Error.limit =:= 10).

test(cost_budget_rejects_reported_overage,
     [setup(completion_test_support:reset_calls)]) :-
    llm_query("cost",
              [ model_handler(completion_test_support:costly_model),
                budget(_{max_cost_usd:0.1})
              ],
              Outcome),
    expect_error(Outcome, Error),
    assertion(Error.kind == cost_budget_exceeded),
    assertion(Error.used =:= 0.5),
    assertion(Error.limit =:= 0.1).

test(llm_query_supports_bounded_injected_model,
     [setup(completion_test_support:reset_calls)]) :-
    llm_query("hello",
              [model_handler(completion_test_support:fake_model)],
              Outcome),
    expect_ok(Outcome, Result),
    assertion(Result.response.text == "FAKE_MODEL_OK"),
    assertion(Result.usage.model_calls =:= 1),
    assertion(Result.usage.total_tokens =:= 3),
    completion_test_support:model_calls(Calls),
    assertion(Calls =:= 1).

test(rlm_query_rejects_depth_above_hard_max) :-
    rlm_query("child",
              text("ctx"),
              [ budget(_{max_recursion_depth:0}),
                depth(1),
                model_handler(completion_test_support:fake_model)
              ],
              Outcome),
    expect_error(Outcome, Error),
    assertion(Error.kind == completion_fault),
    assertion(Error.detail = recursion_depth_exceeded(1, 0)).

test(rlm_query_depth_one_uses_model,
     [setup(completion_test_support:reset_calls)]) :-
    rlm_query("child",
              text("ctx"),
              [ model_handler(completion_test_support:fake_model),
                depth(1)
              ],
              Outcome),
    expect_ok(Outcome, Result),
    assertion(Result.depth =:= 1),
    assertion(Result.response.text == "FAKE_MODEL_OK"),
    completion_test_support:model_calls(Calls),
    assertion(Calls =:= 1).

:- end_tests(rlm_completion).
