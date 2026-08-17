:- initialization(main, main).

:- use_module('../prolog/rlm_effect_migration').

main([Mode,Phase,Source,Destination]) :-
    setenv('RLM_EFFECT_MIGRATION_MARKER_DIR', '/tmp'),
    configure_failure(Mode, Phase),
    effect_store_migrate(_{source:Source,output:Destination}, Report),
    format('migration_result ~w~n', [Report.status]),
    halt(0).

configure_failure(crash, Phase) :-
    setenv('RLM_EFFECT_MIGRATION_CRASH_AT', Phase).
configure_failure(pause, Phase) :-
    setenv('RLM_EFFECT_MIGRATION_PAUSE_AT', Phase).
