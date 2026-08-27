:- begin_tests(rlm_runtime_status).

:- use_module('../prolog/rlm_runtime_status').

test(projects_model_usage_and_explicit_context_occupancy) :-
    Usage = usage_summary{prompt_tokens:12000,
                          completion_tokens:2000},
    runtime_status('qwen3-32b', Usage, context(12288, 32768), Status),
    assertion(Status.model == "qwen3-32b"),
    assertion(Status.input_tokens =:= 12000),
    assertion(Status.output_tokens =:= 2000),
    assertion(Status.context_tokens =:= 12288),
    assertion(Status.context_window =:= 32768),
    assertion(Status.context_percent =:= 38),
    runtime_status_line(Status, Line),
    assertion(Line == "qwen3-32b · in 12000 · out 2000 · ctx 38%").

test(unknown_context_capacity_stays_unknown) :-
    Usage = usage_summary{prompt_tokens:321,
                          completion_tokens:45},
    runtime_status("model-x", Usage, unknown, Status),
    assertion(Status.context_tokens == unknown),
    assertion(Status.context_window == unknown),
    assertion(Status.context_percent == unknown),
    runtime_status_line(Status, Line),
    assertion(Line == "model-x · in 321 · out 45 · ctx ?").

test(cumulative_usage_is_not_accepted_as_context_observation,
     [throws(error(domain_error(runtime_context, _), _))]) :-
    Usage = usage_summary{prompt_tokens:1000,
                          completion_tokens:100},
    runtime_status(model, Usage, Usage, _).

test(rejects_missing_usage_counter,
     [throws(error(domain_error(runtime_usage(completion_tokens), _), _))]) :-
    runtime_status(model,
                   usage_summary{prompt_tokens:12},
                   unknown,
                   _).

:- end_tests(rlm_runtime_status).
