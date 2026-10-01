:- module(prolog_rlm_study,
          [ study_plan/1,
            study_capabilities/1,
            study_budget/1,
            study_options/1,
            study_run/2,
            study_variant_run/3,
            study_compare/2,
            study_capability_failure/1,
            study_depth_failure/1
          ]).

/** <module> Deterministic teaching fixture for the Prolog-RLM capstone

This example exercises the production typed-plan runtime without contacting a
model provider.  It is deliberately small enough to explain line by line in
the companion Prolog + LLMs book while preserving the real runtime boundary:
model-shaped plan data remains closed, capabilities are explicit, nested RLM
steps share one budget, and host-authored tool closures are the only callable
code.
*/

:- use_module('../prolog/rlm_plan').
:- use_module(library(lists), [member/2, memberchk/2]).

study_plan(
    plan([
        tool(study_retrieve, input(topic), evidence),
        rlm(
            plan([
                tool(study_normalize, var(evidence), claim),
                tool(study_verify, var(claim), verdict),
                final(var(verdict))
            ]),
            verified),
        checkpoint(verified),
        final(var(verified))
    ])).

study_capabilities([
    tool(study_retrieve),
    rlm,
    tool(study_normalize),
    tool(study_verify),
    checkpoint
]).

study_budget(
    plan_budget{
        max_steps:7,
        max_depth:2,
        max_parallel:1,
        max_model_calls:0,
        max_tool_calls:3,
        max_context_ops:0,
        max_output_bytes:4096,
        time_limit:2.0
    }).

study_tool_registry([
    tool(study_retrieve, prolog_rlm_study:study_retrieve),
    tool(study_normalize, prolog_rlm_study:study_normalize),
    tool(study_verify, prolog_rlm_study:study_verify)
]).

study_options([
    budget(Budget),
    tools(Tools)
]) :-
    study_budget(Budget),
    study_tool_registry(Tools).

study_run(Topic, Outcome) :-
    study_plan(Plan),
    study_capabilities(Capabilities),
    study_options(Options),
    plan_run(Plan, Capabilities, Options, _{topic:Topic}, Outcome).

study_variant_run(Variant, Topic, Outcome) :-
    study_variant(Variant, Plan, Capabilities, Budget),
    study_tool_registry(Tools),
    Options = [budget(Budget), tools(Tools)],
    plan_run(Plan, Capabilities, Options, _{topic:Topic}, Outcome).

study_compare(Topic, study_report{topic:Topic, variants:Observations}) :-
    Variants = [direct, retrieve, verify, recursive],
    maplist(study_variant_observation(Topic), Variants, Observations).

study_variant_observation(Topic, Variant, Observation) :-
    study_variant(Variant, Plan, Capabilities, Budget),
    plan_validate(Plan, Capabilities, Budget, ok(Validated)),
    study_variant_run(Variant, Topic, ok(Result)),
    get_dict(estimate, Validated, Estimate),
    get_dict(value, Result, Value),
    get_dict(transitions, Result, Transitions),
    get_dict(budget_remaining, Result, Remaining),
    Observation = study_variant_result{
                      variant:Variant,
                      estimate:Estimate,
                      value:Value,
                      transitions:Transitions,
                      budget_remaining:Remaining
                  }.

study_variant(direct,
              plan([
                  final(input(topic))
              ]),
              [],
              Budget) :-
    study_variant_budget(1, 1, 0, Budget).
study_variant(retrieve,
              plan([
                  tool(study_retrieve, input(topic), evidence),
                  final(var(evidence))
              ]),
              [tool(study_retrieve)],
              Budget) :-
    study_variant_budget(2, 1, 1, Budget).
study_variant(verify,
              plan([
                  tool(study_retrieve, input(topic), evidence),
                  tool(study_normalize, var(evidence), claim),
                  tool(study_verify, var(claim), verdict),
                  final(var(verdict))
              ]),
              [
                  tool(study_retrieve),
                  tool(study_normalize),
                  tool(study_verify)
              ],
              Budget) :-
    study_variant_budget(4, 1, 3, Budget).
study_variant(recursive, Plan, Capabilities, Budget) :-
    study_plan(Plan),
    study_capabilities(Capabilities),
    study_budget(Budget).

study_variant_budget(Steps, Depth, ToolCalls,
                     plan_budget{
                         max_steps:Steps,
                         max_depth:Depth,
                         max_parallel:1,
                         max_model_calls:0,
                         max_tool_calls:ToolCalls,
                         max_context_ops:0,
                         max_output_bytes:4096,
                         time_limit:2.0
                     }).

study_capability_failure(Outcome) :-
    study_plan(Plan),
    study_budget(Budget),
    Restricted = [
        tool(study_retrieve),
        rlm,
        tool(study_normalize),
        checkpoint
    ],
    plan_validate(Plan, Restricted, Budget, Outcome).

study_depth_failure(Outcome) :-
    study_plan(Plan),
    study_capabilities(Capabilities),
    study_budget(Budget0),
    put_dict(max_depth, Budget0, 1, Budget),
    plan_validate(Plan, Capabilities, Budget, Outcome).

study_retrieve(Topic,
               evidence{
                   topic:Topic,
                   source:deterministic_fixture,
                   observed:[
                       closed_plan,
                       capability_gate,
                       bounded_recursion,
                       structured_trace
                   ]
               }).

study_normalize(Evidence,
                claim{
                    topic:Topic,
                    required:[
                        closed_plan,
                        capability_gate,
                        bounded_recursion,
                        structured_trace
                    ],
                    observed:Observed
                }) :-
    get_dict(topic, Evidence, Topic),
    get_dict(observed, Evidence, Observed).

study_verify(Claim,
             verification{
                 accepted:Accepted,
                 topic:Topic,
                 missing:Missing
             }) :-
    get_dict(topic, Claim, Topic),
    get_dict(required, Claim, Required),
    get_dict(observed, Claim, Observed),
    findall(Item,
            ( member(Item, Required),
              \+ memberchk(Item, Observed)
            ),
            Missing),
    accepted_if_complete(Missing, Accepted).

accepted_if_complete([], true) :- !.
accepted_if_complete(_, false).
