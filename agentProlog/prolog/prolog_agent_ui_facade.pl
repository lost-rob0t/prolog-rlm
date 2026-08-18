:- module(prolog_agent_ui_facade,
          [ ui_facade_ready/0,
            ui_facade_event/4,
            ui_facade_event/5,
            ui_facade_snapshot/4
          ]).

/** <module> Canonical AgentProlog runtime to UI v1 facade

The application/runtime side owns this translation.  Renderers consume the
resulting semantic events and never scrape raw traces or import authority/tool
implementations to recover domain state.
*/

:- use_module('prolog_agent_ui_v1').
:- use_module('../../prolog/rlm_trace').

ui_facade_ready.

ui_facade_event(SessionId, Seq, CanonicalEvent, Frame) :-
    ui_facade_event(SessionId, Seq, CanonicalEvent, none, Frame).

ui_facade_event(SessionId, Seq, CanonicalEvent, CausedBy, Frame) :-
    canonical_ui_event(CanonicalEvent, EventType, Payload, Extension),
    format(string(EventId), 'evt_~d', [Seq]),
    ui_v1_event_frame(SessionId, Seq, EventId, EventType, Payload, CausedBy,
                      Base),
    put_extension(Extension, Base, Frame).

ui_facade_snapshot(SessionId, SnapshotId, View, Frame) :-
    ui_v1_snapshot_state(View, State),
    ui_v1_snapshot_frame(SessionId, SnapshotId, View.at_seq, State, Frame).

canonical_ui_event(agent_event(run_started, Meta0),
                   "run_started", Meta, none) :- !,
    safe_dict(Meta0, Meta).
canonical_ui_event(agent_event(message_started, MessageId, Role),
                   "message_started",
                   _{message_id:MessageId, role:Role}, none) :- !.
canonical_ui_event(agent_event(model_delta, MessageId, Text),
                   "text_delta",
                   _{message_id:MessageId, delta:Text}, none) :- !.
canonical_ui_event(agent_event(message_completed, MessageId),
                   "message_completed",
                   _{message_id:MessageId}, none) :- !.
canonical_ui_event(agent_event(tool_started, ToolId, Name, Arguments0),
                   "tool_started", Payload, none) :- !,
    safe_value(Arguments0, Arguments),
    Payload = _{tool_id:ToolId, name:Name, arguments:Arguments}.
canonical_ui_event(agent_event(tool_output, ToolId, Output0),
                   "tool_output", Payload, none) :- !,
    safe_value(Output0, Output),
    Payload = _{tool_id:ToolId, output:Output}.
canonical_ui_event(agent_event(tool_finished, ToolId, Outcome0),
                   "tool_finished", Payload, none) :- !,
    safe_value(Outcome0, Outcome),
    Payload = _{tool_id:ToolId, outcome:Outcome}.
canonical_ui_event(agent_event(approval_required,
                               ApprovalId,
                               ToolId,
                               Diff0,
                               Choices0),
                   "approval_required", Payload, none) :- !,
    safe_value(Diff0, Diff),
    safe_value(Choices0, Choices),
    Payload = _{approval_id:ApprovalId,
                tool_id:ToolId,
                diff:Diff,
                choices:Choices}.
canonical_ui_event(agent_event(approval_resolved, ApprovalId, Decision),
                   "approval_resolved",
                   _{approval_id:ApprovalId, decision:Decision}, none) :- !.
canonical_ui_event(agent_event(question_required,
                               QuestionId,
                               Prompt,
                               Choices0),
                   "question_required", Payload, none) :- !,
    safe_value(Choices0, Choices),
    Payload = _{question_id:QuestionId,
                prompt:Prompt,
                choices:Choices}.
canonical_ui_event(agent_event(question_answered, QuestionId, Answer0),
                   "question_answered", Payload, none) :- !,
    safe_value(Answer0, Answer),
    Payload = _{question_id:QuestionId, answer:Answer}.
canonical_ui_event(agent_event(subagent_started, SubagentId, Meta0),
                   "subagent_started", Payload, none) :- !,
    safe_dict(Meta0, Meta),
    put_dict(subagent_id, Meta, SubagentId, Payload).
canonical_ui_event(agent_event(subagent_finished, SubagentId, Outcome0),
                   "subagent_finished", Payload, none) :- !,
    safe_value(Outcome0, Outcome),
    Payload = _{subagent_id:SubagentId, outcome:Outcome}.
canonical_ui_event(agent_event(verification, Name, Outcome0),
                   "verification", Payload, none) :- !,
    safe_value(Outcome0, Outcome),
    Payload = _{name:Name, outcome:Outcome}.
canonical_ui_event(agent_event(usage, Usage0),
                   "usage", Usage, none) :- !,
    safe_dict(Usage0, Usage).
canonical_ui_event(agent_event(trace, Trace0),
                   "trace", Trace, none) :- !,
    safe_dict(Trace0, Trace).
canonical_ui_event(agent_event(effect_indeterminate, EffectId, Detail0),
                   "effect_indeterminate", Payload, none) :- !,
    safe_value(Detail0, Detail),
    Payload = _{effect_id:EffectId, detail:Detail}.
canonical_ui_event(agent_event(run_finished, Outcome0),
                   "run_finished", Payload, none) :- !,
    safe_value(Outcome0, Outcome),
    Payload = _{outcome:Outcome}.
canonical_ui_event(CanonicalEvent,
                   "agentprolog_unknown",
                   _{canonical:Encoded},
                   _{namespace:"agentprolog.canonical", required:false}) :-
    safe_value(CanonicalEvent, Encoded).

safe_dict(Value, Safe) :-
    (   is_dict(Value)
    ->  rlm_trace:trace_encode(Value, Safe)
    ;   safe_value(Value, Encoded),
        Safe = _{value:Encoded}
    ).

safe_value(Value, Safe) :-
    rlm_trace:trace_encode(Value, Safe).

put_extension(none, Frame, Frame) :- !.
put_extension(Extension, Frame0, Frame) :-
    put_dict(extension, Frame0, Extension, Frame).
