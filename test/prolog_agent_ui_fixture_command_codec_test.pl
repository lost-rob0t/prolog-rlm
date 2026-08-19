:- begin_tests(prolog_agent_ui_fixture_command_codec).

:- use_module('../agentProlog/prolog/prolog_agent_ui_v1').
:- use_module('../agentProlog/prolog/prolog_agent_ui_fixture').

test(decoded_approval_command_produces_encodable_frames) :-
    ui_v1_command_frame("fixture_session_1", "req_codec_1",
                        "approval.decide",
                        _{approval_id:"approval_1",
                          decision:"allow_once"},
                        Command0),
    ui_v1_encode_frame(Command0, ok(Line)),
    ui_v1_decode_frame(Line, ok(Command)),
    ui_fixture_handle(Command, Frames),
    assertion(Frames = [Result, Event]),
    assertion(Result.kind == "result"),
    assertion(Result.status == "ok"),
    assertion(Event.kind == "event"),
    assertion(Event.event_type == "approval_resolved"),
    assertion(Event.seq =:= 25),
    assertion(Event.caused_by == "req_codec_1"),
    assertion(ui_v1_encode_frame(Result, ok(_))),
    assertion(ui_v1_encode_frame(Event, ok(_))).

:- end_tests(prolog_agent_ui_fixture_command_codec).
