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
requirement_command(static_load, Argv) :-
    Argv = [swipl, '-q', '-s', 'test/load_all.pl'].
requirement_command(deterministic_suite, Argv) :-
    Argv = [swipl, '-q', '-s', 'test/run_tests.pl'].
requirement_command(native_build, Argv) :-
    Argv = [nix, develop, '--command', make, 'tree-sitter-ffi'].
requirement_command(native_query_suite, Argv) :-
    argv_mentions(Argv, 'run_tests'),
    argv_mentions(Argv, 'rlm_tree_sitter_query_test'),
    argv_mentions(Argv, 'rlm_project_query_test').
requirement_command(restart_fixture, Argv) :-
    argv_mentions(Argv, 'rlm_project_query_restart_test').
requirement_command(flake_checks, Argv) :-
    Argv = [nix, flake, check|_].
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
% native/query commands are the executable evidence that discharges them.
invariant(query_source_is_data, native_query_suite).
invariant(captures_are_closed_data, native_query_suite).
invariant(mode_runtimes_are_unchanged, deterministic_suite).
invariant(publication_fences_prior_records_stale, native_query_suite).
invariant(stale_fencing_survives_restart, restart_fixture).

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
