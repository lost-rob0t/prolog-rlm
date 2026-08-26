:- initialization(main, main).

:- use_module(rlm_conformance).
:- use_module(rlm_live_benchmark).
:- use_module(rlm_live_deep_experiment).
:- use_module(rlm_live_deep_smoke).
:- use_module('../prolog/rlm_benchmark').
:- use_module('../prolog/rlm_deep_experiment').

main(Argv) :-
    parse_args(Argv, Mode, Output),
    catch(run_mode(Mode, Report),
          Exception,
          fatal_benchmark_exception(Exception)),
    benchmark_human_summary(Report, Summary),
    benchmark_json(Report, Json),
    format(user_error, '~s~n', [Summary]),
    emit_json(Output, Json),
    exit_for_status(Report.status).

parse_args([], deterministic, stdout) :- !.
parse_args([deterministic], deterministic, stdout) :- !.
parse_args([deterministic, Output], deterministic, Output) :- !.
parse_args([integration], integration, stdout) :- !.
parse_args([integration, Output], integration, Output) :- !.
parse_args(['deep-experiment'], deep_experiment, stdout) :- !.
parse_args(['deep-experiment', Output], deep_experiment, Output) :- !.
parse_args(['deep-integration'], deep_integration, stdout) :- !.
parse_args(['deep-integration', Output], deep_integration, Output) :- !.
parse_args(['deep-smoke'], deep_smoke, stdout) :- !.
parse_args(['deep-smoke', Output], deep_smoke, Output) :- !.
parse_args(Args, _, _) :-
    format(user_error,
           'usage: swipl -q -s benchmark/run.pl -- (deterministic|integration|deep-experiment|deep-integration|deep-smoke) [report.json]~nreceived: ~q~n',
           [Args]),
    halt(2).

run_mode(deterministic, Report) :-
    deterministic_conformance(Report).
run_mode(integration, Report) :-
    live_openrouter_benchmark(Report).
run_mode(deep_experiment, Report) :-
    deep_experiment_run([experimental_deep_recursion(true)], Outcome),
    require_deep_experiment(Outcome, Result),
    Report = Result.report.
run_mode(deep_integration, Report) :-
    live_deep_experiment_benchmark(Report).
run_mode(deep_smoke, Report) :-
    live_deep_smoke_benchmark(Report).

require_deep_experiment(ok(Result), Result) :- !.
require_deep_experiment(error(Error), _) :-
    throw(error(deep_experiment_failed(Error),
                context(benchmark_run,
                        'deep recursion experiment did not complete'))).

emit_json(stdout, Json) :-
    !,
    format('~s~n', [Json]).
emit_json(Path, Json) :-
    setup_call_cleanup(
        open(Path, write, Stream, [encoding(utf8)]),
        format(Stream, '~s~n', [Json]),
        close(Stream)),
    format(user_error, 'benchmark report: ~w~n', [Path]).

fatal_benchmark_exception(Exception) :-
    print_message(error, Exception),
    halt(2).

exit_for_status(pass) :- halt(0).
exit_for_status(_) :- halt(1).
