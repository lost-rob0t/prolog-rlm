:- initialization(main, main).

:- use_module('../prolog/prolog_agent_ui_fixture').

main(_) :-
    require_stage(golden,
                  ui_fixture_golden(Snapshot0, Events)),
    require_stage(prefix,
                  prolog_agent_ui_fixture:take_through_seq(10,
                                                            Events,
                                                            Prefix)),
    require_replay(Snapshot0, Prefix, View),
    require_stage(snapshot_encode,
                  prolog_agent_ui_facade:ui_facade_snapshot(
                      "fixture_session_1",
                      "snapshot_fixture_10",
                      View,
                      _Snapshot)),
    require_stage(reconnect_0,
                  ui_fixture_reconnect(0, _ReconnectSnapshot, _Resume)),
    ui_fixture_server_loop(user_input, user_output).

require_replay(Snapshot, Events, View) :-
    prolog_agent_ui_v1:ui_v1_replay(Snapshot, Events, Outcome),
    (   Outcome = ok(View)
    ->  true
    ;   throw(error(ui_fixture_replay_failed(Outcome), _))
    ).

require_stage(Stage, Goal) :-
    (   call(Goal)
    ->  true
    ;   throw(error(ui_fixture_startup_stage_failed(Stage), _))
    ).
