:- initialization(main, main).

:- use_module('../prolog/rlm_cli').

main(Argv) :-
    rlm_cli:cli_execute(Argv, ExitCode),
    halt(ExitCode).
