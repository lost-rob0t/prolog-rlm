:- module(agentprolog_ui,
          [ agentprolog_ui_ready/0,
            agentprolog_ui_initial_state/1,
            agentprolog_ui_handle/4,
            agentprolog_ui_handle/5,
            agentprolog_ui_server_loop/2
          ]).

/** <module> AgentProlog application adapter for prolog_agent_ui_v1

This module is application composition over the reusable frontend protocol.
It does not define a second wire format or runtime.  A submitted run is owned
by the canonical prolog-rlm async scheduler; the UI adapter keeps only the
opaque Future needed to poll or cancel that run.
*/

:- use_module(library(lists)).
:- use_module(library(readutil)).
:- use_module(library(uuid)).
:- use_module(library(rlm_async)).
:- use_module(library(rlm_cli)).
:- use_module(library(prolog_agent_ui_v1)).
:- use_module(library(prolog_agent_ui_facade)).
:- use_module(agentprolog_cli, [agentprolog_core_argv/2]).

:- meta_predicate agentprolog_ui_handle(+, +, -, -, 2).

agentprolog_ui_ready.

agentprolog_ui_initial_state(State) :-
    uuid(UUID, [version(4)]),
    format(string(SessionId), 'agentprolog_~w', [UUID]),
    State = agentprolog_ui_state{session_id:SessionId,
                                next_seq:1,
                                active:none}.

agentprolog_ui_handle(Frame, State0, State, Frames) :-
    agentprolog_ui_handle(Frame,
                          State0,
                          State,
                          Frames,
                          agentprolog_ui:production_submit).

agentprolog_ui_handle(Frame, State0, State, Frames, Submitter) :-
    catch(handle_frame(Frame, State0, State, Frames, Submitter),
          Exception,
          handle_exception(Frame, State0, State, Frames, Exception)).

handle_frame(Frame, State0, State, Frames, Submitter) :-
    ui_v1_validate_frame(Frame, Validation),
    (   Validation = error(Error)
    ->  validation_error_frame(Frame, State0, Error, ErrorFrame),
        State = State0,
        Frames = [ErrorFrame]
    ;   Frame.kind == "negotiate"
    ->  negotiate(Frame, State0, State, Frames)
    ;   Frame.kind == "command"
    ->  require_session(Frame, State0),
        handle_command(Frame, State0, State, Frames, Submitter)
    ;   protocol_error(Frame,
                       State0,
                       "unsupported_client_frame",
                       "AgentProlog accepts negotiate and command frames",
                       ErrorFrame),
        State = State0,
        Frames = [ErrorFrame]
    ).

negotiate(Frame, State, State, [Result, Snapshot]) :-
    Payload = Frame.payload,
    list_default(Payload, required_capabilities, [], Required),
    list_default(Payload, optional_capabilities, [], Optional),
    ui_v1_server_capabilities(Supported),
    intersection(Optional, Supported, AcceptedOptional),
    ui_v1_result_frame(State.session_id,
                       Frame.request_id,
                       "ok",
                       _{protocol:"prolog_agent_ui_v1",
                         required_capabilities:Required,
                         accepted_optional_capabilities:AcceptedOptional},
                       Result),
    ui_v1_initial_view(State.session_id, View),
    ui_facade_snapshot(State.session_id,
                       "snapshot_0",
                       View,
                       Snapshot).

handle_command(Frame, State0, State, Frames, Submitter) :-
    Command = Frame.command,
    handle_command_(Command, Frame, State0, State, Frames, Submitter).

handle_command_("run.submit", Frame, State0, State, Frames, Submitter) :-
    !,
    submit_run(Frame, State0, State, Frames, Submitter).
handle_command_("session.poll", Frame, State0, State, Frames, _) :-
    !,
    poll_run(Frame, State0, State, Frames).
handle_command_("session.cancel", Frame, State0, State, Frames, _) :-
    !,
    cancel_run(Frame, State0, State, Frames).
handle_command_(_, Frame, State, State, [Result], _) :-
    ui_v1_result_frame(State.session_id,
                       Frame.request_id,
                       "rejected",
                       _{code:"unknown_command", command:Frame.command},
                       Result).

submit_run(Frame, State0, State, Frames, Submitter) :-
    (   State0.active == none
    ->  submit_run_idle(Frame, State0, State, Frames, Submitter)
    ;   ui_v1_result_frame(State0.session_id,
                           Frame.request_id,
                           "rejected",
                           _{code:"run_active"},
                           Result),
        State = State0,
        Frames = [Result]
    ).

