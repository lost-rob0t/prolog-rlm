:- module(rlm_deep_experiment,
          [ rlm_deep_experiment_ready/0,
            default_deep_experiment_policy/1,
            deep_experiment_run/2,
            deep_experiment_promotion/2
          ]).

/** <module> Explicit depth>1 recursion experiment harness

This module does not change production recursion defaults.  It exercises the
existing typed-plan, agent, artifact, and benchmark runtimes behind an explicit
experimental opt-in and records promotion evidence.  Deterministic fixture
usage is deliberately modeled; it is not provider billing evidence.
*/

:- use_module(library(option)).
:- use_module(library(lists)).
:- use_module(rlm_plan).
:- use_module(rlm_agent).
:- use_module(rlm_artifact).
:- use_module(rlm_benchmark).

rlm_deep_experiment_ready.

default_deep_experiment_policy(
    deep_experiment_policy{
        min_live_trials:20,
        min_independent_fixtures:3,
        min_quality_delta:0.05,
        max_cost_ratio:1.50,
        max_latency_ratio:2.00
    }).

deep_experiment_run(Options, Outcome) :-
    catch(( deep_experiment_run_(Options, Result),
            Outcome = ok(Result) ),
          Exception,
          deep_experiment_exception(run, Exception, Outcome)).

deep_experiment_run_(Options, Result) :-
    require_options(Options),
    require_experimental_flag(Options),
    deterministic_depth_cases(DepthCases),
    delegated_agent_case(AgentCase),
    fresh_root_artifact_case(ArtifactCase),
    global_budget_case(BudgetCase),
    append(DepthCases,
           [AgentCase, ArtifactCase, BudgetCase],
           Cases),
    benchmark_report(deep_recursion_experiment, Cases, Report),
    depth_comparisons(DepthCases, Comparisons),
    classification_summary(Comparisons, ClassificationSummary),
    synthetic_promotion_evidence(Evidence),
    deep_experiment_promotion(Evidence, Promotion),
    Result = deep_experiment_result{
                 status:Report.status,
                 experimental:true,
                 report:Report,
                 comparisons:Comparisons,
                 classification_summary:ClassificationSummary,
                 promotion:Promotion,
                 evidence:Evidence,
                 disclaimer:"deterministic depth fixtures use modeled provider usage; they prove orchestration and policy behavior, not live model economics or quality"
             }.

require_experimental_flag(Options) :-
    option(experimental_deep_recursion(Enabled), Options, false),
    (   Enabled == true
    ->  true
    ;   throw(deep_experiment_fault(experimental_flag_required))
    ).

/* -------------------------------------------------------------------------
 * Depth 0/1/2 deterministic fixtures
 * ---------------------------------------------------------------------- */

deterministic_depth_cases(Cases) :-
    findall(Case,
            ( fixture(Fixture),
              between(0, 2, Depth),
              depth_fixture_case(Fixture, Depth, Case) ),
            Cases).

fixture(trivial).
fixture(two_stage).
fixture(three_stage).
fixture(tradeoff).

fixture_quality(trivial, _, 1.00).
fixture_quality(two_stage, 0, 0.50).
fixture_quality(two_stage, 1, 1.00).
fixture_quality(two_stage, 2, 1.00).
fixture_quality(three_stage, 0, 0.33).
fixture_quality(three_stage, 1, 0.67).
fixture_quality(three_stage, 2, 1.00).
fixture_quality(tradeoff, 0, 0.80).
fixture_quality(tradeoff, 1, 0.90).
fixture_quality(tradeoff, 2, 0.95).

