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

% Extend this predicate with task-specific requirements and invariants.
% Derived invariant: every claimed requirement is covered by at least one
% successful machine-recorded observation at the current repository state.
complete :-
    base_complete,
    requirement_coverage.

requirement_coverage :-
    forall(requirement(Name, _), requirement_satisfied(Name)).

requirement_satisfied(research_approval) :-
    observed_command(['make', 'research-approval']).
requirement_satisfied(design_record_present) :-
    observed_command(['bash', '-c', 'test -f rage/336-text-streaming-design.org']).
requirement_satisfied(oq_resolved) :-
    observed_command(['bash', '-c', 'test $(grep -c "OQ[1-6] ::" rage/336-text-streaming-design.org) -ge 6']).
requirement_satisfied(decision_gate_approved) :-
    observed_command(['bash', '-c', 'grep -q "GO. The operator approved the design" rage/336-text-streaming-design.org && grep -q "ok i aprove it, solve the open design issues" rage/336-text-streaming-design.org']).
requirement_satisfied(slice_scope) :-
    observed_command(['bash', '-c', 'git diff --name-only origin/main -- . :!rage :!research :!.prolog | grep . ; test $? -eq 1']).
requirement_satisfied(static_load) :-
    observed_command(['swipl', '-q', '-s', 'test/check_runtime.pl']).
requirement_satisfied(deterministic_suite) :-
    observed_command(['swipl', '-q', '-s', 'test/run_tests.pl']).
requirement_satisfied(whitespace) :-
    observed_command(['git', 'diff', '--check']).

observed_command(Command) :-
    repo_state(Head, Digest),
    observation(_, command(Command), exit(0), _, Head, Digest).

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