submit_run_idle(Frame, State0, State, [Result, Started], Submitter) :-
    submit_payload_argv(Frame.payload, AppArgv),
    uuid(UUID, [version(4)]),
    format(string(RunId), 'run_~w', [UUID]),
    call(Submitter, AppArgv, Future),
    ui_v1_result_frame(State0.session_id,
                       Frame.request_id,
                       "ok",
                       _{accepted:true, run_id:RunId},
                       Result),
    next_event(State0,
               agent_event(run_started,
                           _{run_id:RunId,
                             query:Frame.payload.query}),
               Frame.request_id,
               Started,
               State1),
    Active = run{run_id:RunId,
                 request_id:Frame.request_id,
                 future:Future},
    put_dict(active, State1, Active, State).

poll_run(Frame, State0, State, Frames) :-
    (   State0.active == none
    ->  ui_v1_result_frame(State0.session_id,
                           Frame.request_id,
                           "ok",
                           _{state:"idle"},
                           Result),
        State = State0,
        Frames = [Result]
    ;   Active = State0.active,
        Future = Active.future,
        rlm_future_status(Future, Status),
        poll_status(Status, Frame, Active, State0, State, Frames)
    ).

poll_status(Status, Frame, Active, State, State, [Result]) :-
    memberchk(Status.state, [pending, running]),
    !,
    ui_v1_result_frame(State.session_id,
                       Frame.request_id,
                       "ok",
                       _{state:"running", run_id:Active.run_id},
                       Result).
poll_status(Status, Frame, Active, State0, State, [Result, Finished]) :-
    Status.state == completed,
    !,
    Outcome = Status.outcome,
    safe_destroy(Active.future),
    put_dict(active, State0, none, Cleared),
    ui_v1_result_frame(State0.session_id,
                       Frame.request_id,
                       "ok",
                       _{state:"completed", run_id:Active.run_id},
                       Result),
    next_event(Cleared,
               agent_event(run_finished, Outcome),
               Active.request_id,
               Finished,
               State).
poll_status(Status, Frame, Active, State0, State, [Result, Finished]) :-
    Status.state == cancelled,
    !,
    safe_destroy(Active.future),
    put_dict(active, State0, none, Cleared),
    ui_v1_result_frame(State0.session_id,
                       Frame.request_id,
                       "ok",
                       _{state:"cancelled", run_id:Active.run_id},
                       Result),
    next_event(Cleared,
               agent_event(run_finished, cancelled),
               Active.request_id,
               Finished,
               State).

cancel_run(Frame, State0, State, Frames) :-
    (   State0.active == none
    ->  ui_v1_result_frame(State0.session_id,
                           Frame.request_id,
                           "rejected",
                           _{code:"no_active_run"},
                           Result),
        State = State0,
        Frames = [Result]
    ;   Active = State0.active,
        rlm_future_cancel(Active.future, _),
        safe_destroy(Active.future),
        put_dict(active, State0, none, Cleared),
        ui_v1_result_frame(State0.session_id,
                           Frame.request_id,
                           "ok",
                           _{accepted:true,
                             state:"cancelled",
                             run_id:Active.run_id},
                           Result),
        next_event(Cleared,
                   agent_event(run_finished, cancelled),
                   Frame.request_id,
                   Finished,
                   State),
        Frames = [Result, Finished]
    ).

submit_payload_argv(Payload, Argv) :-
    required_string(Payload, query, Query),
    optional_string(Payload, provider, Provider),
    optional_string(Payload, model, Model),
    submit_argv(Query, Provider, Model, Argv).

submit_argv(Query, none, none, [ask, Query]).
submit_argv(Query, Provider, none,
            [ask, Query, '--provider', Provider]) :-
    Provider \== none.
submit_argv(Query, none, Model,
            [ask, Query, '--model', Model]) :-
    Model \== none.
submit_argv(Query, Provider, Model,
            [ask, Query,
             '--provider', Provider,
             '--model', Model]) :-
    Provider \== none,
    Model \== none.

production_submit(AppArgv, Future) :-
    rlm_async_submit(agentprolog_ui:run_task(AppArgv),
                     async_metadata{operation:agentprolog_ui_run},
                     Future).

