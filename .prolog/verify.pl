% Task-specific verification for the current worktree.
:- set_prolog_flag(unknown, error).
:- use_module(library(plunit)).
:- use_module(library(time)).

% facts.kb is the machine-observation ledger (current HEAD/digest).
:- ensure_loaded('facts.kb').

% Snapshot the ledger before the run file redefines observation/6, so
% reconsult semantics cannot hide the recorded evidence.
:- dynamic fact_observation/6.
:- findall(fact_observation(Id, C, S, O, H, D),
           observation(Id, C, S, O, H, D),
           Facts),
   forall(member(F, Facts),
          assertz(F)).

load_current_run :-
    repo_state(Head, _),
    atomic_list_concat(['runs/run-', Head, '.pl'], RunFile),
    (   exists_file(RunFile)
    ->  ensure_loaded(RunFile)
    ;   true
    ).

:- load_current_run.

current_successful_observation :-
    fact_observation(_, _, exit(0), _, Head, Digest),
    repo_state(Head, Digest),
    !.

current_research_evidence :-
    research_required(false).
current_research_evidence :-
    research_required(true),
    fact_observation(_, _, _, _, Head, Digest),
    repo_state(Head, Digest),
    brave_search(_, _, _, Head, Digest).

base_complete :-
    task(_),
    current_successful_observation,
    current_research_evidence.

% Task-specific requirements for #98 semantic project knowledge. Each
% requirement is discharged only by a machine observation recorded at the
% current HEAD and worktree digest; facts are never self-certified.
observed_ok(Sub) :-
    fact_observation(_, command(Args), exit(0), _, Head, Digest),
    repo_state(Head, Digest),
    argv_contains(Args, Sub).

argv_contains(_, []) :- !.
argv_contains(Args, [Element|Rest]) :-
    append(_, [Element|Tail], Args),
    append(Rest, _, Tail),
    !,
    argv_contains(Tail, Rest).

requirement_evidence(check_runtime) :-
    observed_ok([swipl, '-q', '-s', 'test/check_runtime.pl']).
requirement_evidence(static_load) :-
    observed_ok([swipl, '-q', '-s', 'test/load_all.pl']).
requirement_evidence(deterministic_suite) :-
    observed_ok([swipl, '-q', '-s', 'test/run_tests.pl']).
requirement_evidence(native_tree_sitter_suite) :-
    observed_ok([swipl, '-q', '-s', 'test/run_tree_sitter_tests.pl']).
requirement_evidence(benchmark_deterministic) :-
    observed_ok([swipl, '-q', '-s', 'benchmark/run.pl', '--', deterministic]).
requirement_evidence(cli_demo_smoke) :-
    observed_ok([swipl, '-q', '-s', 'bin/prolog-rlm.pl', '--', demo, '--json']).
requirement_evidence(whitespace_hygiene) :-
    observed_ok([git, diff, '--check']).

requirement_gate(check_runtime).
requirement_gate(static_load).
requirement_gate(deterministic_suite).
requirement_gate(native_tree_sitter_suite).
requirement_gate(benchmark_deterministic).
requirement_gate(cli_demo_smoke).
requirement_gate(whitespace_hygiene).

all_requirements :-
    forall(requirement_gate(Name),
           requirement_evidence(Name)).

complete :-
    base_complete,
    all_requirements.

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
