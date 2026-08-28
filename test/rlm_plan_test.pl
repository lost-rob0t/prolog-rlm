:- begin_tests(rlm_plan).

:- use_module('../prolog/rlm_plan').
:- use_module('../prolog/rlm_context').
:- use_module('support/plan_test_tools').

native_model_step_fixture(fake, Prompt, RequestOptions, Budget, Outcome) :-
    assertion(Prompt == "inspect with native tools"),
    assertion(RequestOptions.max_tokens =:= 32),
    assertion(Budget.max_iterations =:= 5),
    assertion(Budget.max_model_calls =:= 3),
    assertion(Budget.max_tool_calls =:= 2),
    assertion(Budget.max_context_ops =:= 2),
    response_fixture(native_1, "", 3, First),
    response_fixture(native_2, "NATIVE_STEP_OK", 5, Final),
    Outcome = ok(native_model_execution{
                     response:Final,
                     responses:[First,Final],
                     iterations:2,
                     model_calls:2,
                     tool_calls:1,
                     context_calls:1,
                     observation_bytes:5
                 }).

response_fixture(Id, Text, Tokens,
                 model_response{
                     provider:fake,
                     response_id:Id,
                     text:Text,
                     metadata:provider_metadata{http_status:200,
                                                response_received:true},
                     usage:usage{prompt_tokens:Tokens,
                                 completion_tokens:0,
                                 total_tokens:Tokens,
                                 cost:0.0}
                 }).

:- dynamic native_fixture_calls/1.
:- dynamic native_seen_used_tokens/1.

reset_native_fixture_calls :-
    retractall(native_fixture_calls(_)),
    retractall(native_seen_used_tokens(_)),
    assertz(native_fixture_calls(0)).

bump_native_fixture_calls :-
    retract(native_fixture_calls(N0)),
    N is N0+1,
    assertz(native_fixture_calls(N)).

% Reports more continuation iterations than the shared plan budget can charge
% after the already-reserved model step.
native_overspend_fixture(fake, _Prompt, _RequestOptions, _Budget, Outcome) :-
    bump_native_fixture_calls,
    response_fixture(native_o1, "", 3, First),
    response_fixture(native_o2, "OVERSPEND", 5, Final),
    Outcome = ok(native_model_execution{
                     response:Final,
                     responses:[First,Final],
                     iterations:9,
                     model_calls:2,
                     tool_calls:0,
                     context_calls:0,
                     observation_bytes:0
                 }).

% A native session that already spent provider turns and then failed: the
% direct failure retains every completed response for accounting.
native_failure_fixture(fake, _Prompt, _RequestOptions, _Budget,
                       error(direct_error{phase:provider,
                                          kind:provider_failed,
                                          message:"fake native session failed",
                                          usage:usage_summary{model_calls:1,
                                                              prompt_tokens:7,
                                                              completion_tokens:0,
                                                              total_tokens:7,
                                                              cost_usd:0.0,
                                                              cost_known:true,
                                                              tokens_known:true},
                                          model_responses:[FailedResponse],
                                          iterations:1,
                                          context_calls:0,
                                          tool_calls:0,
                                          output_bytes:0,
                                          trajectory:[]})) :-
    response_fixture(native_fail, "PARTIAL", 7, FailedResponse).

% Succeeds in two provider turns and records the native budget it received so
% the shared token accounting across model steps is observable.
native_capturing_fixture(fake, _Prompt, _RequestOptions, Budget, Outcome) :-
    bump_native_fixture_calls,
    assertz(native_seen_used_tokens(Budget.used_total_tokens)),
    response_fixture(native_c1, "", 4, First),
    response_fixture(native_c2, "SECOND_STEP_OK", 4, Final),
    Outcome = ok(native_model_execution{
                     response:Final,
                     responses:[First,Final],
                     iterations:2,
                     model_calls:2,
                     tool_calls:0,
                     context_calls:0,
                     observation_bytes:0
                 }).