run_task(AppArgv, Outcome) :-
    agentprolog_core_argv(AppArgv, CoreArgv),
    rlm_cli:cli_run(CoreArgv, Outcome).

next_event(State0, Canonical, CausedBy, Frame, State) :-
    Seq = State0.next_seq,
    ui_facade_event(State0.session_id,
                    Seq,
                    Canonical,
                    CausedBy,
                    Frame),
    Next is Seq + 1,
    put_dict(next_seq, State0, Next, State).

require_session(Frame, State) :-
    (   Frame.session_id == State.session_id
    ->  true
    ;   throw(agentprolog_ui_fault(session_mismatch,
                                   _{expected:State.session_id,
                                     got:Frame.session_id}))
    ).

agentprolog_ui_server_loop(In, Out) :-
    agentprolog_ui_initial_state(State0),
    server_loop(In, Out, State0).

server_loop(In, Out, State0) :-
    read_line_to_string(In, Line),
    (   Line == end_of_file
    ->  cleanup_state(State0)
    ;   ui_v1_decode_frame(Line, Decoded),
        dispatch_decoded(Decoded, State0, State, Frames),
        write_frames(Out, Frames),
        server_loop(In, Out, State)
    ).

dispatch_decoded(error(Error), State, State, [Frame]) :-
    !,
    ui_v1_error_frame(State.session_id,
                      none,
                      Error.code,
                      Error.message,
                      Base),
    put_dict(details, Base, Error.details, Frame).
dispatch_decoded(ok(Frame), State0, State, Frames) :-
    agentprolog_ui_handle(Frame, State0, State, Frames).

write_frames(_, []).
write_frames(Out, [Frame|Rest]) :-
    ui_v1_encode_frame(Frame, Encoded),
    encoded_line(Encoded, Line),
    format(Out, '~s~n', [Line]),
    flush_output(Out),
    write_frames(Out, Rest).

encoded_line(ok(Line), Line) :- !.
encoded_line(error(Error), _) :-
    throw(error(agentprolog_ui_encode_failed(Error), _)).

cleanup_state(State) :-
    (   State.active == none
    ->  true
    ;   catch(rlm_future_cancel(State.active.future, _), _, true),
        safe_destroy(State.active.future)
    ).

safe_destroy(Future) :-
    catch(rlm_future_destroy(Future), _, true).

validation_error_frame(Frame, State, Error, ErrorFrame) :-
    frame_request(Frame, RequestId),
    ui_v1_error_frame(State.session_id,
                      RequestId,
                      Error.code,
                      Error.message,
                      Base),
    put_dict(details, Base, Error.details, ErrorFrame).

protocol_error(Frame, State, Code, Message, ErrorFrame) :-
    frame_request(Frame, RequestId),
    ui_v1_error_frame(State.session_id,
                      RequestId,
                      Code,
                      Message,
                      ErrorFrame).

handle_exception(Frame, State, State, [ErrorFrame], Exception) :-
    frame_request(Frame, RequestId),
    exception_detail(Exception, Code, Details),
    ui_v1_error_frame(State.session_id,
                      RequestId,
                      Code,
                      "AgentProlog UI request failed",
                      Base),
    put_dict(details, Base, Details, ErrorFrame).

exception_detail(agentprolog_ui_fault(Code, Details), CodeString, Details) :-
    !,
    atom_string(Code, CodeString).
exception_detail(Exception,
                 "request_exception",
                 _{exception:Text}) :-
    term_string(Exception, Text, [quoted(true), numbervars(true)]).

frame_request(Frame, RequestId) :-
    (   is_dict(Frame),
        get_dict(request_id, Frame, Found),
        string(Found)
    ->  RequestId = Found
    ;   RequestId = none
    ).

required_string(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value),
        string(Value),
        Value \== ""
    ->  true
    ;   throw(agentprolog_ui_fault(invalid_payload,
                                   _{field:Key,
                                     expected:"non-empty string"}))
    ).

optional_string(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Found)
    ->  (   string(Found), Found \== ""
        ->  Value = Found
        ;   throw(agentprolog_ui_fault(invalid_payload,
                                       _{field:Key,
                                         expected:"non-empty string"}))
        )
    ;   Value = none
    ).

list_default(Dict, Key, Default, Value) :-
    (get_dict(Key, Dict, Found) -> Value = Found ; Value = Default).
