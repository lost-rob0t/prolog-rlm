:- module(rlm_live_benchmark,
          [ live_openrouter_benchmark/1
          ]).

/** <module> Optional real-provider benchmark mode */

:- use_module('../prolog/rlm_benchmark').
:- use_module('../prolog/rlm_chain').

live_openrouter_benchmark(Report) :-
    require_openrouter_credential,
    get_time(Start),
    catch(run_openrouter_case(Outcome),
          Exception,
          Outcome = exception(Exception)),
    get_time(End),
    ElapsedMs is max(0, round((End-Start)*1000)),
    live_case(Outcome, ElapsedMs, Case),
    benchmark_report(openrouter_integration, [Case], Report).

run_openrouter_case(outcome(RequestedModel, ProviderOutcome)) :-
    default_openrouter_model(RequestedModel),
    openrouter_provider(RequestedModel, Provider),
    Request = model_request{
                  messages:[message{
                                role:user,
                                content:"Reply with the token PROLOG_RLM_BENCHMARK_OK."
                            }],
                  options:_{max_tokens:32}
              },
    model_complete(Provider, Request, ProviderOutcome).

live_case(outcome(RequestedModel, ok(Response)), ElapsedMs, Case) :-
    !,
    response_quality(Response, Quality, Status, QualityDetails),
    usage_metrics(Response.usage, UsageMetrics),
    put_dict(_{model_calls:1,
               latency_ms:ElapsedMs,
               recursion_depth:0},
             UsageMetrics,
             Metrics),
    Details = _{provider:openrouter,
                requested_model:RequestedModel,
                selected_model:Response.selected_model,
                http_status:Response.metadata.http_status,
                response_received:Response.metadata.response_received,
                usage_present:Response.usage.present,
                quality:QualityDetails},
    benchmark_case(openrouter_direct,
                   provider,
                   Status,
                   Quality,
                   Metrics,
                   Details,
                   Case).
live_case(outcome(RequestedModel, error(Error)), ElapsedMs, Case) :-
    !,
    term_string(Error, Safe, [quoted(true), numbervars(true)]),
    benchmark_case(openrouter_direct,
                   provider,
                   fail,
                   0.0,
                   _{model_calls:1, latency_ms:ElapsedMs},
                   _{provider:openrouter,
                     requested_model:RequestedModel,
                     reason:provider_error,
                     error:Safe},
                   Case).
live_case(exception(Exception), ElapsedMs, Case) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    benchmark_case(openrouter_direct,
                   provider,
                   fail,
                   0.0,
                   _{model_calls:1, latency_ms:ElapsedMs},
                   _{provider:openrouter,
                     reason:exception,
                     exception:Safe},
                   Case).

% Integration status answers whether the provider/runtime produced a usable
% assistant response. Quality separately grades instruction compliance. This
% matters for aliases such as openrouter/free, whose selected model and output
% channel can vary between runs even when the provider path is healthy.
response_quality(Response, 1.0, pass,
                 _{expected_token:true, assistant_output:true}) :-
    expected_token_present(Response),
    !.
response_quality(Response, 0.5, pass,
                 _{expected_token:false, assistant_output:true}) :-
    assistant_output_present(Response, true),
    !.
response_quality(_, 0.0, fail,
                 _{expected_token:false, assistant_output:false}).

expected_token_present(Response) :-
    response_channel_text(Response, Text),
    sub_string(Text, _, _, _, "PROLOG_RLM_BENCHMARK_OK"),
    !.

response_channel_text(Response, Text) :-
    response_text(Response, Text),
    Text \== "".
response_channel_text(Response, Reasoning) :-
    get_dict(reasoning, Response, Reasoning),
    string(Reasoning),
    Reasoning \== "".

response_text(Response, Text) :-
    (   get_dict(text, Response, Value),
        string(Value)
    ->  Text = Value
    ;   Text = ""
    ).

assistant_output_present(Response, true) :-
    response_channel_text(Response, _),
    !.
assistant_output_present(Response, true) :-
    get_dict(tool_calls, Response, ToolCalls),
    is_list(ToolCalls),
    ToolCalls \== [],
    !.
assistant_output_present(_, false).

usage_metrics(Usage,
              _{prompt_tokens:PromptTokens,
                completion_tokens:CompletionTokens,
                total_tokens:TotalTokens,
                cost_usd:CostUsd}) :-
    optional_nonnegative(Usage.prompt_tokens, 0, PromptTokens),
    optional_nonnegative(Usage.completion_tokens, 0, CompletionTokens),
    optional_nonnegative(Usage.total_tokens, 0, TotalTokens),
    optional_nonnegative(Usage.cost, 0.0, CostUsd).

optional_nonnegative(null, Default, Default) :- !.
optional_nonnegative(Value, _, Value) :-
    number(Value),
    Value >= 0,
    !.
optional_nonnegative(_, Default, Default).

require_openrouter_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '',
        Key \== ""
    ->  true
    ;   throw(error(missing_live_credential('OPENROUTER_API_KEY'),
                    context(rlm_live_benchmark,
                            'integration benchmark requires OPENROUTER_API_KEY')))
    ).
