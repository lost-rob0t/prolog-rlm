:- module(rlm_live_deep_experiment,
          [ live_deep_experiment_benchmark/1
          ]).

/** <module> REAL-provider depth 0/1/2 experiment

This benchmark uses a trusted injected typed plan so provider calls measure the
nested execution tree rather than a model's ability to reproduce a known plan.
It records real OpenRouter usage/latency, but never promotes deep recursion.
*/

:- use_module('../prolog/rlm').
:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/rlm_benchmark').

live_deep_experiment_benchmark(Report) :-
    require_openrouter_credential,
    default_openrouter_model(Model),
    openrouter_provider(Model, Provider),
    findall(Case,
            ( between(0, 2, Depth),
              live_depth_case(Depth, Model, Provider, Case) ),
            Cases),
    benchmark_report(deep_openrouter_experiment, Cases, Report).

live_depth_case(Depth, Model, Provider, Case) :-
    Prompt = "Reply exactly with LIVE_DEEP_OK and nothing else.",
    live_depth_plan(Depth, Prompt, Plan),
    live_depth_budget(Depth, Budget),
    Options = [ experimental_deep_recursion(true),
                provider(Provider),
                provider_name(openrouter),
                planner_handler(
                    rlm_live_deep_experiment:fixed_planner(Plan)),
                capabilities([rlm, model(openrouter)]),
                child_capabilities([rlm, model(openrouter)]),
                budget(Budget)
              ],
    get_time(Start),
    rlm:rlm_completion("Execute the fixed live depth experiment.",
                       text("LIVE_DEEP_OK"),
                       Options,
                       Outcome),
    get_time(Stop),
    elapsed_ms(Start, Stop, LatencyMs),
    live_depth_outcome(Depth,
                       Model,
                       LatencyMs,
                       Outcome,
                       Case).

live_depth_plan(0, Prompt,
                plan([model(openrouter,
                            literal(Prompt),
                            model_options{max_tokens:64,
                                          temperature:0},
                            model_0),
                      final(var(model_0))])) :- !.
live_depth_plan(Depth, Prompt,
                plan([model(openrouter,
                            literal(Prompt),
                            model_options{max_tokens:64,
                                          temperature:0},
                            ModelBind),
                      rlm(Child, ChildBind),
                      final(var(ChildBind))])) :-
    Depth > 0,
    ChildDepth is Depth-1,
    live_depth_plan(ChildDepth, Prompt, Child),
    format(atom(ModelBind), 'live_model_~d', [Depth]),
    format(atom(ChildBind), 'live_child_~d', [Depth]).

live_depth_budget(Depth,
                  _{max_iterations:16,
                    max_recursion_depth:Depth,
                    max_concurrent_subcalls:1,
                    max_model_calls:4,
                    max_tool_calls:0,
                    max_context_ops:0,
                    max_total_tokens:3000,
                    max_cost_usd:0.25,
                    max_output_bytes:32768,
                    time_limit:120.0}).

fixed_planner(Plan, _, ok(Output)) :-
    Output = planner_output{
                 plan:Plan,
                 usage:_{prompt_tokens:0,
                         completion_tokens:0,
                         total_tokens:0,
                         cost:0.0}
             }.

live_depth_outcome(Depth, Model, LatencyMs, ok(Result), Case) :-
    !,
    response_quality(Result.value, Quality, OutputPresent, ExpectedPresent),
    ( OutputPresent == true -> Status = pass ; Status = fail ),
    ProviderCalls is max(0, Result.usage.model_calls-1),
    selected_model(Result.value, SelectedModel),
    response_http_status(Result.value, HttpStatus),
    Metrics = _{model_calls:ProviderCalls,
                prompt_tokens:Result.usage.prompt_tokens,
                completion_tokens:Result.usage.completion_tokens,
                total_tokens:Result.usage.total_tokens,
                cost_usd:Result.usage.cost_usd,
                latency_ms:LatencyMs,
                recursion_depth:Result.recursion.max_depth},
    format(atom(Name), 'openrouter_depth_~d', [Depth]),
    Details = live_deep_details{
                  requested_model:Model,
                  selected_model:SelectedModel,
                  http_status:HttpStatus,
                  response_present:OutputPresent,
                  expected_token_present:ExpectedPresent,
                  injected_planner:true,
                  injected_planner_provider_calls:0,
                  actual_provider_calls:ProviderCalls
              },
    benchmark_case(Name,
                   live_deep_recursion,
                   Status,
                   Quality,
                   Metrics,
                   Details,
                   Case).
live_depth_outcome(Depth, Model, LatencyMs, error(Error), Case) :-
    format(atom(Name), 'openrouter_depth_~d', [Depth]),
    benchmark_case(Name,
                   live_deep_recursion,
                   fail,
                   0.0,
                   _{latency_ms:LatencyMs,
                     recursion_depth:Depth},
                   live_deep_error{
                       requested_model:Model,
                       error:Error
                   },
                   Case).

response_quality(Response, 1.0, true, true) :-
    response_channel_text(Response, Text),
    sub_string(Text, _, _, _, "LIVE_DEEP_OK"),
    !.
response_quality(Response, 0.5, true, false) :-
    usable_response(Response),
    !.
response_quality(_, 0.0, false, false).

usable_response(Response) :-
    response_channel_text(Response, _),
    !.
usable_response(Response) :-
    is_dict(Response),
    get_dict(tool_calls, Response, Calls),
    is_list(Calls),
    Calls \== [].

response_channel_text(Response, Text) :-
    is_dict(Response),
    get_dict(text, Response, Text),
    string(Text),
    Text \== "",
    !.
response_channel_text(Response, Text) :-
    is_dict(Response),
    get_dict(reasoning, Response, Text),
    string(Text),
    Text \== "".

selected_model(Response, Model) :-
    (   is_dict(Response),
        get_dict(selected_model, Response, Found)
    ->  Model = Found
    ;   Model = unknown
    ).

response_http_status(Response, Status) :-
    (   is_dict(Response),
        get_dict(metadata, Response, Metadata),
        is_dict(Metadata),
        get_dict(http_status, Metadata, Found)
    ->  Status = Found
    ;   Status = 0
    ).

elapsed_ms(Start, Stop, Milliseconds) :-
    Raw is (Stop-Start)*1000.0,
    Milliseconds is max(0, round(Raw)).

require_openrouter_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '',
        Key \== ""
    ->  true
    ;   throw(error(missing_live_credential('OPENROUTER_API_KEY'),
                    context(rlm_live_deep_experiment,
                            'OPENROUTER_API_KEY is required for live deep-recursion benchmarking')))
    ).