depth_fixture_case(Fixture, Depth, Case) :-
    fixture_quality(Fixture, Depth, Quality),
    format(atom(Expected), '~w-depth-~d-ok', [Fixture, Depth]),
    nested_literal_plan(Depth, Expected, Plan),
    plan_shape_budget(Depth, Budget),
    get_time(Start),
    plan_run(Plan,
             [rlm],
             [budget(Budget)],
             _{},
             PlanOutcome),
    get_time(Stop),
    require_plan_success(Fixture, Depth, PlanOutcome, Result),
    (   Result.value == Expected
    ->  true
    ;   throw(deep_experiment_fault(
                  unexpected_depth_value(Fixture,
                                         Depth,
                                         Expected,
                                         Result.value)))
    ),
    elapsed_ms(Start, Stop, LatencyMs),
    modeled_depth_metrics(Depth, LatencyMs, Metrics),
    format(atom(Name), '~w_depth_~d', [Fixture, Depth]),
    Details = deep_fixture_details{
                  fixture:Fixture,
                  depth:Depth,
                  expected:Expected,
                  modeled_usage:true,
                  measured_orchestration_latency:true,
                  plan_budget_remaining:Result.budget_remaining,
                  disclaimer:"token/call/cost figures are fixed comparison fixtures, not provider measurements"
              },
    benchmark_case(Name,
                   deep_recursion_fixture,
                   pass,
                   Quality,
                   Metrics,
                   Details,
                   Case).

nested_literal_plan(0, Expected,
                    plan([final(literal(Expected))])) :- !.
nested_literal_plan(Depth, Expected,
                    plan([rlm(Child, Bind),
                          final(var(Bind))])) :-
    Depth > 0,
    ChildDepth is Depth-1,
    nested_literal_plan(ChildDepth, Expected, Child),
    format(atom(Bind), 'depth_~d_result', [Depth]).

plan_shape_budget(Depth, Budget) :-
    MaxDepth is Depth+1,
    MaxSteps is 2*Depth+1,
    Budget = _{max_steps:MaxSteps,
               max_depth:MaxDepth,
               max_model_calls:0,
               max_tool_calls:0,
               max_context_ops:0,
               max_output_bytes:65536,
               time_limit:2.0}.

modeled_depth_metrics(Depth, LatencyMs,
                      _{model_calls:Calls,
                        prompt_tokens:PromptTokens,
                        completion_tokens:CompletionTokens,
                        total_tokens:TotalTokens,
                        cost_usd:Cost,
                        latency_ms:LatencyMs,
                        recursion_depth:Depth}) :-
    Calls is Depth+1,
    PromptTokens is 24*Calls,
    CompletionTokens is 8*Calls,
    TotalTokens is PromptTokens+CompletionTokens,
    Cost is 0.001*Calls.

require_plan_success(_, _, ok(Result), Result) :- !.
require_plan_success(Fixture, Depth, Outcome, _) :-
    throw(deep_experiment_fault(
              depth_plan_failed(Fixture, Depth, Outcome))).

elapsed_ms(Start, Stop, Milliseconds) :-
    Raw is (Stop-Start)*1000.0,
    Milliseconds is max(0, round(Raw)).

/* -------------------------------------------------------------------------
 * Delegated supervised-agent comparison
 * ---------------------------------------------------------------------- */

delegated_agent_case(Case) :-
    get_time(Start),
    setup_call_cleanup(
        agent_runtime_create(
            [ root_capabilities([tool(delegate)]),
              worker_count(1),
              mailbox_size(4),
              send_timeout(0.0)
            ],
            Runtime),
        delegated_agent_case_(Runtime, Details0),
        agent_runtime_destroy(Runtime)),
    get_time(Stop),
    elapsed_ms(Start, Stop, LatencyMs),
    Metrics = _{model_calls:2,
                prompt_tokens:48,
                completion_tokens:16,
                total_tokens:64,
                cost_usd:0.0024,
                latency_ms:LatencyMs,
                recursion_depth:0},
    put_dict(_{modeled_usage:true,
               disclaimer:"provider usage is modeled; supervision, narrowing, handoff, and cancellation are executed by the real agent runtime"},
             Details0,
             Details),
    benchmark_case(delegated_subagent,
                   recursive_agent_harness,
                   pass,
                   1.0,
                   Metrics,
                   Details,
                   Case).