test(parses_model_json_into_closed_ast) :-
    Json = "{\"steps\":[{\"op\":\"context\",\"handle\":{\"ref\":\"input\",\"name\":\"context\"},\"action\":{\"type\":\"search\",\"pattern\":\"needle\"},\"bind\":\"hits\"},{\"op\":\"tool\",\"name\":\"count_items\",\"args\":{\"ref\":\"var\",\"name\":\"hits\"},\"bind\":\"count\"},{\"op\":\"final\",\"value\":{\"ref\":\"var\",\"name\":\"count\"}}]}",
    plan_parse(Json, ok(Plan)),
    assertion(Plan == plan([
        context(input(context), search("needle"), hits),
        tool(count_items, var(hits), count),
        final(var(count))
    ])).

test(parses_fenced_json_without_prolog_read_term) :-
    Text = "```json\n{\"steps\":[{\"op\":\"final\",\"value\":7}]}\n```",
    plan_parse(Text, ok(plan([final(literal(7))]))).

test(valid_context_tool_final_plan_executes_and_traces) :-
    context_register(text("alpha\nneedle one\nneedle two\nomega"), [], ok(Ref)),
    Handle = Ref.handle,
    Plan = plan([
        context(input(context), search("needle"), hits),
        tool(count_items, var(hits), count),
        final(var(count))
    ]),
    Caps = [context(search), tool(count_items)],
    Options = [tools([tool(count_items, plan_test_tools:count_items)]),
               context_options([max_results(4), max_bytes(512)])],
    plan_run(Plan, Caps, Options, _{context:Handle}, ok(Result)),
    assertion(Result.value =:= 2),
    assertion(length(Result.transitions, 3)),
    Result.transitions = [T1,T2,T3],
    assertion(T1.sequence =:= 1),
    assertion(T1.operation == context(search)),
    assertion(T2.sequence =:= 2),
    assertion(T2.operation == tool(count_items)),
    assertion(T3.sequence =:= 3),
    assertion(T3.operation == final),
    context_delete(Handle, ok(_)).

test(raw_call_term_is_rejected_during_validation) :-
    Plan = plan([call(shell('id')), final(literal(done))]),
    plan_validate(Plan, [], default, error(Error)),
    assertion(Error.phase == validate),
    assertion(Error.kind == invalid_plan),
    assertion(Error.detail == unknown_or_malformed_operation(call/1)).

test(unknown_json_operator_is_rejected_during_normalization) :-
    Json = "{\"steps\":[{\"op\":\"eval\",\"code\":\"call(shell)\"},{\"op\":\"final\",\"value\":1}]}",
    plan_parse(Json, error(Error)),
    assertion(Error.phase == normalize),
    assertion(Error.kind == invalid_plan).

test(capability_denial_occurs_before_tool_side_effect) :-
    reset_marks,
    Plan = plan([
        tool(mark, literal(secret), marked),
        final(var(marked))
    ]),
    Options = [tools([tool(mark, plan_test_tools:mark)])],
    plan_run(Plan, [], Options, _{}, error(Error)),
    assertion(Error.kind == capability_denied),
    assertion(\+ marked).

test(runtime_preflight_rejects_unknown_tool_before_prior_context_side_effect) :-
    context_register(text("needle"), [], ok(Ref)),
    Handle = Ref.handle,
    Plan = plan([
        context(input(context), search("needle"), hits),
        tool(not_registered, var(hits), count),
        final(var(count))
    ]),
    Caps = [context(search), tool(not_registered)],
    plan_run(Plan, Caps, [], _{context:Handle}, error(Error)),
    assertion(Error.phase == preflight),
    assertion(Error.kind == unknown_tool),
    context_trace(Handle, 10, ok(Events)),
    assertion(Events == []),
    context_delete(Handle, ok(_)).

test(model_provider_is_preflighted_before_execution) :-
    Plan = plan([
        model(live, literal("hello"), _{max_tokens:8}, reply),
        final(field(var(reply), text))
    ]),
    Caps = [model(live)],
    plan_run(Plan, Caps, [], _{}, error(Error)),
    assertion(Error.phase == preflight),
    assertion(Error.kind == unknown_provider).

