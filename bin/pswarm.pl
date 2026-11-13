:- initialization(main, main).

:- use_module('../prolog/rlm_swarm_cli').

main(Argv) :-
    rlm_swarm_cli:pswarm_execute(Argv, ExitCode),
    halt(ExitCode).
