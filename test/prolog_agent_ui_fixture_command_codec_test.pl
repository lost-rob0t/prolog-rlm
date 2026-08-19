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

test(persistent_stream_handles_negotiate_then_approval_command) :-
    Negotiate = _{protocol:"prolog_agent_ui_v1",
                  kind:"negotiate",
                  request_id:"req_negotiate_1",
                  payload:_{protocol_versions:["prolog_agent_ui_v1"],
                            required_capabilities:["streaming_text",
                                                   "generic_tools"],
                            optional_capabilities:["approvals",
                                                   "questions",
                                                   "subagents",
                                                   "verification",
                                                   "usage",
                                                   "traces",
                                                   "indeterminate_effects",
                                                   "optional_extensions"],
                            resume_from:0}},
    ui_v1_encode_frame(Negotiate, ok(NegotiateLine)),
    ui_v1_command_frame("fixture_session_1", "req_command_2",
                        "approval.decide",
                        _{approval_id:"approval_1",
                          decision:"allow_once"},
                        Command),
    ui_v1_encode_frame(Command, ok(CommandLine)),
    format(string(Input), '~s~n~s~n', [NegotiateLine, CommandLine]),
    setup_call_cleanup(
        open_string(Input, In),
        with_output_to(string(Output),
                       ui_fixture_server_loop(In, current_output)),
        close(In)),
    split_string(Output, "\n", "\n", Lines0),
    exclude(=(""), Lines0, Lines),
    maplist(decoded_frame, Lines, Frames),
    append(_, [Result, Event], Frames),
    assertion(Result.kind == "result"),
    assertion(Result.request_id == "req_command_2"),
    assertion(Result.status == "ok"),
    assertion(Event.kind == "event"),
    assertion(Event.event_type == "approval_resolved"),
    assertion(Event.seq =:= 25),
    assertion(Event.caused_by == "req_command_2").

decoded_frame(Line, Frame) :-
    ui_v1_decode_frame(Line, ok(Frame)).

:- end_tests(prolog_agent_ui_fixture_command_codec).
