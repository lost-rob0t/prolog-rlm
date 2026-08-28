:- begin_tests(rlm_completion_final_handoff).

:- use_module('../prolog/rlm_completion').
:- use_module('../benchmark/rlm_live_deep_experiment').
:- use_module('../benchmark/rlm_constraint_problem').
:- use_module('../benchmark/rlm_constraint_verify').
:- use_module('support/completion_final_handoff_support').
:- use_module(library(http/json)).

:- meta_predicate with_handoff_server(1).

expect_ok(ok(Result), Result) :- !.
expect_ok(Outcome, _) :-
    throw(error(unexpected_completion_outcome(Outcome),
                context(rlm_completion_final_handoff, expected_ok))).

expect_error(error(Error), Error) :- !.
expect_error(Outcome, _) :-
    throw(error(unexpected_completion_outcome(Outcome),
                context(rlm_completion_final_handoff, expected_error))).

completion_options(Port, Planner, Options) :-
    format(atom(Endpoint),
           'http://127.0.0.1:~d/rlm_final_handoff',
           [Port]),
    Provider = provider(openai_compatible,
                        [endpoint(Endpoint),
                         credential(none),
                         model('test/final-handoff'),
                         timeout(5)]),
    Options = [ planner_handler(Planner),
                provider(Provider),
                provider_name(openai_compatible),
                capabilities([rlm,model(openai_compatible)]),
                child_capabilities([model(openai_compatible)]),
                budget(_{max_recursion_depth:1,
                         max_iterations:16,
                         max_model_calls:4,
                         max_total_tokens:8192,
                         max_output_bytes:131072,
                         time_limit:5.0})
              ].

with_handoff_server(Goal) :-
    setup_call_cleanup(
        start_final_handoff_server(Port),
        call(Goal, Port),
        stop_final_handoff_server(Port)).

known_query(Query) :- constraint_problem_prompt(Query).

known_solution_json(Json) :-
    constraint_known_solution(Solution),
    atom_json_dict(Atom, Solution, [width(0)]),
    atom_string(Atom, Json).

test(valid_planner_cannot_become_final_answer,
     []) :-
    with_handoff_server(run_direct_handoff_regression).

run_direct_handoff_regression(Port) :-
    known_query(Query),
    completion_options(
        Port,
        completion_final_handoff_support:final_handoff_planner,
        Options),
    rlm_completion(Query, text("opaque context"), Options, Outcome),
    expect_ok(Outcome, Result),
    get_dict(value, Result, FinalResponse),
    get_dict(text, FinalResponse, FinalText),
    assertion(is_dict(FinalResponse)),
    assertion(sub_string(FinalText, _, _, _, "assignments")),
    assertion(\+ sub_string(FinalText, _, _, _, "planner-leak")),
    constraint_verify_text(FinalText, ok(Verification)),
    assertion(Verification.status == passed),
    assertion(Result.plan \== Result.value),
    Result.trajectory.events = [Root, Model],
    assertion(Root.id == root_planner),
    assertion(Model.id == plan_model_1),
    final_handoff_requests([Request]),
    assertion(\+ request_has_planner_contract(Request)).

request_has_planner_contract(Request) :-
    get_dict(messages, Request, Messages),
    member(Message, Messages),
    get_dict(role, Message, Role),
    (Role == system ; Role == "system"),
    get_dict(content, Message, Content),
    text_content(Content, Text),
    sub_string(Text, _, _, _, "{\"steps\":[...]}").

text_content(Text, Text) :- string(Text), !.
text_content(Atom, Text) :- atom(Atom), atom_string(Atom, Text).

test(explicit_final_returns_materialized_value,
     []) :-
    with_handoff_server(run_explicit_final_regression).

run_explicit_final_regression(Port) :-
    completion_options(
        Port,
        completion_final_handoff_support:final_handoff_planner,
        Options0),
    append([skill_mode(off)], Options0, Options),
    rlm_completion("materialize the final model value",
                   text("opaque"),
                   Options,
                   Outcome),
    expect_ok(Outcome, Result),
    get_dict(value, Result, FinalResponse),
    get_dict(text, FinalResponse, FinalText),
    assertion(sub_string(FinalText, _, _, _, "assignments")).

