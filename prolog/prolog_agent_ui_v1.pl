:- module(prolog_agent_ui_v1,
          [ ui_v1_ready/0,
            ui_v1_protocol/1,
            ui_v1_server_capabilities/1,
            ui_v1_snapshot_max_bytes/1,
            ui_v1_validate_frame/2,
            ui_v1_encode_frame/2,
            ui_v1_decode_frame/2,
            ui_v1_event_frame/7,
            ui_v1_snapshot_frame/5,
            ui_v1_command_frame/5,
            ui_v1_result_frame/5,
            ui_v1_error_frame/5,
            ui_v1_initial_view/2,
            ui_v1_snapshot_state/2,
            ui_v1_apply_snapshot/3,
            ui_v1_apply_event/3,
            ui_v1_replay/3
          ]).

/** <module> PrologAgent application-facing UI protocol v1

This module defines renderer-independent wire semantics for PrologAgent.
Frontends receive bounded canonical snapshots and ordered semantic events and
send explicit correlated commands.  Event sequence numbers are owned by the
server/session.  Request identifiers correlate commands and results and are
never overloaded as event cursors.

NDJSON is the reference encoding: one complete JSON object per line.  The
newline is transport framing only; protocol semantics do not depend on stdio
and can be carried over a local socket later without changing the records.
*/

:- use_module(library(http/json)).
:- use_module(library(lists)).
:- use_module(library(apply)).

ui_v1_ready.

ui_v1_protocol("prolog_agent_ui_v1").
ui_v1_snapshot_max_bytes(1048576).

ui_v1_server_capabilities(
    [ "streaming_text",
      "generic_tools",
      "approvals",
      "questions",
      "subagents",
      "verification",
      "usage",
      "traces",
      "indeterminate_effects",
      "optional_extensions",
      "native_file_buffers",
      "side_by_side_diff",
      "mouse",
      "clipboard",
      "multiple_windows"
    ]).

known_event_type("run_started").
known_event_type("message_started").
known_event_type("text_delta").
known_event_type("message_completed").
known_event_type("tool_started").
known_event_type("tool_output").
known_event_type("tool_finished").
known_event_type("approval_required").
known_event_type("approval_resolved").
known_event_type("question_required").
known_event_type("question_answered").
known_event_type("subagent_started").
known_event_type("subagent_finished").
known_event_type("verification").
known_event_type("usage").
known_event_type("trace").
known_event_type("effect_indeterminate").
known_event_type("run_finished").

/* Public constructors -------------------------------------------------- */

ui_v1_event_frame(SessionId, Seq, EventId, EventType, Payload0, CausedBy,
                  Frame) :-
    normalize_payload(Payload0, Payload),
    ui_v1_protocol(Protocol),
    Base = ui_frame{protocol:Protocol,
                    kind:"event",
                    session_id:SessionId,
                    seq:Seq,
                    event_id:EventId,
                    event_type:EventType,
                    payload:Payload},
    put_optional_correlation(CausedBy, Base, Frame0),
    canonical_ui_data(Frame0, Frame).

ui_v1_snapshot_frame(SessionId, SnapshotId, AtSeq, State, Frame) :-
    ui_v1_protocol(Protocol),
    Frame0 = ui_frame{protocol:Protocol,
                      kind:"snapshot",
                      session_id:SessionId,
                      snapshot_id:SnapshotId,
                      at_seq:AtSeq,
                      state:State},
    canonical_ui_data(Frame0, Frame).

ui_v1_command_frame(SessionId, RequestId, Command, Payload0, Frame) :-
    normalize_payload(Payload0, Payload),
    ui_v1_protocol(Protocol),
    Frame0 = ui_frame{protocol:Protocol,
                      kind:"command",
                      session_id:SessionId,
                      request_id:RequestId,
                      command:Command,
                      payload:Payload},
    canonical_ui_data(Frame0, Frame).

ui_v1_result_frame(SessionId, RequestId, Status, Payload0, Frame) :-
    normalize_payload(Payload0, Payload),
    ui_v1_protocol(Protocol),
    Frame0 = ui_frame{protocol:Protocol,
                      kind:"result",
                      session_id:SessionId,
                      request_id:RequestId,
                      status:Status,
                      payload:Payload},
    canonical_ui_data(Frame0, Frame).

