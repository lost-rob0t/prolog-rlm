% Task-specific verification for the current worktree.
% Task: #293 S0 — adopt the closed project-op plan vocabulary and the plan
% dependency-graph executor (rage/288-spec-plan-graph-executor @ 71a10ae +
% D6-11 plan-native dispatch from rage/355-d6-11-plan-native-dispatch) into
% main, with the design gate repointed at the merged module.
:- set_prolog_flag(unknown, error).
:- use_module(library(plunit)).
:- use_module(library(time)).
:- ensure_loaded('facts.kb').

current_successful_observation :-
    repo_state(Head, Digest),
    observation(_, _, exit(0), _, Head, Digest).

current_research_evidence :-
    research_required(false).
current_research_evidence :-
    research_required(true),
    repo_state(Head, Digest),
    brave_search(_, _, _, Head, Digest).

base_complete :-
    task(_),
    current_successful_observation,
    current_research_evidence.

% Every required deterministic gate ran green at the current HEAD/worktree.
all_required_gates_observed :-
    repo_state(Head, Digest),
    forall(member(Cmd,
                  [[swipl, -q, -s, 'test/check_runtime.pl'],
                   [swipl, -q, -s, 'test/load_all.pl'],
                   [swipl, -q, -s, 'test/run_tests.pl'],
                   [swipl, -q, -s, 'benchmark/run.pl', --, deterministic],
                   [swipl, -q, -s, 'scripts/design_gate.pl'],
                   [swipl, -q, -s, 'scripts/plan_graph_contract_check.pl'],
                   [swipl, -q, -s, 'bin/prolog-rlm.pl', --, demo, --json],
                   [git, diff, --check],
                   [make, research-approval],
                   [swipl, -q, -s, 'test/rlm_plan_graph_test.pl', -g, run_tests],
                   [swipl, -q, -s, 'test/rlm_plan_native_ops_test.pl', -g, run_tests],
                   [swipl, -q, -s, 'test/rlm_effect_restart_test.pl']]),
           observation(_, Cmd, exit(0), _, Head, Digest)).

% D6-11 shape: the merged executor exports the closed plan-native set and
% the design gate pins it against the closed vocabulary. Checked by loading
% the real merged modules, not by self-attestation.
:- use_module('../prolog/rlm_plan_graph', []).
:- use_module('../prolog/rlm_tool', []).

d6_11_closed_set_exported :-
    rlm_plan_graph:plan_native_op(sync_remote/1),
    rlm_plan_graph:plan_native_op(run/1),
    rlm_plan_graph:plan_native_op(index/1),
    rlm_plan_graph:plan_native_op(delete/1),
    \+ rlm_plan_graph:plan_native_op(edit/2),
    \+ rlm_plan_graph:plan_native_op(create/2).

d6_11_set_inside_closed_vocabulary :-
    forall(rlm_plan_graph:plan_native_op(Op),
           rlm_plan_graph:plan_graph_op(Op)).

% Only one scheduler: the executor goes through rlm_async and there is no
% second plan interpreter (rlm_plan executes the desugared tool/3 steps).
no_second_scheduler :-
    current_predicate(rlm_async:rlm_async_submit/2),
    current_predicate(rlm_async:rlm_async_submit/3),
    \+ current_predicate(rlm_plan_graph:rlm_async_submit/2),
    \+ current_predicate(rlm_plan_graph:schedule_step/1),
    \+ current_predicate(rlm_plan_graph:plan_graph_eval/1).

% The D6-11 exclusion is enforced fail-closed at preflight, not ignored.
expert_mapping_exclusion_enforced :-
    \+ catch(rlm_plan_graph:valid_expert_registry(
                 [expert(sync_remote, true)]), _, fail).

% No new external-effect path: the executor module performs no effect
% submission itself; durable effects belong to the rlm_effect boundary.
executor_has_no_effect_path :-
    current_predicate(rlm_effect:rlm_effect_store_open/1),
    \+ current_predicate(rlm_plan_graph:effect_submit/2),
    \+ current_predicate(rlm_plan_graph:rlm_effect_attempt/2),
    \+ current_predicate(rlm_plan_graph:effect_dispatch/2).

complete :-
    base_complete,
    all_required_gates_observed,
    d6_11_closed_set_exported,
    d6_11_set_inside_closed_vocabulary,
    no_second_scheduler,
    expert_mapping_exclusion_enforced,
    executor_has_no_effect_path.

:- begin_tests(workspace_verification).

test(complete) :-
    complete.

:- end_tests(workspace_verification).

main :-
    catch(call_with_time_limit(30, (run_tests, once(complete))),
          Error,
          (print_message(error, Error), fail)),
    !,
    halt(0).
main :-
    halt(1).

:- initialization(main, main).