delegated_agent_case_(Runtime, Details) :-
    Runtime = agent_runtime(RunId),
    agent_spawn(Runtime,
                none,
                agent_spec(experiment_root),
                [tool(delegate)],
                ok(Root)),
    agent_spawn(Runtime,
                Root,
                agent_spec(experiment_child),
                [],
                ok(Child)),
    agent_spawn(Runtime,
                Child,
                agent_spec(widening_grandchild),
                [tool(extra)],
                WideningOutcome),
    require_capability_denial(WideningOutcome),
    agent_send(Runtime,
               Child,
               checkpoint(RunId, delegated_result),
               [],
               ok(_)),
    agent_pump(Runtime, Child, [], ok(_)),
    agent_status(Runtime, Child, ok(ChildBeforeCancel)),
    (   memberchk(delegated_result, ChildBeforeCancel.checkpoints)
    ->  true
    ;   throw(deep_experiment_fault(agent_handoff_missing))
    ),
    agent_cancel(Runtime, Root, experiment_cancel, ok(_)),
    agent_status(Runtime, Root, ok(RootAfterCancel)),
    agent_status(Runtime, Child, ok(ChildAfterCancel)),
    (   RootAfterCancel.status == cancelled(experiment_cancel),
        ChildAfterCancel.status == cancelled(experiment_cancel)
    ->  true
    ;   throw(deep_experiment_fault(agent_cancellation_not_propagated))
    ),
    agent_trace(Runtime, Trace),
    length(Trace, TraceEvents),
    Details = agent_experiment_details{
                  capability_narrowing:true,
                  widening_denied:true,
                  checkpoint_handoff:true,
                  cancellation_propagated:true,
                  trace_events:TraceEvents
              }.

require_capability_denial(error(Error)) :-
    is_dict(Error),
    get_dict(kind, Error, capability_denied),
    !.
require_capability_denial(Outcome) :-
    throw(deep_experiment_fault(
              expected_capability_denial(Outcome))).

/* -------------------------------------------------------------------------
 * Fresh-root artifact comparison
 * ---------------------------------------------------------------------- */

fresh_root_artifact_case(Case) :-
    artifact_store_open(memory, OpenOutcome),
    require_artifact_ok(open, OpenOutcome, Store),
    get_time(Start),
    setup_call_cleanup(
        true,
        fresh_root_artifact_case_(Store, Details0),
        artifact_store_close(Store, _)),
    get_time(Stop),
    elapsed_ms(Start, Stop, LatencyMs),
    Metrics = _{model_calls:2,
                prompt_tokens:32,
                completion_tokens:12,
                total_tokens:44,
                cost_usd:0.0018,
                latency_ms:LatencyMs,
                recursion_depth:0},
    put_dict(_{modeled_usage:true,
               disclaimer:"provider usage is modeled; artifact publication and fresh-root consumption use the real artifact runtime"},
             Details0,
             Details),
    benchmark_case(fresh_root_artifact,
                   fresh_root_handoff,
                   pass,
                   1.0,
                   Metrics,
                   Details,
                   Case).

fresh_root_artifact_case_(Store, Details) :-
    Namespace = [deep, experiment],
    Producer = _{run_id:root_1, call_id:publish_1},
    artifact_put(Store,
                 Namespace,
                 three_stage,
                 summary,
                 _{answer:"artifact-handoff-ok"},
                 Producer,
                 PutOutcome),
    require_artifact_ok(put, PutOutcome, Artifact),
    Consumer = _{run_id:root_2, call_id:consume_1},
    artifact_context_refs(Store,
                          [Artifact.ref],
                          [ consumer(Consumer),
                            max_items(1),
                            max_chars(1024)
                          ],
                          ContextOutcome),
    require_artifact_ok(context, ContextOutcome, Pack),
    Pack.entries = [Entry],
    (   Entry.value.answer == "artifact-handoff-ok",
        Pack.stale_refs == [],
        \+ get_dict(messages, Entry, _),
        \+ get_dict(transcript, Entry, _)
    ->  true
    ;   throw(deep_experiment_fault(invalid_artifact_handoff(Pack)))
    ),
    artifact_trace(Store, Namespace, TraceOutcome),
    require_artifact_ok(trace, TraceOutcome, Trace),
    length(Trace, TraceEvents),
    Details = artifact_experiment_details{
                  producer:root_1,
                  consumer:root_2,
                  compact_handoff:true,
                  transcript_inherited:false,
                  stale_refs:0,
                  trace_events:TraceEvents
              }.