ui_v1_error_frame(SessionId, RequestId, Code, Message, Frame) :-
    ui_v1_protocol(Protocol),
    Base = ui_frame{protocol:Protocol,
                    kind:"error",
                    session_id:SessionId,
                    code:Code,
                    message:Message,
                    details:ui_data{}},
    put_optional_request(RequestId, Base, Frame0),
    canonical_ui_data(Frame0, Frame).

/* Validation and codec ------------------------------------------------ */

ui_v1_validate_frame(Frame, Outcome) :-
    catch((validate_frame(Frame), Outcome = ok(Frame)),
          Error,
          validation_outcome(Error, Outcome)).

ui_v1_encode_frame(Frame, Outcome) :-
    ui_v1_validate_frame(Frame, Validation),
    (   Validation = ok(_)
    ->  catch(( with_output_to(string(Line),
                               json_write_dict(current_output,
                                               Frame,
                                               [width(0)])),
                Encoded = ok(Line)
              ),
              Error,
              codec_outcome(encode, Error, Encoded)),
        Outcome = Encoded
    ;   Outcome = Validation
    ).

ui_v1_decode_frame(Line0, Outcome) :-
    catch(( normalize_line(Line0, Line),
            atom_string(Atom, Line),
            atom_json_dict(Atom, RawFrame, []),
            canonical_ui_data(RawFrame, Frame),
            ui_v1_validate_frame(Frame, Outcome)
          ),
          Error,
          codec_outcome(decode, Error, Outcome)).

validate_frame(Frame) :-
    must_be_dict(Frame),
    require_exact(Frame, protocol, "prolog_agent_ui_v1"),
    require_string(Frame, kind, Kind),
    validate_kind(Kind, Frame).

validate_kind("negotiate", Frame) :- !,
    require_id(Frame, request_id, _),
    require_dict(Frame, payload, Payload),
    require_list(Payload, protocol_versions, Versions),
    must_all_strings(Versions),
    require_list_default(Payload, required_capabilities, [], Required),
    require_list_default(Payload, optional_capabilities, [], Optional),
    must_all_strings(Required),
    must_all_strings(Optional),
    (   memberchk("prolog_agent_ui_v1", Versions)
    ->  true
    ;   throw(ui_fault(protocol_version_not_offered,
                       _{offered:Versions}))
    ),
    ensure_required_capabilities(Required).
validate_kind("snapshot", Frame) :- !,
    require_id(Frame, session_id, _),
    require_id(Frame, snapshot_id, _),
    require_nonnegative_integer(Frame, at_seq, _),
    require_dict(Frame, state, State),
    validate_snapshot_bound(State).
validate_kind("event", Frame) :- !,
    require_id(Frame, session_id, _),
    require_positive_integer(Frame, seq, _),
    require_id(Frame, event_id, _),
    require_string(Frame, event_type, EventType),
    require_dict(Frame, payload, _),
    optional_id(Frame, caused_by),
    validate_event_extension(EventType, Frame).
validate_kind("command", Frame) :- !,
    require_id(Frame, session_id, _),
    require_id(Frame, request_id, _),
    require_string(Frame, command, _),
    require_dict(Frame, payload, _).
validate_kind("result", Frame) :- !,
    require_id(Frame, session_id, _),
    require_id(Frame, request_id, _),
    require_string(Frame, status, Status),
    (   memberchk(Status, ["ok","rejected"])
    ->  true
    ;   throw(ui_fault(invalid_result_status, _{status:Status}))
    ),
    require_dict(Frame, payload, _).
validate_kind("error", Frame) :- !,
    require_id(Frame, session_id, _),
    optional_id(Frame, request_id),
    require_string(Frame, code, _),
    require_string(Frame, message, _),
    require_dict(Frame, details, _).
validate_kind(Kind, _) :-
    throw(ui_fault(unknown_frame_kind, _{kind:Kind})).

validate_event_extension(EventType, _) :-
    known_event_type(EventType),
    !.
validate_event_extension(EventType, Frame) :-
    (   get_dict(extension, Frame, Extension),
        is_dict(Extension),
        get_dict(namespace, Extension, Namespace),
        string(Namespace),
        get_dict(required, Extension, Required),
        (Required == true ; Required == false)
    ->  (   Required == false
        ->  true
        ;   throw(ui_fault(unsupported_required_extension,
                           _{event_type:EventType,
                             namespace:Namespace}))
        )
    ;   throw(ui_fault(unknown_event_without_extension,
                       _{event_type:EventType}))
    ).

