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

% Task-specific requirements and invariants.
%
% research_approval / record_present / slice_scope are requirements for the
% research slice: the gate derives them from machine-recorded observations,
% never from prose or self-asserted success facts.
required_observation(make_research_approval,
                     ['make', 'research-approval']).
required_observation(record_present,
                     ['bash', '-c', 'test -f research/RLM-RESEARCH-336-text-streaming.org']).
required_observation(slice_scope,
                     ['bash', '-c',
                      'git diff --name-only origin/main -- . \':!research\' \':!.prolog\' | grep . ; test $? -eq 1']).
required_observation(static_load,
                     ['swipl', '-q', '-s', 'test/check_runtime.pl']).
required_observation(deterministic_suite,
                     ['swipl', '-q', '-s', 'test/run_tests.pl']).
required_observation(whitespace,
                     ['git', 'diff', '--check']).

requirement_observed(Requirement) :-
    required_observation(Requirement, Command),
    repo_state(Head, Digest),
    observation(_, command(Command), exit(0), _, Head, Digest).

all_requirements_observed :-
    forall(required_observation(Requirement, _),
           requirement_observed(Requirement)).

% Extend this predicate with task-specific requirements and invariants.
complete :-
    base_complete,
    all_requirements_observed.

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
