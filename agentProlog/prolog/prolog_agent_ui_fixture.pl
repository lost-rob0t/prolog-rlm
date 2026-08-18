:- module(prolog_agent_ui_fixture,
          [ ui_fixture_ready/0,
            ui_fixture_session_id/1,
            ui_fixture_golden/2,
            ui_fixture_snapshot_at/2,
            ui_fixture_reconnect/3,
            ui_fixture_handle/2,
            ui_fixture_server_loop/2
          ]).

/** <module> Deterministic prolog_agent_ui_v1 coding-session fixture

The fixture is deliberately renderer-free.  It gives polyglot clients a stable
session containing streaming, generic/unknown tools, approvals, questions,
subagents, verification, usage, traces, an indeterminate effect and an optional
unknown extension event.
*/

:- use_module(library(readutil)).
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module('prolog_agent_ui_v1').
:- use_module('prolog_agent_ui_facade').

ui_fixture_ready.
ui_fixture_session_id("fixture_session_1").

ui_fixture_golden(Snapshot0, Events) :-
    ui_fixture_session_id(SessionId),
    ui_v1_initial_view(SessionId, View0),
    ui_facade_snapshot(SessionId, "snapshot_fixture_0", View0, Snapshot0),
    fixture_canonical_events(Canonical),
    numbered_frames(SessionId, Canonical, 1, Events).

fixture_canonical_events(
    [ agent_event(run_started,
                  _{run_id:"run_fixture_1", task:"repair authority tests"}),
      agent_event(message_started, "msg_1", "assistant"),
      agent_event(model_delta, "msg_1", "I will inspect "),
      agent_event(model_delta, "msg_1", "the authority path."),
      agent_event(message_completed, "msg_1"),
      agent_event(tool_started, "tool_1", "project_search",
                  _{query:"rlm_authority"}),
      agent_event(tool_output, "tool_1", _{matches:3}),
      agent_event(tool_finished, "tool_1", ok(_{matches:3})),
      agent_event(tool_started, "tool_2", "project_patch",
                  _{path:"prolog/rlm_authority.pl"}),
      agent_event(approval_required, "approval_1", "tool_2",
                  _{path:"prolog/rlm_authority.pl", added:4, removed:1},
                  ["approve_diff","allow_once","allow_session"]),
      agent_event(approval_resolved, "approval_1", "allow_once"),
      agent_event(tool_finished, "tool_2", ok(_{changed:true})),
      agent_event(question_required, "question_1",
                  "Which verification profile should run?",
                  ["authority","deterministic"]),
      agent_event(question_answered, "question_1", "authority"),
      agent_event(subagent_started, "subagent_1", _{role:"verifier"}),
      agent_event(tool_started, "tool_3", "mystery_linter", _{mode:"strict"}),
      agent_event(tool_finished, "tool_3", ok(_{warnings:0})),
      agent_event(subagent_finished, "subagent_1", ok),
      agent_event(verification, "authority", _{status:"pass", tests:42}),
      agent_event(usage, _{input_tokens:1200, output_tokens:340}),
      agent_event(trace, _{trace_id:"trace_fixture_1", span:"verify"}),
      agent_event(effect_indeterminate, "effect_1",
                  _{adapter:"fixture", reason:"transport_lost_after_dispatch"}),
      agent_event(frontend_hint, _{density:"compact"}),
      agent_event(run_finished, ok(_{changed_files:1}))
    ]).

numbered_frames(_, [], _, []).
numbered_frames(SessionId, [Canonical|Rest], Seq, [Frame|Frames]) :-
    ui_facade_event(SessionId, Seq, Canonical, Frame),
    Next is Seq + 1,
    numbered_frames(SessionId, Rest, Next, Frames).

ui_fixture_snapshot_at(AtSeq, Snapshot) :-
    integer(AtSeq),
    AtSeq >= 0,
    ui_fixture_golden(Snapshot0, Events),
    take_through_seq(AtSeq, Events, Prefix),
    ui_v1_replay(Snapshot0, Prefix, ok(View)),
    ui_fixture_session_id(SessionId),
    format(string(SnapshotId), 'snapshot_fixture_~d', [AtSeq]),
    ui_facade_snapshot(SessionId, SnapshotId, View, Snapshot).

ui_fixture_reconnect(_LastSeenSeq, Snapshot, ResumeEvents) :-
    CheckpointSeq = 10,
    ui_fixture_snapshot_at(CheckpointSeq, Snapshot),
    ui_fixture_golden(_Snapshot0, Events),
    include(seq_after(CheckpointSeq), Events, ResumeEvents).

seq_after(Checkpoint, Event) :-
    Event.seq > Checkpoint.

take_through_seq(0, _, []) :- !.
take_through_seq(AtSeq, Events, Prefix) :-
    include(seq_at_most(AtSeq), Events, Prefix).

seq_at_most(AtSeq, Event) :-
    Event.seq =< AtSeq.

ui_fixture_handle(Frame, Frames) :-
    ui_v1_validate_frame(Frame, Validation),
    (   Validation = error(Error)
    ->  error_from_validation(Frame, Error, Frames)
    ;   Frame.kind == "negotiate"
    ->  negotiate_frames(Frame, Frames)
    ;   Frame.kind == "command"
    ->  fixture_command(Frame, 25, Frames, _)
    ;   frame_error(Frame, "unsupported_client_frame",
                    "Fixture accepts negotiate and command frames", ErrorFrame),
        Frames = [ErrorFrame]
    ).

