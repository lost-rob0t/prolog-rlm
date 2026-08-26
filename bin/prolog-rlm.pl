:- initialization(main, main).

:- use_module('../prolog/rlm_cli_app').

main(Argv) :-
    rlm_cli_app:cli_execute(Argv, ExitCode),
    halt(ExitCode).
