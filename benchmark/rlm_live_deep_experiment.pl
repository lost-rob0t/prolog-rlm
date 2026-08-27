:- encoding(utf8).

:- module(rlm_live_deep_experiment,
          [ live_deep_experiment_benchmark/1,
            benchmark_lane_instruction/3
          ]).

/** <module> REAL-provider recursive constraint-solving benchmark

This is the reasoning benchmark. It deliberately does not inject a fixed plan.
The root controller receives the normal minimal rlm_completion runtime contract
and a hard closed CSP query; it may answer directly or select a typed plan.
The report records the actual root decision and claims a plan parsed/validated
only when a plan actually executed. Correctness is decided by the trusted
Prolog oracle in rlm_constraint_problem and routed through the production
Frozen Spec / Verify path, never by model self-report or a magic output token.

Two lanes are compared at recursion ceilings 0/1/2:

  * core_minimal: no benchmark-specific planner instruction;
  * harness_guided: downstream-only decomposition guidance.

The former token-echo depth test survives as rlm_live_deep_smoke.
*/

:- use_module('../prolog/rlm').
:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/rlm_benchmark').
:- use_module('rlm_constraint_problem').
:- use_module('rlm_constraint_verify').

live_deep_experiment_benchmark(Report) :-
    require_openrouter_credential,
    require_unique_constraint_fixture,
    default_openrouter_model(Model),
    openrouter_provider(Model, Provider),
    findall(Case,
            ( member(Lane, [core_minimal,harness_guided]),
              between(0, 2, Depth),
              live_constraint_case(Lane, Depth, Model, Provider, Case) ),
            Cases),
    benchmark_report(deep_constraint_openrouter, Cases, Report).

live_constraint_case(Lane, Depth, Model, Provider, Case) :-
    constraint_problem_prompt(Query),
    lane_capabilities(Depth, Capabilities),
    lane_budget(Depth, Budget),
    benchmark_lane_instruction(Lane, Depth, InstructionOptions),
    BaseOptions = [ experimental_deep_recursion(true),
                    provider(Provider),
                    provider_name(openrouter),
                    capabilities(Capabilities),
                    child_capabilities(Capabilities),
                    planner_attempts(2),
                    planner_reasoning_effort(low),
                    planner_max_tokens(2400),
                    budget(Budget)
                  ],
    append(InstructionOptions, BaseOptions, Options),
    get_time(Start),
    rlm:rlm_completion(Query,
                       text("Closed benchmark problem; no external facts are required."),
                       Options,
                       Outcome),
    get_time(Stop),
    elapsed_ms(Start, Stop, LatencyMs),
    constraint_outcome_case(Lane,
                            Depth,
                            Model,
                            LatencyMs,
                            Outcome,
                            Case).

benchmark_lane_instruction(core_minimal, _, []).
benchmark_lane_instruction(harness_guided, Depth,
                           [planner_instruction(Guidance)]) :-
    constraint_guidance(Depth, Guidance).

lane_capabilities(0, [model(openrouter)]) :- !.
lane_capabilities(_, [rlm,model(openrouter)]).

lane_budget(Depth,
            _{max_iterations:32,
              max_recursion_depth:Depth,
              max_concurrent_subcalls:2,
              max_model_calls:ModelCalls,
              max_tool_calls:0,
              max_context_ops:0,
              max_total_tokens:TokenBudget,
              max_cost_usd:CostBudget,
              max_output_bytes:131072,
              time_limit:240.0}) :-
    ModelCalls is 6 + Depth*4,
    TokenBudget is 24000 + Depth*12000,
    CostBudget is 0.75 + Depth*0.50.

constraint_outcome_case(Lane,
                        RequestedDepth,
                        Model,
                        LatencyMs,
                        ok(Result),
                        Case) :-
    !,
    result_response_text(Result.value, TextOutcome),
    verify_response_text(TextOutcome, Verification),
    constraint_verification_status(Verification,
                                   Status,
                                   Quality,
                                   VerificationDetails),
    result_recursion(Result, ActualDepth, RecursiveCalls),
    result_selected_model(Result, SelectedModel),
    result_root_decision(Result, Decision, PlanParsed, PlanValidated),
    usage_metrics(Result.usage, LatencyMs, ActualDepth, Metrics),
    format(atom(Name), '~w_depth_~d', [Lane, RequestedDepth]),
    output_present(TextOutcome, OutputPresent),
    put_dict(_{lane:Lane,
               requested_model:Model,
               selected_model:SelectedModel,
               requested_recursion_depth:RequestedDepth,
               actual_recursion_depth:ActualDepth,
               recursive_calls:RecursiveCalls,
               root_decision:Decision,
               plan_parsed:PlanParsed,
               plan_validated:PlanValidated,
               fixed_plan_injected:false,
               planner_instruction:Lane,
               final_output_present:OutputPresent},
             VerificationDetails,
             Details),
    benchmark_case(Name,
                   constraint_reasoning,
                   Status,
                   Quality,
                   Metrics,
                   Details,
                   Case).
