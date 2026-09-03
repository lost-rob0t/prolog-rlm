% Task-specific verification for the current worktree.
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

current_successful_command(Argv) :-
    repo_state(Head, Digest),
    observation(_, command(Argv), exit(0), _, Head, Digest).

requirement_command(research_gate, Argv) :-
    Argv = [make, 'research-approval'].
requirement_command(design_gate, Argv) :-
    Argv = [swipl, '-q', '-s', 'scripts/design_gate.pl'].
requirement_command(static_load, Argv) :-
    Argv = [swipl, '-q', '-s', 'test/load_all.pl'].
requirement_command(runtime_check, Argv) :-
    Argv = [swipl, '-q', '-s', 'test/check_runtime.pl'].
requirement_command(deterministic_suite, Argv) :-
    Argv = [swipl, '-q', '-s', 'test/run_tests.pl'].
requirement_command(focused_native_ops, Argv) :-
    argv_mentions(Argv, 'rlm_plan_native_ops_test').
requirement_command(benchmark_deterministic, Argv) :-
    Argv = [swipl, '-q', '-s', 'benchmark/run.pl', '--', 'deterministic'].
requirement_command(cli_demo, Argv) :-
    Argv = [swipl, '-q', '-s', 'bin/prolog-rlm.pl', '--', 'demo', '--json'].
requirement_command(whitespace, Argv) :-
    Argv = [git, diff, '--check'].

% Focused-suite invocations pass the test file names inside the -g goal
% string rather than as standalone argv elements; both spellings count.
% Argv is always ground here (bound from a recorded observation).
argv_mentions(Argv, Name) :-
    is_list(Argv),
    member(Element, Argv),
    (   Element == Name
    ;   atom(Element),
        sub_atom(Element, _, _, _, Name)
    ).

requirement_satisfied(Requirement) :-
    requirement(Requirement, _),
    current_successful_command(Argv),
    requirement_command(Requirement, Argv).

% These invariants are intentionally descriptive obligations; the observed
% design-gate and focused-suite commands are the executable evidence that
% discharges them.
invariant(d6_11_recorded_verbatim, design_gate).
invariant(d6_8_references_d6_11_exclusion, design_gate).
invariant(plan_native_set_closed_in_base_vocabulary, design_gate).
invariant(plan_native_desugar_is_canonical_tool_step, design_gate).
invariant(ungranted_capability_fails_closed, focused_native_ops).
invariant(admitted_effect_normalized_fingerprint, focused_native_ops).
invariant(observation_op_never_admitted_durably, focused_native_ops).
invariant(edit_create_remain_expert_owned, design_gate).

complete :-
    base_complete,
    forall(requirement(Requirement, _),
           requirement_satisfied(Requirement)),
    forall(invariant(_, Requirement),
           requirement_satisfied(Requirement)).

:- begin_tests(workspace_verification).

test(complete) :-
    complete.

test(task_requirements_have_command_evidence) :-
    forall(requirement(Requirement, _),
           requirement_satisfied(Requirement)),
    forall(invariant(_, Requirement),
           requirement_satisfied(Requirement)).

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