negotiate_frames(Frame, [Result, Snapshot|Resume]) :-
    Payload = Frame.payload,
    list_default(Payload, optional_capabilities, [], Optional),
    ui_v1_server_capabilities(Supported),
    intersection(Optional, Supported, AcceptedOptional),
    list_default(Payload, required_capabilities, [], Required),
    ui_fixture_session_id(SessionId),
    ui_v1_result_frame(SessionId, Frame.request_id, "ok",
                       _{protocol:"prolog_agent_ui_v1",
                         required_capabilities:Required,
                         accepted_optional_capabilities:AcceptedOptional},
                       Result),
    dict_default(Payload, resume_from, 0, LastSeen),
    ui_fixture_reconnect(LastSeen, Snapshot, Resume).

fixture_command(Frame, NextSeq0, Frames, NextSeq) :-
    Command = Frame.command,
    fixture_command_(Command, Frame, NextSeq0, Frames, NextSeq).

fixture_command_("approval.decide", Frame, Seq, [Result, Event], Next) :- !,
    required_string(Frame.payload, approval_id, ApprovalId),
    required_string(Frame.payload, decision, Decision),
    ui_v1_result_frame(Frame.session_id, Frame.request_id, "ok",
                       _{accepted:true}, Result),
    ui_facade_event(Frame.session_id, Seq,
                    agent_event(approval_resolved, ApprovalId, Decision),
                    Frame.request_id, Event),
    Next is Seq + 1.
fixture_command_("question.answer", Frame, Seq, [Result, Event], Next) :- !,
    required_string(Frame.payload, question_id, QuestionId),
    get_dict(answer, Frame.payload, Answer),
    ui_v1_result_frame(Frame.session_id, Frame.request_id, "ok",
                       _{accepted:true}, Result),
    ui_facade_event(Frame.session_id, Seq,
                    agent_event(question_answered, QuestionId, Answer),
                    Frame.request_id, Event),
    Next is Seq + 1.
fixture_command_("session.cancel", Frame, Seq, [Result, Event], Next) :- !,
    ui_v1_result_frame(Frame.session_id, Frame.request_id, "ok",
                       _{accepted:true}, Result),
    ui_facade_event(Frame.session_id, Seq,
                    agent_event(run_finished, cancelled),
                    Frame.request_id, Event),
    Next is Seq + 1.
fixture_command_(_, Frame, Next, [Result], Next) :-
    ui_v1_result_frame(Frame.session_id, Frame.request_id, "rejected",
                       _{code:"unknown_command", command:Frame.command}, Result).

ui_fixture_server_loop(In, Out) :-
    ui_fixture_golden(_Snapshot, Events),
    last_event_next_seq(Events, NextSeq),
    server_loop(In, Out, NextSeq).

server_loop(In, Out, NextSeq0) :-
    read_line_to_string(In, Line),
    (   Line == end_of_file
    ->  true
    ;   ui_v1_decode_frame(Line, Decoded),
        handle_decoded(Decoded, NextSeq0, Frames, NextSeq),
        write_frames(Out, Frames),
        server_loop(In, Out, NextSeq)
    ).

handle_decoded(error(Error), Next, [Frame], Next) :- !,
    ui_fixture_session_id(SessionId),
    ui_v1_error_frame(SessionId, none, Error.code, Error.message, Frame0),
    put_dict(details, Frame0, Error.details, Frame).
handle_decoded(ok(Frame), NextSeq0, Frames, NextSeq) :-
    (   Frame.kind == "negotiate"
    ->  negotiate_frames(Frame, Frames),
        NextSeq = NextSeq0
    ;   Frame.kind == "command"
    ->  fixture_command(Frame, NextSeq0, Frames, NextSeq)
    ;   frame_error(Frame, "unsupported_client_frame",
                    "Fixture accepts negotiate and command frames", ErrorFrame),
        Frames = [ErrorFrame],
        NextSeq = NextSeq0
    ).

write_frames(_, []).
write_frames(Out, [Frame|Rest]) :-
    ui_v1_encode_frame(Frame, ok(Line)),
    format(Out, '~s~n', [Line]),
    flush_output(Out),
    write_frames(Out, Rest).

last_event_next_seq([], 1).
last_event_next_seq(Events, Next) :-
    last(Events, Last),
    Next is Last.seq + 1.

error_from_validation(Frame, Error, [ErrorFrame]) :-
    frame_session(Frame, SessionId),
    frame_request(Frame, RequestId),
    ui_v1_error_frame(SessionId, RequestId, Error.code, Error.message, Base),
    put_dict(details, Base, Error.details, ErrorFrame).

frame_error(Frame, Code, Message, ErrorFrame) :-
    frame_session(Frame, SessionId),
    frame_request(Frame, RequestId),
    ui_v1_error_frame(SessionId, RequestId, Code, Message, ErrorFrame).

frame_session(Frame, SessionId) :-
    (   get_dict(session_id, Frame, Existing), string(Existing)
    ->  SessionId = Existing
    ;   ui_fixture_session_id(SessionId)
    ).

frame_request(Frame, RequestId) :-
    (   get_dict(request_id, Frame, Existing), string(Existing)
    ->  RequestId = Existing
    ;   RequestId = none
    ).

list_default(Dict, Key, Default, Value) :-
    (get_dict(Key, Dict, Existing) -> Value = Existing ; Value = Default).

dict_default(Dict, Key, Default, Value) :-
    (get_dict(Key, Dict, Existing) -> Value = Existing ; Value = Default).

required_string(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value), string(Value)
    ->  true
    ;   throw(error(domain_error(string_field, Key), _))
    ).
