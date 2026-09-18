% Task-specific verification for the current worktree.
:- set_prolog_flag(unknown, error).
:- use_module(library(plunit)).
:- use_module(library(time)).
:- ensure_loaded('facts.kb').

load_current_run :-
    repo_state(Head, _),
    atomic_list_concat(['runs/run-', Head, '.pl'], RunFile),
    ( exists_file(RunFile) -> ensure_loaded(RunFile) ; true ).

:- load_current_run.

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

observed_ok(Required) :-
    repo_state(Head, Digest),
    observation(_, command(Args), exit(0), _, Head, Digest),
    append(_, Tail, Args),
    append(Required, _, Tail),
    !.

requirement(focused_provider_tests) :-
    observed_ok([swipl, '-q', '-s', 'test/rlm_chain_test.pl']).
requirement(http_identity_tests) :-
    observed_ok([swipl, '-q', '-s',
                 'test/rlm_chain_app_attribution_test.pl']).
requirement(check_runtime) :-
    observed_ok([swipl, '-q', '-s', 'test/check_runtime.pl']).
requirement(static_load) :-
    observed_ok([swipl, '-q', '-s', 'test/load_all.pl']).
requirement(deterministic_suite) :-
    observed_ok([swipl, '-q', '-s', 'test/run_tests.pl']).
requirement(deterministic_benchmark) :-
    observed_ok([swipl, '-q', '-s', 'benchmark/run.pl', '--', deterministic]).
requirement(deep_experiment) :-
    observed_ok([swipl, '-q', '-s', 'benchmark/run.pl', '--', 'deep-experiment']).
requirement(cli_smoke) :-
    observed_ok([swipl, '-q', '-s', 'bin/prolog-rlm.pl', '--', demo, '--json']).
requirement(diff_hygiene) :-
    observed_ok([git, diff, '--check']).

all_requirements :-
    forall(member(Name,
                   [ focused_provider_tests,
                     http_identity_tests,
                     check_runtime,
                    static_load,
                    deterministic_suite,
                    deterministic_benchmark,
                    deep_experiment,
                    cli_smoke,
                    diff_hygiene
                  ]),
           requirement(Name)).

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
