:- module(completion_test_support,
          [ direct_planner/2,
            depth_two_planner/2,
            duplicate_recursive_planner/2,
            child_tool_planner/2,
            invalid_planner/2,
            fake_model/2,
            slow_model/2,
            token_heavy_model/2,
            costly_model/2,
            reset_calls/0,
            planner_calls/1,
            model_calls/1
          ]).

:- dynamic planner_call_count/1.
:- dynamic model_call_count/1.

reset_calls :-
    retractall(planner_call_count(_)),
    retractall(model_call_count(_)),
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

fake_model(_, ok(Response)) :-
    bump_model,
    fake_response("FAKE_MODEL_OK", Response).

slow_model(_, ok(Response)) :-
    bump_model,
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