ensure_required_capabilities(Required) :-
    ui_v1_server_capabilities(Supported),
    subtract(Required, Supported, Missing),
    (   Missing == []
    ->  true
    ;   throw(ui_fault(unsupported_required_capability,
                       _{missing:Missing}))
    ).

validate_snapshot_bound(State) :-
    bounded_lists(State),
    with_output_to(string(Json),
                   json_write_dict(current_output, State, [width(0)])),
    string_bytes(Json, WireBytes, utf8),
    length(WireBytes, Bytes),
    ui_v1_snapshot_max_bytes(Max),
    (   Bytes =< Max
    ->  true
    ;   throw(ui_fault(snapshot_too_large,
                       _{bytes:Bytes, max_bytes:Max}))
    ).

bounded_lists(Value) :-
    (   is_list(Value)
    ->  length(Value, Length),
        (   Length =< 256
        ->  maplist(bounded_lists, Value)
        ;   throw(ui_fault(snapshot_collection_too_large,
                           _{items:Length, max_items:256}))
        )
    ;   is_dict(Value)
    ->  dict_pairs(Value, _, Pairs),
        maplist(bounded_pair, Pairs)
    ;   true
    ).

bounded_pair(_-Value) :-
    bounded_lists(Value).

/* Deterministic client-side replay ------------------------------------ */

ui_v1_initial_view(SessionId,
                   ui_view{protocol:"prolog_agent_ui_v1",
                           session_id:SessionId,
                           at_seq:0,
                           status:"idle",
                           run:null,
                           messages:[],
                           tools:[],
                           approvals:[],
                           questions:[],
                           subagents:[],
                           verification:[],
                           usage:_{},
                           traces:[],
                           indeterminate_effects:[],
                           extensions:[]}).

ui_v1_snapshot_state(View, State) :-
    Raw = ui_snapshot_state{status:View.status,
                            run:View.run,
                            messages:View.messages,
                            tools:View.tools,
                            approvals:View.approvals,
                            questions:View.questions,
                            subagents:View.subagents,
                            verification:View.verification,
                            usage:View.usage,
                            traces:View.traces,
                            indeterminate_effects:View.indeterminate_effects,
                            extensions:View.extensions},
    canonical_ui_data(Raw, State).

canonical_ui_data(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_ui_pair, Pairs0, Pairs),
    dict_pairs(Value, ui_data, Pairs).
canonical_ui_data(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_ui_data, Values0, Values).
canonical_ui_data(Value, Value).

canonical_ui_pair(Key-Value0, Key-Value) :-
    canonical_ui_data(Value0, Value).

ui_v1_apply_snapshot(_View0, Frame, Outcome) :-
    ui_v1_validate_frame(Frame, Validation),
    (   Validation = ok(_), Frame.kind == "snapshot"
    ->  State = Frame.state,
        catch((state_to_view(Frame.session_id, Frame.at_seq, State, View),
               Outcome = ok(View)),
              Error,
              validation_outcome(Error, Outcome))
    ;   Validation = error(Error)
    ->  Outcome = error(Error)
    ;   Outcome = error(ui_error{code:"expected_snapshot",
                                 message:"Expected snapshot frame",
                                 details:_{kind:Frame.kind}})
    ).

ui_v1_apply_event(View0, Frame, Outcome) :-
    ui_v1_validate_frame(Frame, Validation),
    (   Validation = error(Error)
    ->  Outcome = error(Error)
    ;   Frame.kind \== "event"
    ->  Outcome = error(ui_error{code:"expected_event",
                                 message:"Expected event frame",
                                 details:_{kind:Frame.kind}})
    ;   View0.session_id \== Frame.session_id
    ->  Outcome = error(ui_error{code:"session_mismatch",
                                 message:"Event belongs to another session",
                                 details:_{expected:View0.session_id,
                                           actual:Frame.session_id}})
    ;   Frame.seq =< View0.at_seq
    ->  Outcome = ok(View0)
    ;   Expected is View0.at_seq + 1,
        Frame.seq =\= Expected
    ->  Outcome = error(ui_error{code:"sequence_gap",
                                 message:"Event stream has a sequence gap",
                                 details:_{expected:Expected,
                                           actual:Frame.seq}})
    ;   catch((reduce_event(Frame, View0, View1), Outcome = ok(View1)),
              Error,
              validation_outcome(Error, Outcome))
    ).