test(recursive_model_final_value_survives_plan_execution,
     []) :-
    with_handoff_server(run_recursive_handoff_regression).

run_recursive_handoff_regression(Port) :-
    completion_options(
        Port,
        completion_final_handoff_support:recursive_final_handoff_planner,
        Options),
    rlm_completion("recursively materialize the final model value",
                   text("opaque"),
                   Options,
                   Outcome),
    expect_ok(Outcome, Result),
    get_dict(value, Result, FinalResponse),
    get_dict(text, FinalResponse, FinalText),
    get_dict(recursion, Result, Recursion),
    assertion(Recursion.recursive_calls =:= 1),
    assertion(Recursion.max_depth =:= 1),
    constraint_verify_text(FinalText, ok(Verification)),
    assertion(Verification.status == passed),
    assertion(Result.trajectory.events = [_, _]).

test(malformed_or_absent_final_fails_without_planner_fallback) :-
    completion_options(
        0,
        completion_final_handoff_support:missing_final_planner,
        Options0),
    append([skill_mode(off)], Options0, Options),
    rlm_completion("no final operation", text("opaque"), Options, Outcome),
    expect_error(Outcome, Error),
    assertion(Error.phase == planner),
    assertion(Error.kind == plan_validation_failed),
    assertion(Error.cause.phase == validate),
    assertion(Error.cause.detail == final_must_be_unique_and_last).

test(planner_shaped_execution_value_is_not_trusted_as_assignment,
     []) :-
    with_handoff_server(run_planner_value_rejection).

run_planner_value_rejection(Port) :-
    set_final_handoff_mode(planner),
    completion_options(
        Port,
        completion_final_handoff_support:final_handoff_planner,
        Options0),
    append([skill_mode(off)], Options0, Options),
    rlm_completion("return a task result", text("opaque"), Options, Outcome),
    expect_ok(Outcome, Result),
    get_dict(value, Result, FinalResponse),
    get_dict(text, FinalResponse, FinalText),
    assertion(sub_string(FinalText, _, _, _, "steps")),
    constraint_verify_text(FinalText, Verification),
    assertion(Verification = error(_)),
    constraint_verification_status(Verification, Status, Quality, _),
    assertion(Status == fail),
    assertion(Quality =:= 0.0).

test(text_final_answer_wins_over_reasoning_plan,
     []) :-
    with_handoff_server(run_mixed_channel_regression).

run_mixed_channel_regression(Port) :-
    set_final_handoff_mode(mixed),
    completion_options(
        Port,
        completion_final_handoff_support:final_handoff_planner,
        Options0),
    append([skill_mode(off)], Options0, Options),
    rlm_completion("separate final text from reasoning",
                   text("opaque"),
                   Options,
                   Outcome),
    expect_ok(Outcome, Result),
    get_dict(value, Result, FinalResponse),
    get_dict(text, FinalResponse, FinalText),
    get_dict(reasoning, FinalResponse, Reasoning),
    constraint_verify_text(FinalText, ok(Verification)),
    assertion(Verification.status == passed),
    assertion(sub_string(Reasoning, _, _, _, "steps")).

test(benchmark_normalization_uses_final_text_not_reasoning) :-
    known_solution_json(Json),
    Response = _{text:Json,
                 reasoning:"{\"steps\":[{\"op\":\"final\"}]}"},
    rlm_live_deep_experiment:result_response_text(Response, ok(Text)),
    assertion(Text == Json),
    constraint_verify_text(Text, ok(Verification)),
    assertion(Verification.status == passed).

test(benchmark_spec_verifier_accepts_executed_assignment) :-
    known_solution_json(Json),
    constraint_verify_text_via_spec(Json, ok(Verification)),
    assertion(Verification.status == passed),
    assertion(Verification.oracle_status == passed),
    assertion(Verification.requirement_status == passed).

test(later_model_result_is_the_only_final_value,
     []) :-
    with_handoff_server(run_multiple_model_regression).