test(first_class_model_step_uses_native_session_and_charges_actual_counts) :-
    Plan = plan([
        model(fake, literal("inspect with native tools"),
              _{max_tokens:32}, reply),
        final(field(var(reply), text))
    ]),
    Caps = [model(fake)],
    Budget = _{max_steps:5,max_model_calls:3,max_tool_calls:2,
               max_context_ops:2,max_output_bytes:4096},
    Options = [providers([provider_ref(fake,provider(fake,[]))]),
               model_step_handler(plunit_rlm_plan:native_model_step_fixture),
               budget(Budget)],
    plan_run(Plan, Caps, Options, _{}, ok(Result)),
    assertion(Result.value == "NATIVE_STEP_OK"),
    Result.model_responses = [First,Final],
    assertion(First.response_id == native_1),
    assertion(Final.response_id == native_2),
    assertion(Result.budget_remaining.steps =:= 2),
    assertion(Result.budget_remaining.model_calls =:= 1),
    assertion(Result.budget_remaining.tool_calls =:= 1),
    assertion(Result.budget_remaining.context_ops =:= 1).

test(native_continuation_overspend_is_rejected_before_binding) :-
    reset_native_fixture_calls,
    Plan = plan([
        model(fake, literal("inspect with native tools"), _{max_tokens:32},
              reply),
        final(field(var(reply), text))
    ]),
    Caps = [model(fake)],
    Budget = _{max_steps:5,max_model_calls:3,max_tool_calls:2,
               max_context_ops:2,max_output_bytes:4096},
    Options = [providers([provider_ref(fake,provider(fake,[]))]),
               model_step_handler(plunit_rlm_plan:native_overspend_fixture),
               budget(Budget)],
    plan_run(Plan, Caps, Options, _{}, error(Error)),
    assertion(Error.kind == budget_exhausted),
    assertion(Error.budget == steps),
    assertion(Error.requested =:= 8),
    assertion(Error.remaining =:= 4),
    response_fixture(native_o1, "", 3, First),
    response_fixture(native_o2, "OVERSPEND", 5, Final),
    assertion(Error.model_responses == [First,Final]),
    native_fixture_calls(1).

test(partial_native_failure_preserves_provider_usage) :-
    Plan = plan([
        model(fake, literal("inspect with native tools"), _{}, reply),
        final(field(var(reply), text))
    ]),
    Caps = [model(fake)],
    Budget = _{max_steps:5,max_model_calls:3,max_tool_calls:2,
               max_context_ops:2,max_output_bytes:4096},
    Options = [providers([provider_ref(fake,provider(fake,[]))]),
               model_step_handler(plunit_rlm_plan:native_failure_fixture),
               budget(Budget)],
    plan_run(Plan, Caps, Options, _{}, error(Error)),
    assertion(Error.kind == model_error),
    response_fixture(native_fail, "PARTIAL", 7, FailedResponse),
    assertion(Error.model_responses == [FailedResponse]),
    assertion(FailedResponse.usage.total_tokens =:= 7),
    assertion(Error.budget_remaining.model_calls =:= 2).

test(native_sessions_share_recorded_token_budget_across_steps) :-
    reset_native_fixture_calls,
    Plan = plan([
        model(fake, literal("first native step"), _{}, first),
        model(fake, literal("second native step"), _{}, second),
        final(field(var(second), text))
    ]),
    Caps = [model(fake)],
    Budget = _{max_steps:8,max_model_calls:4,max_tool_calls:2,
               max_context_ops:2,max_output_bytes:4096},
    Options = [providers([provider_ref(fake,provider(fake,[]))]),
               model_step_handler(plunit_rlm_plan:native_capturing_fixture),
               budget(Budget)],
    plan_run(Plan, Caps, Options, _{}, ok(Result)),
    assertion(Result.value == "SECOND_STEP_OK"),
    native_fixture_calls(2),
    findall(Used, native_seen_used_tokens(Used), [0,8]),
    assertion(length(Result.model_responses, 4)),
    assertion(Result.budget_remaining.model_calls =:= 0).

test(standalone_model_step_without_handler_makes_one_raw_provider_call) :-
    Plan = plan([
        model(fake, literal("raw provider call"), _{}, reply),
        final(field(var(reply), text))
    ]),
    Caps = [model(fake)],
    Options = [providers([provider_ref(fake,provider(fake,[]))]),
               budget(_{max_steps:5,max_model_calls:3,max_tool_calls:2,
                        max_context_ops:2,max_output_bytes:4096})],
    plan_run(Plan, Caps, Options, _{}, error(Error)),
    assertion(Error.kind == model_error),
    assertion(Error.cause.kind == capability_denied),
    assertion(Error.cause.provider == fake),
    assertion(Error.model_responses == []).

