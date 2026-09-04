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
current_observation(Stamp, Argv) :-
    repo_state(Head, Digest),
    observation(Stamp, command(Argv), exit(0), _, Head, Digest).

argv_text(Argv, Text) :-
    atomic_list_concat(Argv, ' ', Text).

container_lane_evidence(Stamp) :-
    current_observation(Stamp, Argv),
    argv_text(Argv, Text),
    sub_atom(Text, _, _, _, 'run-tree-sitter-lane.sh').

swipl_suite_evidence(Stamp, File) :-
    current_observation(Stamp, ['swipl', '-q', '-s', File]).

workflow_lane_evidence(Stamp) :-
    current_observation(Stamp, Argv),
    argv_text(Argv, Text),
    sub_atom(Text, _, _, _, '.github/workflows/tree-sitter.yml'),
    sub_atom(Text, _, _, _, 'no-apt-get').

complete :-
    base_complete,
    requirement(nix_lane, _),
    requirement(container_fidelity, _),
    container_lane_evidence(_),
    swipl_suite_evidence(_, 'test/run_tests.pl'),
    swipl_suite_evidence(_, 'test/check_runtime.pl'),
    swipl_suite_evidence(_, 'test/load_all.pl'),
    workflow_lane_evidence(_).

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
