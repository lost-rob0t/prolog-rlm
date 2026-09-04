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

required_command(ci_range_whitespace,
                 [git, diff, '--check', 'origin/main...HEAD']).
required_command(worktree_whitespace,
                 [git, diff, '--check']).
required_command(plan_graph_suite,
                 [swipl, '-q', '-s', 'test/rlm_plan_graph_test.pl',
                  '-g', run_tests]).
required_command(deterministic_suite,
                 [swipl, '-q', '-s', 'test/run_tests.pl']).

requirement_observed(Requirement) :-
    requirement(Requirement, _),
    required_command(Requirement, Argv),
    repo_state(Head, Digest),
    observation(_, command(Argv), exit(0), _, Head, Digest).

complete :-
    base_complete,
    forall(requirement(Requirement, _),
           requirement_observed(Requirement)).

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
