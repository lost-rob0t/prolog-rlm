:- initialization(main, main).

:- use_module('../prolog/prolog_agent_ui_fixture').

main(_) :-
    require_stage(snapshot_at_10,
                  ui_fixture_snapshot_at(10, _Snapshot)),
    require_stage(reconnect_0,
                  ui_fixture_reconnect(0, _ReconnectSnapshot, _Resume)),
    ui_fixture_server_loop(user_input, user_output).

require_stage(Stage, Goal) :-
    (   call(Goal)
    ->  true
    ;   throw(error(ui_fixture_startup_stage_failed(Stage), _))
    ).
