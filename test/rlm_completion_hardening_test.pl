:- begin_tests(rlm_completion_hardening).

:- use_module('../prolog/rlm_completion').
:- use_module('../prolog/rlm_openai_compatible', []).
:- use_module('../prolog/rlm_plan', []).
:- use_module('support/completion_hardening_support').

test(root_parallel_branch_keeps_root_authority) :-
    Options = [ planner_handler(completion_hardening_support:root_parallel_planner),
                capabilities([parallel, tool(root_only)]),
                child_capabilities([]),
                tools([tool(root_only,
                            completion_hardening_support:root_only_tool)])
              ],
    rlm_completion("root parallel authority",
                   text("opaque"),
                   Options,
                   Outcome),
    assertion(Outcome = ok(Result)),
    assertion(Result.value == [7]),
    assertion(Result.recursion.recursive_calls =:= 0).

test(nonground_model_response_gets_safe_trace_id) :-
    llm_query("trace nonground response",
              [model_handler(completion_hardening_support:nonground_model)],
              Outcome),
    assertion(Outcome = ok(Result)),
    assertion(Result.response.text == "NON_GROUND_OK"),
    Result.trajectory = [Event],
    assertion(atom(Event.id)).

test(transport_preserves_cancellation_signal,
     [throws(error(rlm_cancelled(test_token), _))]) :-
    rlm_openai_compatible:transport_exception_handler(
        error(rlm_cancelled(test_token), context(test, transport_cancel))).

test(plan_runtime_preserves_cancellation_signal,
     [throws(error(rlm_cancelled(test_token), _))]) :-
    rlm_plan:execution_exception(
        error(rlm_cancelled(test_token), context(test, plan_cancel)),
        _).

:- end_tests(rlm_completion_hardening).