test(duplicate_binding_is_rejected) :-
    Plan = plan([
        tool(count_items, literal([]), x),
        tool(count_items, literal([]), x),
        final(var(x))
    ]),
    Caps = [tool(count_items)],
    plan_validate(Plan, Caps, default, error(Error)),
    assertion(Error.kind == invalid_plan),
    assertion(Error.detail == duplicate_binding(x)).

test(unbound_variable_is_rejected_before_execution) :-
    Plan = plan([final(var(missing))]),
    plan_validate(Plan, [], default, error(Error)),
    assertion(Error.kind == invalid_plan),
    assertion(Error.detail == unbound_variable(missing)).

test(runaway_retry_plan_is_rejected_by_static_budget) :-
    Child = plan([
        tool(count_items, literal([]), n),
        final(var(n))
    ]),
    Plan = plan([
        retry(5, Child, result),
        final(var(result))
    ]),
    Budget = _{max_steps:5},
    Caps = [retry, tool(count_items)],
    plan_validate(Plan, Caps, Budget, error(Error)),
    assertion(Error.kind == budget_exceeded),
    assertion(Error.budget == steps),
    assertion(Error.estimated > Error.limit).

test(recursive_plan_honors_depth_budget) :-
    Deep = plan([final(literal(ok))]),
    Mid = plan([rlm(Deep, deep), final(var(deep))]),
    Root = plan([rlm(Mid, mid), final(var(mid))]),
    Caps = [rlm],
    plan_validate(Root, Caps, _{max_depth:2}, error(Error)),
    assertion(Error.kind == budget_exceeded),
    assertion(Error.budget == depth).

test(nested_plan_shares_global_runtime_output_budget) :-
    Child = plan([
        tool(large_payload, literal(go), payload),
        final(var(payload))
    ]),
    Plan = plan([
        rlm(Child, child),
        final(var(child))
    ]),
    Caps = [rlm, tool(large_payload)],
    Budget = _{max_output_bytes:50},
    Options = [budget(Budget),
               tools([tool(large_payload, plan_test_tools:large_payload)])],
    plan_run(Plan, Caps, Options, _{}, error(Error)),
    assertion(Error.kind == budget_exhausted),
    assertion(Error.budget == output_bytes).

test(parallel_branches_collect_results_under_shared_budget) :-
    P1 = plan([final(literal(alpha))]),
    P2 = plan([final(literal(beta))]),
    Plan = plan([
        parallel([P1,P2], values),
        final(var(values))
    ]),
    plan_run(Plan, [parallel], [], _{}, ok(Result)),
    assertion(Result.value == [alpha,beta]).

test(retry_reexecutes_failed_trusted_tool_with_global_counters) :-
    reset_flaky,
    Child = plan([
        tool(flaky, literal(ok), value),
        final(var(value))
    ]),
    Plan = plan([
        retry(2, Child, result),
        final(var(result))
    ]),
    Caps = [retry, tool(flaky)],
    Options = [tools([tool(flaky, plan_test_tools:flaky)])],
    plan_run(Plan, Caps, Options, _{}, ok(Result)),
    assertion(Result.value == ok),
    assertion(Result.budget_remaining.tool_calls =:= 14).

test(checkpoint_is_structured_runtime_state_not_arbitrary_io) :-
    Plan = plan([
        checkpoint(before_final),
        final(literal(done))
    ]),
    plan_run(Plan, [checkpoint], [], _{}, ok(Result)),
    assertion(Result.checkpoints == [before_final]),
    Result.transitions = [Checkpoint, Final],
    assertion(Checkpoint.operation == checkpoint),
    assertion(Final.operation == final).

test(invalid_map_transform_is_structured_validation_error) :-
    Plan = plan([
        context(input(context), map(call(shell)), mapped),
        final(var(mapped))
    ]),
    plan_validate(Plan, [context(map)], default, error(Error)),
    assertion(Error.kind == invalid_plan).

test(malformed_final_position_is_rejected) :-
    Plan = plan([
        final(literal(done)),
        checkpoint(after_final)
    ]),
    plan_validate(Plan, [checkpoint], default, error(Error)),
    assertion(Error.kind == invalid_plan),
    assertion(Error.detail == final_must_be_unique_and_last).

:- end_tests(rlm_plan).
