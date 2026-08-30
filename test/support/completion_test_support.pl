:- module(completion_test_support,
           [ direct_planner/2,
             direct_root_answer/2,
             empty_direct_answer/2,
             extra_field_direct_answer/2,
             unsupported_mode_direct_answer/2,
             context_slice_planner/2,
             depth_two_planner/2,
            model_step_planner/2,
            duplicate_recursive_planner/2,
            anonymous_dict_grandchild_tool_planner/2,
            nonground_recursive_planner/2,
            cyclic_recursive_planner/2,
            child_tool_planner/2,
             invalid_planner/2,
             capture_planner/2,
             capture_retry_planner/2,
             capture_missing_name_retry_planner/2,
             capture_envelope_retry_planner/2,
             capture_model/2,
             last_planner_request/1,
             planner_requests/1,
            last_model_request/1,
            fake_model/2,
            slow_model/2,
            slow_model_started/3,
            token_heavy_model/2,
            costly_model/2,
            reset_calls/0,
            planner_calls/1,
            model_calls/1
          ]).

:- dynamic planner_call_count/1.
:- dynamic model_call_count/1.
:- dynamic last_planner_request/1.
:- dynamic last_model_request/1.
:- dynamic captured_planner_request/2.

reset_calls :-
    retractall(planner_call_count(_)),
    retractall(model_call_count(_)),
    retractall(last_planner_request(_)),
    retractall(last_model_request(_)),
    retractall(captured_planner_request(_, _)),
    assertz(planner_call_count(0)),
    assertz(model_call_count(0)).

planner_calls(Count) :- planner_call_count(Count).
model_calls(Count) :- model_call_count(Count).

bump_planner :-
    retract(planner_call_count(Count0)),
    Count is Count0+1,
    assertz(planner_call_count(Count)).

bump_model :-
    retract(model_call_count(Count0)),
    Count is Count0+1,
    assertz(model_call_count(Count)).

planner_output(Plan,
               planner_output{plan:Plan,
                              usage:_{prompt_tokens:1,
                                      completion_tokens:1,
                                      total_tokens:2,
                                      cost:0.0}}).

direct_planner(_, ok(Output)) :-
    bump_planner,
    Plan = plan([final(literal("direct-ok"))]),
    planner_output(Plan, Output).

direct_root_answer(_, ok(Response)) :-
    bump_planner,
    fake_response("{\"mode\":\"direct\",\"answer\":\"direct-root-ok\"}",
                  Response).

empty_direct_answer(_, ok(Response)) :-
    bump_planner,
    fake_response("{\"mode\":\"direct\",\"answer\":\"\"}",
                  Response).

extra_field_direct_answer(_, ok(Response)) :-
    bump_planner,
    fake_response("{\"mode\":\"direct\",\"answer\":\"x\",\"extra\":1}",
                  Response).

unsupported_mode_direct_answer(_, ok(Response)) :-
    bump_planner,
    fake_response("{\"mode\":\"auto\",\"answer\":\"x\"}",
                  Response).

context_slice_planner(_, ok(Output)) :-
    bump_planner,
    Plan = plan([context(input(context),
                         slice(0, 1024),
                         evidence),
                 final(literal("context-plan-ok"))]),
    planner_output(Plan, Output).

model_step_planner(_, ok(Output)) :-
    bump_planner,
    Plan = plan([model(openrouter,
                       literal("native step task: fetch the token"),
                       _{},
                       reply),
                 final(field(var(reply), text))]),
    planner_output(Plan, Output).

depth_two_planner(_, ok(Output)) :-
    bump_planner,
    Grandchild = plan([final(literal("grandchild"))]),
    Child = plan([rlm(Grandchild, grand),
                  final(var(grand))]),
    Plan = plan([rlm(Child, child),
                 final(var(child))]),
    planner_output(Plan, Output).

duplicate_recursive_planner(_, ok(Output)) :-
    bump_planner,
    Child = plan([final(literal("same-child"))]),
    Plan = plan([rlm(Child, first),
                 rlm(Child, second),
                 final(var(first))]),
    planner_output(Plan, Output).

anonymous_dict_grandchild_tool_planner(_, ok(Output)) :-
    bump_planner,
    Grandchild = plan([tool(secret_tool,
                            literal(_{secret:true}),
                            secret),
                       final(var(secret))]),
    Child = plan([rlm(Grandchild, grand),
                  final(var(grand))]),
    Plan = plan([rlm(Child, child),
                 final(var(child))]),
    planner_output(Plan, Output).

nonground_recursive_planner(_, ok(Output)) :-
    bump_planner,
    Child = plan([final(literal(Unbound))]),
    Plan = plan([rlm(Child, child),
                 final(var(child))]),
    planner_output(Plan, Output),
    var(Unbound).

