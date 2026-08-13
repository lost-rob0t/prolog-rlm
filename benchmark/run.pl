:- initialization(main, main).

:- use_module(rlm_conformance).
:- use_module(rlm_live_benchmark).
:- use_module('../prolog/rlm_benchmark').

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
parse_args(Args, _, _) :-
    format(user_error,
           'usage: swipl -q -s benchmark/run.pl -- (deterministic|integration) [report.json]~nreceived: ~q~n',
           [Args]),
    halt(2).

run_mode(deterministic, Report) :-
    deterministic_conformance(Report).
run_mode(integration, Report) :-
    live_openrouter_benchmark(Report).

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
