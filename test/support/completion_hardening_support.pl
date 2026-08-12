:- module(completion_hardening_support,
          [ root_parallel_planner/2,
            root_only_tool/2,
            nonground_model/2
          ]).

root_parallel_planner(_, ok(Output)) :-
    Branch = plan([tool(root_only, literal(7), value),
                   final(var(value))]),
    Plan = plan([parallel([Branch], results),
                 final(var(results))]),
    Output = planner_output{
                 plan:Plan,
                 usage:_{prompt_tokens:1,
                         completion_tokens:1,
                         total_tokens:2,
                         cost:0.0}
             }.

root_only_tool(Value, Value).

nonground_model(_, ok(Response)) :-
    Response = model_response{
                   provider:fake,
                   requested_model:fake,
                   selected_model:fake,
                   text:"NON_GROUND_OK",
                   reasoning:"",
                   reasoning_details:[_Opaque],
                   tool_calls:[],
                   finish_reason:stop,
                   usage:usage{present:true,
                               prompt_tokens:2,
                               completion_tokens:1,
                               total_tokens:3,
                               cost:0.0},
                   metadata:metadata{http_status:200,
                                     response_received:true}
               }.