cyclic_recursive_planner(_, ok(Output)) :-
    bump_planner,
    Child = plan([rlm(Child, loop)]),
    Plan = plan([rlm(Child, child),
                 final(var(child))]),
    planner_output(Plan, Output).

child_tool_planner(_, ok(Output)) :-
    bump_planner,
    Child = plan([tool(secret_tool,
                       literal(_{value:1}),
                       secret),
                  final(var(secret))]),
    Plan = plan([rlm(Child, child),
                 final(var(child))]),
    planner_output(Plan, Output).

invalid_planner(_, ok(Response)) :-
    bump_planner,
    fake_response("not a typed plan", Response).

capture_planner(Request, ok(Output)) :-
    bump_planner,
    retractall(last_planner_request(_)),
    assertz(last_planner_request(Request)),
    Plan = plan([final(literal("captured-planner"))]),
    planner_output(Plan, Output).

capture_retry_planner(Request, ok(Output)) :-
    bump_planner,
    planner_calls(Call),
    assertz(captured_planner_request(Call, Request)),
    (   Call =:= 1
    ->  fake_response("not a typed plan", Output)
    ;   Plan = plan([final(literal("captured-retry"))]),
        planner_output(Plan, Output)
    ).

capture_missing_name_retry_planner(Request, ok(Output)) :-
    bump_planner,
    planner_calls(Call),
    assertz(captured_planner_request(Call, Request)),
    (   Call =:= 1
    ->  fake_response(
            "{\"steps\":[{\"op\":\"tool\",\"args\":{\"private\":\"MUST_NOT_ECHO\"},\"bind\":\"result\"},{\"op\":\"final\",\"value\":1}]}",
            Output)
    ;   Plan = plan([final(literal("repaired"))]),
        planner_output(Plan, Output)
    ).

% Attempt 1 selects a tool-result key directly from the tool binding
% (one hop); the runtime must reject it with the envelope fault and the
% repair message must teach the corrected two-hop form. Attempt 2 answers
% directly so the test never executes the tool.
capture_envelope_retry_planner(Request, ok(Output)) :-
    bump_planner,
    planner_calls(Call),
    assertz(captured_planner_request(Call, Request)),
    (   Call =:= 1
    ->  format(string(BadPlan),
               "{\"steps\":[{\"op\":\"tool\",\"name\":\"probe\",\"args\":{},\"bind\":\"result\"},{\"op\":\"final\",\"value\":{\"ref\":\"field\",\"value\":{\"ref\":\"var\",\"name\":\"result\"},\"key\":\"content\"}}]}",
               []),
        fake_response(BadPlan, Output)
    ;   fake_response("{\"mode\":\"direct\",\"answer\":\"envelope_repaired\"}",
                      Output)
    ).

planner_requests(Requests) :-
    findall(Request,
            captured_planner_request(_, Request),
            Requests).

capture_model(Request, ok(Response)) :-
    bump_model,
    retractall(last_model_request(_)),
    assertz(last_model_request(Request)),
    fake_response("CAPTURED_MODEL_OK", Response).

fake_model(_, ok(Response)) :-
    bump_model,
    fake_response("FAKE_MODEL_OK", Response).

slow_model(_, ok(Response)) :-
    bump_model,
    sleep(5),
    fake_response("SLOW_MODEL_OK", Response).

slow_model_started(Queue, _, ok(Response)) :-
    bump_model,
    thread_send_message(Queue, started),
    sleep(5),
    fake_response("SLOW_MODEL_OK", Response).

token_heavy_model(_, ok(Response)) :-
    bump_model,
    fake_response_with_usage("TOKEN_HEAVY",
                             40,
                             20,
                             60,
                             0.0,
                             Response).

costly_model(_, ok(Response)) :-
    bump_model,
    fake_response_with_usage("COSTLY_MODEL",
                             2,
                             1,
                             3,
                             0.5,
                             Response).

fake_response(Text, Response) :-
    fake_response_with_usage(Text, 2, 1, 3, 0.0, Response).

fake_response_with_usage(
    Text,
    PromptTokens,
    CompletionTokens,
    TotalTokens,
    Cost,
    model_response{provider:fake,
                   requested_model:fake,
                   selected_model:fake,
                   text:Text,
                   reasoning:"",
                   tool_calls:[],
                   finish_reason:stop,
                   usage:usage{present:true,
                               prompt_tokens:PromptTokens,
                               completion_tokens:CompletionTokens,
                               total_tokens:TotalTokens,
                               cost:Cost},
                   metadata:metadata{http_status:200,
                                     response_received:true}}).

:- initialization(reset_calls).