require_artifact_ok(_, ok(Value), Value) :- !.
require_artifact_ok(Operation, Outcome, _) :-
    throw(deep_experiment_fault(
              artifact_operation_failed(Operation, Outcome))).

/* -------------------------------------------------------------------------
 * Global nested-tree budget evidence
 * ---------------------------------------------------------------------- */

global_budget_case(Case) :-
    nested_model_plan(2, Plan),
    plan_validate(Plan,
                  [rlm, model(fake)],
                  _{max_steps:16,
                    max_depth:3,
                    max_model_calls:2},
                  ModelBudgetOutcome),
    require_global_model_budget_rejection(ModelBudgetOutcome),
    nested_literal_plan(2, step_budget_probe, StepPlan),
    plan_validate(StepPlan,
                  [rlm],
                  _{max_steps:4,
                    max_depth:3},
                  StepBudgetOutcome),
    require_global_step_budget_rejection(StepBudgetOutcome),
    Details = global_budget_details{
                  depth:2,
                  model_calls_estimated:3,
                  model_call_limit:2,
                  steps_estimated:5,
                  step_limit:4,
                  shared_tree_budget:true
              },
    benchmark_case(global_recursive_budget,
                   safety_invariant,
                   pass,
                   1.0,
                   _{recursion_depth:2},
                   Details,
                   Case).

nested_model_plan(0,
                  plan([model(fake,
                              literal("leaf"),
                              _{max_tokens:1},
                              model_0),
                        final(var(model_0))])) :- !.
nested_model_plan(Depth,
                  plan([model(fake,
                              literal("level"),
                              _{max_tokens:1},
                              ModelBind),
                        rlm(Child, ChildBind),
                        final(var(ChildBind))])) :-
    Depth > 0,
    ChildDepth is Depth-1,
    nested_model_plan(ChildDepth, Child),
    format(atom(ModelBind), 'model_~d', [Depth]),
    format(atom(ChildBind), 'model_child_~d', [Depth]).

require_global_model_budget_rejection(error(Error)) :-
    Error.kind == budget_exceeded,
    Error.budget == model_calls,
    Error.estimated =:= 3,
    Error.limit =:= 2,
    !.
require_global_model_budget_rejection(Outcome) :-
    throw(deep_experiment_fault(
              global_model_budget_not_enforced(Outcome))).

require_global_step_budget_rejection(error(Error)) :-
    Error.kind == budget_exceeded,
    Error.budget == steps,
    Error.estimated =:= 5,
    Error.limit =:= 4,
    !.
require_global_step_budget_rejection(Outcome) :-
    throw(deep_experiment_fault(
              global_step_budget_not_enforced(Outcome))).

/* -------------------------------------------------------------------------
 * Comparative result classification
 * ---------------------------------------------------------------------- */

depth_comparisons(Cases, Comparisons) :-
    findall(Comparison,
            ( fixture(Fixture),
              member(From-To, [0-1, 1-2]),
              comparison_for_fixture(Fixture,
                                     From,
                                     To,
                                     Cases,
                                     Comparison) ),
            Comparisons).

