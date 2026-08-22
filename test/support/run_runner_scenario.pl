:- set_prolog_flag(on_error, status).
:- initialization(main, main).

:- use_module('../deterministic_corpus.pl').
:- use_module('../deterministic_runner.pl').

main(_) :-
    current_prolog_flag(argv, [Scenario|_]),
    scenario(Scenario, Files, Suites),
    deterministic_corpus:load_corpus_files(Files),
    (   deterministic_corpus:aggregate_load_succeeded,
        runner_goal(Scenario, Suites)
    ->  halt(0)
    ;   halt(1)
    ).

runner_goal(slow, Suites) :-
    !,
    deterministic_runner:run(Suites, [run_budget(1), test_timeout(10)]).
runner_goal(budget_setup, Suites) :-
    !,
    deterministic_runner:run(Suites, [run_budget(1), test_timeout(10)]).
runner_goal(_, Suites) :-
    deterministic_runner:run(Suites).

scenario(empty, [], []).
scenario(subset,
         ['support/runner_subset_tests.pl'],
         [runner_subset_one]).
scenario(failures,
         ['support/runner_adversarial_failures.pl'],
         [runner_adversarial_failures]).
scenario(blocked,
         ['support/runner_blocked_test.pl'],
         [runner_blocked]).
scenario(condition,
         ['support/runner_condition_test.pl'],
         [runner_condition_skipped]).
scenario(setup,
         ['support/runner_setup_test.pl'],
         [runner_setup_failure]).
scenario(duplicate,
         ['support/runner_duplicate_test.pl'],
         [runner_duplicate]).
scenario(timeout,
         ['support/runner_timeout_test.pl'],
         [runner_timeout]).
scenario(passing,
         ['support/runner_passing_test.pl'],
         [runner_passing]).
scenario(slow,
         ['support/runner_budget_test.pl'],
         [runner_budget]).
scenario(budget_setup,
         ['support/runner_budget_setup_test.pl'],
         [runner_budget_setup]).