constraint_outcome_case(Lane,
                        RequestedDepth,
                        Model,
                        LatencyMs,
                        error(Error),
                        Case) :-
    format(atom(Name), '~w_depth_~d', [Lane, RequestedDepth]),
    safe_term(Error, Safe),
    benchmark_case(Name,
                   constraint_reasoning,
                   fail,
                   0.0,
                   _{latency_ms:LatencyMs,
                     recursion_depth:RequestedDepth},
                   _{lane:Lane,
                     requested_model:Model,
                     requested_recursion_depth:RequestedDepth,
                     plan_parsed:false,
                     plan_validated:false,
                     fixed_plan_injected:false,
                     verification_status:not_reached,
                     error:Safe},
                   Case).

verify_response_text(ok(Text), Verification) :-
    !,
    constraint_verify_text_via_spec(Text, Verification).
verify_response_text(error(Error), error(Error)).

result_response_text(Value, ok(Text)) :-
    string(Value),
    Value \== "",
    !,
    Text = Value.
result_response_text(Value, ok(Text)) :-
    atom(Value),
    Value \== '',
    !,
    atom_string(Value, Text).
result_response_text(Value, ok(Text)) :-
    is_dict(Value),
    get_dict(text, Value, Text),
    string(Text),
    Text \== "",
    !.
result_response_text(Value, ok(Text)) :-
    is_dict(Value),
    get_dict(reasoning, Value, Text),
    string(Text),
    Text \== "",
    !.
result_response_text(_, error(constraint_verification_error{
                                  phase:response,
                                  detail:"no textual final model output"
                              })).

output_present(ok(Text), true) :- string(Text), Text \== "", !.
output_present(_, false).

result_recursion(Result, Depth, Calls) :-
    (   get_dict(recursion, Result, Recursion),
        is_dict(Recursion)
    ->  dict_number(Recursion, max_depth, 0, Depth),
        dict_number(Recursion, recursive_calls, 0, Calls)
    ;   Depth = 0,
        Calls = 0
    ).

% Truthful root-decision reporting: a direct completion executed no typed
% plan, so plan_parsed/plan_validated must not claim one ran. Only an
% executed plan result carries a parsed and validated plan.
result_root_decision(Result, direct, false, false) :-
    get_dict(plan, Result, none),
    !.
result_root_decision(Result, plan, true, true) :-
    get_dict(plan, Result, _).

result_selected_model(Result, Model) :-
    (   get_dict(trajectory, Result, Trajectory),
        is_dict(Trajectory),
        get_dict(root_event, Trajectory, Root),
        is_dict(Root),
        get_dict(selected_model, Root, Selected)
    ->  Model = Selected
    ;   Model = unknown
    ).

usage_metrics(Usage, LatencyMs, Depth,
              _{model_calls:ModelCalls,
                prompt_tokens:PromptTokens,
                completion_tokens:CompletionTokens,
                total_tokens:TotalTokens,
                cost_usd:CostUsd,
                latency_ms:LatencyMs,
                recursion_depth:Depth}) :-
    dict_number(Usage, model_calls, 0, ModelCalls),
    dict_number(Usage, prompt_tokens, 0, PromptTokens),
    dict_number(Usage, completion_tokens, 0, CompletionTokens),
    dict_number(Usage, total_tokens, 0, TotalTokens),
    dict_number(Usage, cost_usd, 0.0, CostUsd).

dict_number(Dict, Key, Default, Value) :-
    (   is_dict(Dict),
        get_dict(Key, Dict, Found),
        number(Found),
        Found >= 0
    ->  Value = Found
    ;   Value = Default
    ).

require_unique_constraint_fixture :-
    constraint_solution_count(Count),
    (   Count =:= 1
    ->  true
    ;   throw(error(constraint_fixture_not_unique(Count),
                    context(rlm_live_deep_experiment,
                            'live benchmark fixture must have exactly one satisfying assignment')))
    ).

elapsed_ms(Start, Stop, Milliseconds) :-
    Raw is (Stop-Start)*1000.0,
    Milliseconds is max(0, round(Raw)).

safe_term(Term, Safe) :-
    term_string(Term, Safe, [quoted(true), numbervars(true)]).

require_openrouter_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '', Key \== ""
    ->  true
    ;   throw(error(missing_live_credential('OPENROUTER_API_KEY'),
                    context(rlm_live_deep_experiment,
                            'OPENROUTER_API_KEY is required for live constraint benchmarking')))
    ).
