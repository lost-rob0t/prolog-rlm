:- initialization(aggregate_probe_main, main).

:- consult(runner_hostile_main).

aggregate_probe_main :-
    format('aggregate_probe_main_ran~n'),
    halt(0).