run_multiple_model_regression(Port) :-
    set_final_handoff_mode(sequenced),
    completion_options(
        Port,
        completion_final_handoff_support:two_model_final_handoff_planner,
        Options0),
    append([skill_mode(off)], Options0, Options),
    rlm_completion("use the later model result",
                   text("opaque"),
                   Options,
                   Outcome),
    expect_ok(Outcome, Result),
    get_dict(value, Result, FinalResponse),
    get_dict(text, FinalResponse, FinalText),
    assertion(FinalText \== "EARLIER_MODEL_RESULT"),
    constraint_verify_text(FinalText, ok(Verification)),
    assertion(Verification.status == passed),
    final_handoff_requests([_, _]).

test(repair_does_not_replace_later_final_value,
     [setup(reset_repair_handoff)]) :-
    with_handoff_server(run_repair_regression).

run_repair_regression(Port) :-
    completion_options(
        Port,
        completion_final_handoff_support:repair_then_final_handoff_planner,
        Options0),
    append([skill_mode(off), planner_attempts(2)], Options0, Options),
    rlm_completion("repair the planner then execute the task",
                   text("opaque"),
                   Options,
                   Outcome),
    expect_ok(Outcome, Result),
    get_dict(value, Result, FinalResponse),
    get_dict(text, FinalResponse, FinalText),
    constraint_verify_text(FinalText, ok(Verification)),
    assertion(Verification.status == passed).

test(failed_final_execution_does_not_fallback_to_planner_data,
     []) :-
    with_handoff_server(run_failed_execution_regression).

run_failed_execution_regression(Port) :-
    set_final_handoff_mode(error),
    completion_options(
        Port,
        completion_final_handoff_support:final_handoff_planner,
        Options0),
    append([skill_mode(off)], Options0, Options),
    rlm_completion("fail before final materialization",
                   text("opaque"),
                   Options,
                   Outcome),
    expect_error(Outcome, Error),
    assertion(Error.phase == execute),
    assertion(Error.kind == model_error),
    assertion(\+ get_dict(value, Error, _)).

test(model_step_carries_scoped_system_message,
     []) :-
    with_handoff_server(run_system_message_regression).

run_system_message_regression(Port) :-
    completion_options(
        Port,
        completion_final_handoff_support:final_handoff_planner,
        Options0),
    append([skill_mode(off)], Options0, Options),
    rlm_completion("produce the task result", text("opaque"), Options,
                   Outcome),
    expect_ok(Outcome, _),
    final_handoff_requests([Request]),
    get_dict(messages, Request, [Identity, System, User]),
    get_dict(role, Identity, "system"),
    get_dict(content, Identity, IdentityText),
    get_dict(role, System, "system"),
    get_dict(content, System, SystemText),
    assertion(sub_string(SystemText, _, _, _, "bounded direct agent")),
    assertion(\+ sub_string(SystemText, _, _, _, "{\"steps\":")),
    assertion(\+ sub_string(SystemText, _, _, _, "RLM_OPERATE_BODY")),
    assertion(\+ sub_string(SystemText, _, _, _, "\"mode\":\"direct\"")),
    assertion(\+ sub_string(IdentityText, _, _, _, "{\"steps\":")),
    assertion(\+ sub_string(IdentityText, _, _, _, "RLM_OPERATE_BODY")),
    get_dict(role, User, "user"),
    get_dict(content, User, UserText),
    assertion(sub_string(UserText, _, _, _, "produce the task result")),
    assertion(\+ sub_string(UserText, _, _, _, "{\"steps\":[...]")).

test(native_tool_call_is_not_a_planner_or_final_result) :-
    completion_options(
        0,
        completion_final_handoff_support:native_tool_call_planner,
        Options0),
    append([skill_mode(off), planner_attempts(1)], Options0, Options),
    rlm_completion("native tool calls are not typed plans",
                   text("opaque"),
                   Options,
                   Outcome),
    expect_error(Outcome, Error),
    assertion(Error.phase == planner),
    assertion(Error.kind == plan_parse_failed),
    assertion(Error.cause.phase == normalize).

:- end_tests(rlm_completion_final_handoff).
