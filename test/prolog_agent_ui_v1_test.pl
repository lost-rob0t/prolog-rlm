:- begin_tests(prolog_agent_ui_v1).

:- use_module('../agentProlog/prolog/prolog_agent_ui_v1').
:- use_module('../agentProlog/prolog/prolog_agent_ui_facade').
:- use_module('../agentProlog/prolog/prolog_agent_ui_fixture').
:- use_module(library(readutil)).
:- use_module(library(process)).


test(ndjson_codec_roundtrip) :-
    ui_v1_event_frame("s1", 1, "e1", "trace", _{trace_id:"t1"}, none,
                      Frame),
    ui_v1_encode_frame(Frame, ok(Line)),
    \+ sub_string(Line, _, _, _, "\n"),
    ui_v1_decode_frame(Line, ok(Decoded)),
    assertion(Decoded == Frame).


test(request_ids_are_correlation_not_sequence) :-
    ui_v1_command_frame("s1", "req_77", "approval.decide",
                        _{approval_id:"a1", decision:"allow_once"}, Command),
    assertion(Command.request_id == "req_77"),
    assertion(\+ get_dict(seq, Command, _)),
    ui_fixture_handle(Command, [Result, Event]),
    assertion(Result.request_id == "req_77"),
    assertion(Event.caused_by == "req_77"),
    assertion(Event.seq =:= 25).


test(optional_unknown_event_advances_sequence) :-
    ui_v1_initial_view("s1", View0),
    ui_facade_snapshot("s1", "snap0", View0, Snapshot),
    Event = _{protocol:"prolog_agent_ui_v1",
              kind:"event",
              session_id:"s1",
              seq:1,
              event_id:"e1",
              event_type:"future_widget_hint",
              payload:_{value:1},
              extension:_{namespace:"future.ui", required:false}},
    ui_v1_replay(Snapshot, [Event], ok(View)),
    assertion(View.at_seq =:= 1),
    assertion(length(View.extensions, 1)).


test(required_unknown_event_fails_closed) :-
    Event = _{protocol:"prolog_agent_ui_v1",
              kind:"event",
              session_id:"s1",
              seq:1,
              event_id:"e1",
              event_type:"future_authority_semantics",
              payload:_{},
              extension:_{namespace:"future.required", required:true}},
    ui_v1_validate_frame(Event, error(Error)),
    assertion(Error.code == "unsupported_required_extension").


test(sequence_gap_is_rejected) :-
    ui_v1_initial_view("s1", View0),
    ui_facade_snapshot("s1", "snap0", View0, Snapshot),
    ui_v1_event_frame("s1", 2, "e2", "trace", _{trace_id:"t2"}, none,
                      Event),
    ui_v1_replay(Snapshot, [Event], error(Error)),
    assertion(Error.code == "sequence_gap").


test(overlapping_resume_event_is_deduplicated) :-
    ui_v1_initial_view("s1", View0),
    ui_facade_snapshot("s1", "snap0", View0, Snapshot),
    ui_v1_event_frame("s1", 1, "e1", "trace", _{trace_id:"t1"}, none,
                      Event),
    ui_v1_replay(Snapshot, [Event], ok(View1)),
    ui_v1_apply_event(View1, Event, ok(View2)),
    assertion(View2 == View1),
    assertion(length(View2.traces, 1)).


test(golden_ndjson_replays_complete_coding_session) :-
    read_golden_frames([Snapshot|Events]),
    ui_v1_replay(Snapshot, Events, ok(View)),
    assertion(View.at_seq =:= 24),
    assertion(View.status == "finished"),
    View.messages = [Message],
    assertion(Message.text == "I will inspect the authority path."),
    assertion(Message.status == "complete"),
    assertion(length(View.tools, 3)),
    member(UnknownTool, View.tools),
    UnknownTool.name == "mystery_linter",
    assertion(length(View.approvals, 1)),
    View.approvals = [Approval],
    assertion(Approval.status == "resolved"),
    assertion(length(View.questions, 1)),
    assertion(length(View.subagents, 1)),
    assertion(length(View.verification, 1)),
    assertion(View.usage.input_tokens =:= 1200),
    assertion(length(View.traces, 1)),
    assertion(length(View.indeterminate_effects, 1)),
    assertion(length(View.extensions, 1)).


test(reconnect_snapshot_plus_resume_matches_full_replay) :-
    ui_fixture_golden(Snapshot0, Events),
    ui_v1_replay(Snapshot0, Events, ok(Full)),
    ui_fixture_reconnect(24, Snapshot10, Resume),
    assertion(Snapshot10.at_seq =:= 10),
    Resume = [FirstResume|_],
    assertion(FirstResume.seq =:= 11),
    ui_v1_replay(Snapshot10, Resume, ok(Reconnected)),
    ui_v1_snapshot_state(Full, FullState),
    ui_v1_snapshot_state(Reconnected, ReconnectedState),
    assertion(Reconnected.at_seq =:= Full.at_seq),
    assertion(ReconnectedState == FullState).