comparison_for_fixture(Fixture, FromDepth, ToDepth, Cases, Comparison) :-
    case_for_fixture_depth(Cases, Fixture, FromDepth, FromCase),
    case_for_fixture_depth(Cases, Fixture, ToDepth, ToCase),
    QualityDelta is ToCase.quality-FromCase.quality,
    cost_ratio(FromCase.metrics.cost_usd,
               ToCase.metrics.cost_usd,
               CostRatio),
    classify_comparison(QualityDelta, CostRatio, Classification),
    Comparison = depth_comparison{
                     fixture:Fixture,
                     from_depth:FromDepth,
                     to_depth:ToDepth,
                     quality_delta:QualityDelta,
                     cost_ratio:CostRatio,
                     classification:Classification
                 }.

case_for_fixture_depth([Case|_], Fixture, Depth, Case) :-
    Case.details.fixture == Fixture,
    Case.details.depth =:= Depth,
    !.
case_for_fixture_depth([_|Cases], Fixture, Depth, Case) :-
    case_for_fixture_depth(Cases, Fixture, Depth, Case).

cost_ratio(0, 0, 1.0) :- !.
cost_ratio(0, _, infinite) :- !.
cost_ratio(Base, Candidate, Ratio) :-
    Ratio is Candidate/Base.

classify_comparison(QualityDelta, _, helps) :-
    QualityDelta >= 0.25,
    !.
classify_comparison(QualityDelta, CostRatio, hurts) :-
    ( QualityDelta < 0.0
    ; QualityDelta =< 0.01,
      number(CostRatio),
      CostRatio > 1.05
    ),
    !.
classify_comparison(_, _, neutral).

classification_summary(Comparisons,
                       classification_summary{
                           helps:Helps,
                           hurts:Hurts,
                           neutral:Neutral
                       }) :-
    count_classification(Comparisons, helps, Helps),
    count_classification(Comparisons, hurts, Hurts),
    count_classification(Comparisons, neutral, Neutral).

count_classification(Comparisons, Classification, Count) :-
    include(has_classification(Classification), Comparisons, Matches),
    length(Matches, Count).

has_classification(Classification, Comparison) :-
    Comparison.classification == Classification.

/* -------------------------------------------------------------------------
 * Promotion rule
 * ---------------------------------------------------------------------- */

synthetic_promotion_evidence(
    promotion_evidence{
        live_trials:0,
        independent_fixtures:4,
        quality_delta:0.0,
        cost_ratio:1.0,
        latency_ratio:1.0,
        budget_violations:0,
        capability_violations:0,
        cancellation_failures:0
    }).

deep_experiment_promotion(Evidence0, Decision) :-
    catch(deep_experiment_promotion_(Evidence0, Decision),
          Exception,
          deep_experiment_promotion_exception(Exception, Decision)).

deep_experiment_promotion_(Evidence0, Decision) :-
    normalize_promotion_evidence(Evidence0, Evidence),
    default_deep_experiment_policy(Policy),
    promotion_reasons(Evidence, Policy, Reasons),
    (   Reasons == []
    ->  Status = promote
    ;   Status = hold
    ),
    Decision = promotion_decision{
                   status:Status,
                   reasons:Reasons,
                   evidence:Evidence,
                   policy:Policy
               }.

normalize_promotion_evidence(Evidence0, Evidence) :-
    require_dict(Evidence0, promotion_evidence),
    evidence_nonnegative_integer(Evidence0, live_trials, LiveTrials),
    evidence_nonnegative_integer(Evidence0,
                                 independent_fixtures,
                                 IndependentFixtures),
    evidence_number(Evidence0, quality_delta, QualityDelta),
    evidence_nonnegative_number(Evidence0, cost_ratio, CostRatio),
    evidence_nonnegative_number(Evidence0, latency_ratio, LatencyRatio),
    evidence_nonnegative_integer(Evidence0,
                                 budget_violations,
                                 BudgetViolations),
    evidence_nonnegative_integer(Evidence0,
                                 capability_violations,
                                 CapabilityViolations),
    evidence_nonnegative_integer(Evidence0,
                                 cancellation_failures,
                                 CancellationFailures),
    Evidence = promotion_evidence{
                   live_trials:LiveTrials,
                   independent_fixtures:IndependentFixtures,
                   quality_delta:QualityDelta,
                   cost_ratio:CostRatio,
                   latency_ratio:LatencyRatio,
                   budget_violations:BudgetViolations,
                   capability_violations:CapabilityViolations,
                   cancellation_failures:CancellationFailures
               }.