ui_v1_replay(Snapshot, Events, Outcome) :-
    ui_v1_validate_frame(Snapshot, Validation),
    (   Validation = error(Error)
    ->  Outcome = error(Error)
    ;   Snapshot.kind \== "snapshot"
    ->  Outcome = error(ui_error{code:"expected_snapshot",
                                 message:"Expected snapshot frame",
                                 details:_{kind:Snapshot.kind}})
    ;   ui_v1_initial_view(Snapshot.session_id, Empty),
        ui_v1_apply_snapshot(Empty, Snapshot, SnapshotOutcome),
        (   SnapshotOutcome = error(Error)
        ->  Outcome = error(Error)
        ;   SnapshotOutcome = ok(View0),
            replay_events(Events, View0, Outcome)
        )
    ).

replay_events([], View, ok(View)).
replay_events([Event|Rest], View0, Outcome) :-
    ui_v1_apply_event(View0, Event, Applied),
    (   Applied = error(Error)
    ->  Outcome = error(Error)
    ;   Applied = ok(View1),
        replay_events(Rest, View1, Outcome)
    ).

state_to_view(SessionId, AtSeq, State, View) :-
    required_state_field(State, status, Status),
    required_state_field(State, run, Run),
    required_state_field(State, messages, Messages),
    required_state_field(State, tools, Tools),
    required_state_field(State, approvals, Approvals),
    required_state_field(State, questions, Questions),
    required_state_field(State, subagents, Subagents),
    required_state_field(State, verification, Verification),
    required_state_field(State, usage, Usage),
    required_state_field(State, traces, Traces),
    required_state_field(State, indeterminate_effects, Indeterminate),
    required_state_field(State, extensions, Extensions),
    View = ui_view{protocol:"prolog_agent_ui_v1",
                   session_id:SessionId,
                   at_seq:AtSeq,
                   status:Status,
                   run:Run,
                   messages:Messages,
                   tools:Tools,
                   approvals:Approvals,
                   questions:Questions,
                   subagents:Subagents,
                   verification:Verification,
                   usage:Usage,
                   traces:Traces,
                   indeterminate_effects:Indeterminate,
                   extensions:Extensions}.

required_state_field(State, Key, Value) :-
    (   get_dict(Key, State, Value)
    ->  true
    ;   throw(ui_fault(invalid_snapshot_state, _{missing:Key}))
    ).

reduce_event(Frame, View0, View) :-
    EventType = Frame.event_type,
    Payload = Frame.payload,
    reduce_known_or_extension(EventType, Payload, Frame, View0, View1),
    put_dict(at_seq, View1, Frame.seq, View).

reduce_known_or_extension("run_started", Payload, _, View0, View) :- !,
    put_dict(_{status:"running", run:Payload}, View0, View).
reduce_known_or_extension("message_started", Payload, _, View0, View) :- !,
    required_payload_id(Payload, message_id, MessageId),
    require_string(Payload, role, Role),
    Message = _{id:MessageId, role:Role, text:"", status:"streaming"},
    upsert_by_id(Message, View0.messages, Messages),
    put_dict(messages, View0, Messages, View).
reduce_known_or_extension("text_delta", Payload, _, View0, View) :- !,
    required_payload_id(Payload, message_id, MessageId),
    require_string(Payload, delta, Delta),
    update_message_delta(MessageId, Delta, View0.messages, Messages),
    put_dict(messages, View0, Messages, View).
reduce_known_or_extension("message_completed", Payload, _, View0, View) :- !,
    required_payload_id(Payload, message_id, MessageId),
    update_item_fields(MessageId, _{status:"complete"},
                       View0.messages, Messages),
    put_dict(messages, View0, Messages, View).
reduce_known_or_extension("tool_started", Payload, _, View0, View) :- !,
    required_payload_id(Payload, tool_id, ToolId),
    put_dict(_{id:ToolId, status:"running"}, Payload, Tool),
    upsert_by_id(Tool, View0.tools, Tools),
    put_dict(tools, View0, Tools, View).
reduce_known_or_extension("tool_output", Payload, _, View0, View) :- !,
    required_payload_id(Payload, tool_id, ToolId),
    require_payload_field(Payload, output, Output),
    update_item_fields(ToolId, _{output:Output}, View0.tools, Tools),
    put_dict(tools, View0, Tools, View).
reduce_known_or_extension("tool_finished", Payload, _, View0, View) :- !,
    required_payload_id(Payload, tool_id, ToolId),
    require_payload_field(Payload, outcome, Outcome),
    update_item_fields(ToolId, _{status:"finished", outcome:Outcome},
                       View0.tools, Tools),
    put_dict(tools, View0, Tools, View).