test(negotiate_returns_canonical_snapshot_then_resume) :-
    Negotiate = _{protocol:"prolog_agent_ui_v1",
                  kind:"negotiate",
                  request_id:"req_negotiate",
                  payload:_{protocol_versions:["prolog_agent_ui_v1"],
                            required_capabilities:["approvals"],
                            optional_capabilities:["mouse","not_supported"],
                            resume_from:24}},
    ui_fixture_handle(Negotiate, [Result, Snapshot|Resume]),
    assertion(Result.kind == "result"),
    assertion(Result.request_id == "req_negotiate"),
    assertion(Result.payload.accepted_optional_capabilities == ["mouse"]),
    assertion(Snapshot.kind == "snapshot"),
    assertion(Snapshot.at_seq =:= 10),
    Resume = [First|_],
    assertion(First.seq =:= 11).


test(ten_thousand_deltas_preserve_semantic_order_and_bound_snapshot) :-
    stress_session(Snapshot, Events),
    ui_v1_replay(Snapshot, Events, ok(View)),
    assertion(View.at_seq =:= 10015),
    View.messages = [Message],
    string_length(Message.text, 10000),
    findall(Marker,
            (member(Trace, View.traces), Marker = Trace.marker),
            Markers),
    assertion(Markers == [1000,2000,3000,4000,5000,
                          6000,7000,8000,9000,10000]),
    assertion(length(View.verification, 1)),
    ui_facade_snapshot("stress_session", "stress_snapshot", View,
                       FinalSnapshot),
    ui_v1_validate_frame(FinalSnapshot, ok(_)),
    ui_v1_encode_frame(FinalSnapshot, ok(Line)),
    string_length(Line, Bytes),
    ui_v1_snapshot_max_bytes(Max),
    assertion(Bytes < Max).


test(stdio_fixture_server_smoke) :-
    Negotiate = _{protocol:"prolog_agent_ui_v1",
                  kind:"negotiate",
                  request_id:"req_stdio",
                  payload:_{protocol_versions:["prolog_agent_ui_v1"],
                            required_capabilities:[],
                            optional_capabilities:[]}},
    ui_v1_encode_frame(Negotiate, ok(Line)),
    process_create(path(swipl),
                   ['-q','-s','agentProlog/bin/prolog-agent-ui-fixture.pl'],
                   [ stdin(pipe(In)),
                     stdout(pipe(Out)),
                     stderr(pipe(Err)),
                     process(Pid)
                   ]),
    format(In, '~s~n', [Line]),
    close(In),
    read_string(Out, _, Stdout),
    close(Out),
    read_string(Err, _, _Stderr),
    close(Err),
    process_wait(Pid, Status),
    assertion(Status == exit(0)),
    split_string(Stdout, "\n", "\n", Lines0),
    exclude(=(""), Lines0, Lines),
    Lines = [ResultLine, SnapshotLine|_],
    ui_v1_decode_frame(ResultLine, ok(Result)),
    ui_v1_decode_frame(SnapshotLine, ok(ServerSnapshot)),
    assertion(Result.request_id == "req_stdio"),
    assertion(ServerSnapshot.kind == "snapshot").


read_golden_frames(Frames) :-
    setup_call_cleanup(
        open('agentProlog/fixtures/prolog_agent_ui_v1_session.ndjson',
             read, Stream, [encoding(utf8)]),
        read_frame_lines(Stream, Frames),
        close(Stream)).

read_frame_lines(Stream, Frames) :-
    read_line_to_string(Stream, Line),
    (   Line == end_of_file
    ->  Frames = []
    ;   Line == ""
    ->  read_frame_lines(Stream, Frames)
    ;   ui_v1_decode_frame(Line, ok(Frame)),
        Frames = [Frame|Rest],
        read_frame_lines(Stream, Rest)
    ).

stress_session(Snapshot, Events) :-
    ui_v1_initial_view("stress_session", View0),
    ui_facade_snapshot("stress_session", "stress_snapshot_0", View0,
                       Snapshot),
    ui_facade_event("stress_session", 1,
                    agent_event(run_started, _{run_id:"stress"}), Run),
    ui_facade_event("stress_session", 2,
                    agent_event(message_started, "stress_msg", "assistant"),
                    MessageStart),
    stress_deltas(1, 10000, 3, DeltaEvents, NextSeq),
    ui_facade_event("stress_session", NextSeq,
                    agent_event(message_completed, "stress_msg"), Complete),
    VerifySeq is NextSeq + 1,
    ui_facade_event("stress_session", VerifySeq,
                    agent_event(verification, "stress", _{status:"pass"}),
                    Verify),
    FinishSeq is VerifySeq + 1,
    ui_facade_event("stress_session", FinishSeq,
                    agent_event(run_finished, ok), Finish),
    append([[Run,MessageStart], DeltaEvents, [Complete,Verify,Finish]], Events).

stress_deltas(Index, Max, Seq, [], Seq) :-
    Index > Max,
    !.
stress_deltas(Index, Max, Seq0, Frames, NextSeq) :-
    ui_facade_event("stress_session", Seq0,
                    agent_event(model_delta, "stress_msg", "x"), Delta),
    Seq1 is Seq0 + 1,
    (   0 is Index mod 1000
    ->  ui_facade_event("stress_session", Seq1,
                        agent_event(trace, _{marker:Index}), Marker),
        Frames = [Delta,Marker|Rest],
        Seq2 is Seq1 + 1
    ;   Frames = [Delta|Rest],
        Seq2 = Seq1
    ),
    NextIndex is Index + 1,
    stress_deltas(NextIndex, Max, Seq2, Rest, NextSeq).

:- end_tests(prolog_agent_ui_v1).