promotion_reasons(Evidence, Policy, Reasons) :-
    findall(Reason,
            promotion_reason(Evidence, Policy, Reason),
            Reasons).

promotion_reason(Evidence, Policy,
                 insufficient_live_trials(Evidence.live_trials,
                                          Policy.min_live_trials)) :-
    Evidence.live_trials < Policy.min_live_trials.
promotion_reason(Evidence, Policy,
                 insufficient_independent_fixtures(
                     Evidence.independent_fixtures,
                     Policy.min_independent_fixtures)) :-
    Evidence.independent_fixtures < Policy.min_independent_fixtures.
promotion_reason(Evidence, Policy,
                 insufficient_quality_delta(Evidence.quality_delta,
                                            Policy.min_quality_delta)) :-
    Evidence.quality_delta < Policy.min_quality_delta.
promotion_reason(Evidence, Policy,
                 cost_ratio_exceeded(Evidence.cost_ratio,
                                     Policy.max_cost_ratio)) :-
    Evidence.cost_ratio > Policy.max_cost_ratio.
promotion_reason(Evidence, Policy,
                 latency_ratio_exceeded(Evidence.latency_ratio,
                                        Policy.max_latency_ratio)) :-
    Evidence.latency_ratio > Policy.max_latency_ratio.
promotion_reason(Evidence, _, budget_violations(Evidence.budget_violations)) :-
    Evidence.budget_violations > 0.
promotion_reason(Evidence, _,
                 capability_violations(Evidence.capability_violations)) :-
    Evidence.capability_violations > 0.
promotion_reason(Evidence, _,
                 cancellation_failures(Evidence.cancellation_failures)) :-
    Evidence.cancellation_failures > 0.

deep_experiment_promotion_exception(Exception,
                                    promotion_decision{
                                        status:hold,
                                        reasons:[invalid_evidence(Safe)]
                                    }) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).

/* -------------------------------------------------------------------------
 * Validation and errors
 * ---------------------------------------------------------------------- */

require_options(Value) :- is_list(Value), !.
require_options(Value) :-
    throw(deep_experiment_fault(invalid_options(Value))).

require_dict(Value, _) :- is_dict(Value), !.
require_dict(Value, Name) :-
    throw(deep_experiment_fault(expected_dict(Name, Value))).

evidence_nonnegative_integer(Dict, Key, Value) :-
    require_evidence_key(Dict, Key, Value),
    (   integer(Value), Value >= 0
    ->  true
    ;   throw(deep_experiment_fault(invalid_evidence(Key, Value)))
    ).

evidence_nonnegative_number(Dict, Key, Value) :-
    require_evidence_key(Dict, Key, Value),
    (   number(Value), Value >= 0
    ->  true
    ;   throw(deep_experiment_fault(invalid_evidence(Key, Value)))
    ).

evidence_number(Dict, Key, Value) :-
    require_evidence_key(Dict, Key, Value),
    (   number(Value)
    ->  true
    ;   throw(deep_experiment_fault(invalid_evidence(Key, Value)))
    ).

require_evidence_key(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(deep_experiment_fault(missing_evidence(Key)))
    ).

deep_experiment_exception(_, deep_experiment_fault(Detail), error(Error)) :-
    !,
    Error = deep_experiment_error{
                phase:experiment,
                kind:invalid_experiment,
                detail:Detail,
                message:"deep recursion experiment rejected the request or violated an invariant"
            }.
deep_experiment_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = deep_experiment_error{
                phase:Phase,
                kind:exception,
                exception:Safe,
                message:"deep recursion experiment raised an exception"
            }.