reduce_known_or_extension("approval_required", Payload, _, View0, View) :- !,
    required_payload_id(Payload, approval_id, Id),
    put_dict(_{id:Id, status:"pending"}, Payload, Approval),
    upsert_by_id(Approval, View0.approvals, Approvals),
    put_dict(approvals, View0, Approvals, View).
reduce_known_or_extension("approval_resolved", Payload, _, View0, View) :- !,
    required_payload_id(Payload, approval_id, Id),
    put_dict(_{status:"resolved"}, Payload, Fields),
    update_item_fields(Id, Fields, View0.approvals, Approvals),
    put_dict(approvals, View0, Approvals, View).
reduce_known_or_extension("question_required", Payload, _, View0, View) :- !,
    required_payload_id(Payload, question_id, Id),
    put_dict(_{id:Id, status:"pending"}, Payload, Question),
    upsert_by_id(Question, View0.questions, Questions),
    put_dict(questions, View0, Questions, View).
reduce_known_or_extension("question_answered", Payload, _, View0, View) :- !,
    required_payload_id(Payload, question_id, Id),
    put_dict(_{status:"answered"}, Payload, Fields),
    update_item_fields(Id, Fields, View0.questions, Questions),
    put_dict(questions, View0, Questions, View).
reduce_known_or_extension("subagent_started", Payload, _, View0, View) :- !,
    required_payload_id(Payload, subagent_id, Id),
    put_dict(_{id:Id, status:"running"}, Payload, Subagent),
    upsert_by_id(Subagent, View0.subagents, Subagents),
    put_dict(subagents, View0, Subagents, View).
reduce_known_or_extension("subagent_finished", Payload, _, View0, View) :- !,
    required_payload_id(Payload, subagent_id, Id),
    put_dict(_{status:"finished"}, Payload, Fields),
    update_item_fields(Id, Fields, View0.subagents, Subagents),
    put_dict(subagents, View0, Subagents, View).
reduce_known_or_extension("verification", Payload, _, View0, View) :- !,
    append_bounded(View0.verification, Payload, Verification),
    put_dict(verification, View0, Verification, View).
reduce_known_or_extension("usage", Payload, _, View0, View) :- !,
    put_dict(usage, View0, Payload, View).
reduce_known_or_extension("trace", Payload, _, View0, View) :- !,
    append_bounded(View0.traces, Payload, Traces),
    put_dict(traces, View0, Traces, View).
reduce_known_or_extension("effect_indeterminate", Payload, _, View0, View) :- !,
    append_bounded(View0.indeterminate_effects, Payload, Effects),
    put_dict(indeterminate_effects, View0, Effects, View).
reduce_known_or_extension("run_finished", Payload, _, View0, View) :- !,
    merge_run_finish(View0.run, Payload, Run),
    put_dict(_{status:"finished", run:Run}, View0, View).
reduce_known_or_extension(_Unknown, Payload, Frame, View0, View) :-
    Extension = Frame.extension,
    Record = _{event_type:Frame.event_type,
               extension:Extension,
               payload:Payload},
    append_bounded(View0.extensions, Record, Extensions),
    put_dict(extensions, View0, Extensions, View).

merge_run_finish(Run0, Payload, Run) :-
    (   is_dict(Run0)
    ->  put_dict(Payload, Run0, Run)
    ;   Run = Payload
    ).

update_message_delta(MessageId, Delta, Messages0, Messages) :-
    select_item(MessageId, Messages0, Message0, Before, After),
    string_concat(Message0.text, Delta, Text),
    put_dict(text, Message0, Text, Message),
    append(Before, [Message|After], Messages).

update_item_fields(Id, Fields, Items0, Items) :-
    select_item(Id, Items0, Item0, Before, After),
    put_dict(Fields, Item0, Item),
    append(Before, [Item|After], Items).

select_item(Id, Items, Item, Before, After) :-
    existing_item(Id, Items, Item, Before, After),
    !.
select_item(Id, _, _, _, _) :-
    throw(ui_fault(replay_missing_entity, _{id:Id})).

existing_item(Id, Items, Item, Before, After) :-
    append(Before, [Item|After], Items),
    get_dict(id, Item, Id).

