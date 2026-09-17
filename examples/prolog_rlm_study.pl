:- module(prolog_rlm_study,
          [ study_plan/1,
            study_capabilities/1,
            study_budget/1,
            study_options/1,
            study_run/2,
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

study_options([
    budget(Budget),
    tools([
        tool(study_retrieve, prolog_rlm_study:study_retrieve),
        tool(study_normalize, prolog_rlm_study:study_normalize),
        tool(study_verify, prolog_rlm_study:study_verify)
    ])
]) :-
    study_budget(Budget).

study_run(Topic, Outcome) :-
    study_plan(Plan),
    study_capabilities(Capabilities),
    study_options(Options),
    plan_run(Plan, Capabilities, Options, _{topic:Topic}, Outcome).

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