upsert_by_id(Item, Items0, Items) :-
    Id = Item.id,
    (   existing_item(Id, Items0, _Old, Before, After)
    ->  append(Before, [Item|After], Items)
    ;   append(Items0, [Item], Items)
    ).

append_bounded(Items0, Item, Items) :-
    append(Items0, [Item], All),
    length(All, Length),
    (   Length =< 256
    ->  Items = All
    ;   Drop is Length - 256,
        length(Prefix, Drop),
        append(Prefix, Items, All)
    ).

/* Helpers -------------------------------------------------------------- */

normalize_payload(Payload0, Payload) :-
    is_dict(Payload0),
    !,
    canonical_ui_data(Payload0, Payload).
normalize_payload(null, ui_data{}) :- !.
normalize_payload(Payload0, Payload) :-
    canonical_ui_data(ui_data{value:Payload0}, Payload).

put_optional_correlation(none, Base, Base) :- !.
put_optional_correlation(CausedBy, Base, Frame) :-
    put_dict(caused_by, Base, CausedBy, Frame).

put_optional_request(none, Base, Base) :- !.
put_optional_request(RequestId, Base, Frame) :-
    put_dict(request_id, Base, RequestId, Frame).

normalize_line(Line, Line) :- string(Line), !.
normalize_line(Line, String) :- atom(Line), !, atom_string(Line, String).
normalize_line(_, _) :- throw(ui_fault(invalid_ndjson_line, _{})).

must_be_dict(Value) :-
    (   is_dict(Value)
    ->  true
    ;   throw(ui_fault(expected_object, _{}))
    ).

require_exact(Dict, Key, Expected) :-
    (   get_dict(Key, Dict, Actual), Actual == Expected
    ->  true
    ;   throw(ui_fault(invalid_field, _{field:Key, expected:Expected}))
    ).

require_string(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value), string(Value)
    ->  true
    ;   throw(ui_fault(invalid_string_field, _{field:Key}))
    ).

require_dict(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value), is_dict(Value)
    ->  true
    ;   throw(ui_fault(invalid_object_field, _{field:Key}))
    ).

require_list(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value), is_list(Value)
    ->  true
    ;   throw(ui_fault(invalid_list_field, _{field:Key}))
    ).

require_list_default(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Existing)
    ->  (   is_list(Existing)
        ->  Value = Existing
        ;   throw(ui_fault(invalid_list_field, _{field:Key}))
        )
    ;   Value = Default
    ).

require_id(Dict, Key, Value) :-
    require_string(Dict, Key, Value),
    (   string_length(Value, Length), Length > 0, Length =< 200
    ->  true
    ;   throw(ui_fault(invalid_id, _{field:Key}))
    ).

optional_id(Dict, Key) :-
    (   get_dict(Key, Dict, Value)
    ->  require_id(Dict, Key, Value)
    ;   true
    ).

require_nonnegative_integer(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value), integer(Value), Value >= 0
    ->  true
    ;   throw(ui_fault(invalid_integer_field, _{field:Key}))
    ).

require_positive_integer(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value), integer(Value), Value > 0
    ->  true
    ;   throw(ui_fault(invalid_integer_field, _{field:Key}))
    ).

must_all_strings([]).
must_all_strings([Value|Rest]) :-
    (   string(Value)
    ->  must_all_strings(Rest)
    ;   throw(ui_fault(expected_string_list, _{}))
    ).

required_payload_id(Payload, Key, Id) :-
    require_id(Payload, Key, Id).

require_payload_field(Payload, Key, Value) :-
    (   get_dict(Key, Payload, Value)
    ->  true
    ;   throw(ui_fault(missing_payload_field, _{field:Key}))
    ).

validation_outcome(ui_fault(Code, Details),
                   error(ui_error{code:CodeString,
                                  message:Message,
                                  details:Details})) :-
    !,
    atom_string(Code, CodeString),
    format(string(Message), 'Invalid prolog_agent_ui_v1 record: ~w', [Code]).
validation_outcome(Error,
                   error(ui_error{code:"validation_exception",
                                  message:"Unexpected protocol validation exception",
                                  details:_{exception:Text}})) :-
    term_string(Error, Text, [quoted(true), numbervars(true)]).

codec_outcome(Direction, Error,
              error(ui_error{code:"ndjson_codec_error",
                             message:"Failed to encode/decode NDJSON frame",
                             details:_{direction:Direction,
                                       exception:Text}})) :-
    term_string(Error, Text, [quoted(true), numbervars(true)]).
