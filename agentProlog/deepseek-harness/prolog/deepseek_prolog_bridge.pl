:- module(deepseek_prolog_bridge,
          [ deepseek_bridge_ready/0,
            deepseek_bridge_open/2,
            deepseek_bridge_close/1,
            deepseek_bridge_handle/2,
            deepseek_bridge_completion_options/3
          ]).

/** <module> DeepSeek Harness to Prolog-RLM authority bridge

This is not an agent loop. It is a narrow application boundary used by the
DeepSeek Harness frontend/host path. Durable conversation state and every model
turn remain owned by `rlm_conversation`; provider-visible history is a bounded
projection over the lossless transcript and no compaction replacement is
permitted.

The bridge exposes asynchronous turn handles so a host can remain responsive
while Prolog owns execution. The handles are wrappers over the canonical
`rlm_async` runtime, including its real cancellation semantics. They are not a
second scheduler.
*/

:- use_module(library(filesex)).
:- use_module(library(uuid)).
:- use_module(deepseek_prolog_settings).
:- use_module('../../../prolog/rlm_async').
:- use_module('../../../prolog/rlm_conversation').

:- dynamic bridge_runtime/3.
:- dynamic bridge_run/5.

deepseek_bridge_ready :-
    deepseek_prolog_settings:deepseek_settings_ready,
    rlm_async:rlm_async_ready,
    rlm_conversation:rlm_conversation_ready.

deepseek_bridge_open(SettingsPath, Outcome) :-
    bridge_outcome(open,
                   deepseek_bridge_open_(SettingsPath),
                   Outcome).

deepseek_bridge_open_(SettingsPath0, Info) :-
    path_atom(SettingsPath0, SettingsPath),
    close_runtime_if_open,
    deepseek_prolog_settings:deepseek_settings_load(SettingsPath,
                                                    SettingsOutcome),
    require_ok(SettingsOutcome, Settings),
    deepseek_prolog_settings:deepseek_settings_save(SettingsPath,
                                                    Settings,
                                                    SaveOutcome),
    require_ok(SaveOutcome, PersistedSettings),
    open_settings_store(PersistedSettings, Store),
    assertz(bridge_runtime(SettingsPath, PersistedSettings, Store)),
    runtime_info(PersistedSettings, Info).

deepseek_bridge_close(Outcome) :-
    bridge_outcome(close,
                   deepseek_bridge_close_,
                   Outcome).

deepseek_bridge_close_(closed) :-
    close_runtime_if_open.

close_runtime_if_open :-
    close_all_runs,
    (   retract(bridge_runtime(_, _, Store))
    ->  rlm_conversation:conversation_store_close(Store, _),
        retractall(bridge_runtime(_, _, _))
    ;   true
    ).

close_all_runs :-
    findall(Future, bridge_run(_, _, Future, _, _), Futures0),
    sort(Futures0, Futures),
    maplist(cancel_and_destroy_future, Futures),
    retractall(bridge_run(_, _, _, _, _)).

cancel_and_destroy_future(Future) :-
    catch(rlm_async:rlm_future_cancel(Future, _), _, true),
    catch(rlm_async:rlm_future_destroy(Future), _, true).

open_settings_store(Settings, Store) :-
    (   Settings.persist_sessions == true
    ->  atom_string(StorePath, Settings.conversation_store),
        file_directory_name(StorePath, StoreDirectory),
        make_directory_path(StoreDirectory),
        StoreSpec = persist(StorePath)
    ;   StoreSpec = memory
    ),
    rlm_conversation:conversation_store_open(StoreSpec, StoreOutcome),
    require_ok(StoreOutcome, Store).

deepseek_bridge_handle(Request, Response) :-
    request_id(Request, RequestId),
    catch(( bridge_request(Request, Result),
            response_ok(RequestId, Result, Response)
          ),
          Exception,
          response_error(RequestId, Exception, Response)).

bridge_request(Request, Result) :-
    require_dict(Request, request),
    require_string_key(Request, command, Command),
    dict_default(Request, payload, _{}, Payload),
    require_dict(Payload, payload),
    bridge_command(Command, Payload, Result).

bridge_command("hello", _, Result) :-
    !,
    current_runtime(_, Settings, _),
    runtime_info(Settings, Runtime),
    Result = _{protocol:"prolog_rlm_deepseek_bridge_v1",
               driver:"prolog-rlm",
               canonical_agent_runtime:"prolog-rlm",
               history_mode:"lossless_rlm",
               compaction:false,
               turn_execution:"rlm_async",
               commands:["settings/get",
                         "settings/set",
                         "session/create",
                         "session/open",
                         "session/list",
                         "session/messages",
                         "session/search",
                         "session/stats",
                         "session/turn",
                         "session/turn/start",
                         "run/status",
                         "run/result",
                         "run/cancel"],
               runtime:Runtime}.
bridge_command("settings/get", _, Settings) :-
    !,
    current_runtime(_, Settings, _).
bridge_command("settings/set", Payload, Result) :-
    !,
    require_dict_key(Payload, settings, Patch),
    require_dict(Patch, settings),
    current_runtime(SettingsPath, Current, _),
    put_dict(Patch, Current, Candidate),
    deepseek_prolog_settings:deepseek_settings_save(SettingsPath,
                                                    Candidate,
                                                    SaveOutcome),
    require_ok(SaveOutcome, Settings),
    close_runtime_if_open,
    open_settings_store(Settings, Store),
    assertz(bridge_runtime(SettingsPath, Settings, Store)),
    runtime_info(Settings, Result).
bridge_command("session/create", Payload, Result) :-
    !,
    current_runtime(_, _, Store),
    create_options(Payload, Options),
    rlm_conversation:conversation_create(Store, Options, Outcome),
    require_ok(Outcome, Conversation),
    conversation_view(Conversation, Result).
bridge_command("session/open", Payload, Result) :-
    !,
    open_payload_conversation(Payload, Conversation),
    conversation_view(Conversation, Result).
bridge_command("session/list", Payload, Result) :-
    !,
    current_runtime(_, _, Store),
    dict_default(Payload, limit, 64, Limit),
    require_nonnegative_integer(Limit, limit),
    rlm_conversation:conversation_list(Store,
                                       [order(desc), limit(Limit)],
                                       Outcome),
    require_ok(Outcome, Conversations),
    maplist(conversation_view, Conversations, Result).
bridge_command("session/messages", Payload, Result) :-
    !,
    open_payload_conversation(Payload, Conversation),
    dict_default(Payload, limit, all, Limit0),
    message_limit(Limit0, Limit),
    rlm_conversation:conversation_messages(Conversation,
                                           all,
                                           [limit(Limit)],
                                           Outcome),
    require_ok(Outcome, Messages),
    maplist(message_view, Messages, Result).
bridge_command("session/search", Payload, Result) :-
    !,
    open_payload_conversation(Payload, Conversation),
    require_string_key(Payload, query, Query),
    dict_default(Payload, max_results, 32, MaxResults),
    require_positive_integer(MaxResults, max_results),
    rlm_conversation:conversation_search(Conversation,
                                         Query,
                                         [max_results(MaxResults)],
                                         Outcome),
    require_ok(Outcome, Messages),
    maplist(message_view, Messages, Result).
bridge_command("session/stats", Payload, Result) :-
    !,
    open_payload_conversation(Payload, Conversation),
    rlm_conversation:conversation_stats(Conversation, Outcome),
    require_ok(Outcome, Stats),
    stats_view(Stats, Result).
bridge_command("session/turn", Payload, Result) :-
    !,
    prepare_turn(Payload, Conversation, Content, TurnOptions, Route),
    ensure_session_not_running(Conversation.id),
    rlm_conversation:conversation_turn(Conversation,
                                       message(user, Content),
                                       TurnOptions,
                                       TurnOutcome),
    require_ok(TurnOutcome, Turn),
    turn_view(Turn, Route, Result).
bridge_command("session/turn/start", Payload, Result) :-
    !,
    prepare_turn(Payload, Conversation, Content, TurnOptions, Route),
    ensure_session_not_running(Conversation.id),
    uuid(RunId, [version(4)]),
    get_time(StartedAt),
    Metadata = async_metadata{operation:deepseek_harness_turn,
                              session_id:Conversation.id,
                              run_id:RunId},
    rlm_async:rlm_async_submit(
        deepseek_prolog_bridge:bridge_turn_task(Conversation,
                                                Content,
                                                TurnOptions),
        Metadata,
        Future),
    assertz(bridge_run(RunId,
                       Conversation.id,
                       Future,
                       Route,
                       StartedAt)),
    run_identity_view(RunId, Conversation.id, StartedAt, "pending", Result).
bridge_command("run/status", Payload, Result) :-
    !,
    payload_run(Payload, RunId, SessionId, Future, _, StartedAt),
    rlm_async:rlm_future_status(Future, Status),
    run_status_view(RunId, SessionId, StartedAt, Status, Result).
bridge_command("run/result", Payload, Result) :-
    !,
    payload_run(Payload, RunId, SessionId, Future, Route, StartedAt),
    rlm_async:rlm_future_status(Future, Status),
    run_result_view(RunId,
                    SessionId,
                    StartedAt,
                    Future,
                    Route,
                    Status,
                    Result).
bridge_command("run/cancel", Payload, Result) :-
    !,
    payload_run(Payload, RunId, SessionId, Future, _, StartedAt),
    rlm_async:rlm_future_cancel(Future, CancelOutcome),
    cancel_outcome_state(CancelOutcome, State),
    run_identity_view(RunId, SessionId, StartedAt, State, Result).
bridge_command(Command, _, _) :-
    throw(bridge_fault(unknown_command(Command))).

prepare_turn(Payload, Conversation, Content, TurnOptions, Route) :-
    open_payload_conversation(Payload, Conversation),
    require_string_key(Payload, content, Content),
    current_runtime(_, Settings, _),
    deepseek_bridge_completion_options(Settings,
                                       CompletionOptions,
                                       Route),
    TurnOptions = [completion_options(CompletionOptions)].

bridge_turn_task(Conversation, Content, TurnOptions, TurnOutcome) :-
    rlm_conversation:conversation_turn(Conversation,
                                       message(user, Content),
                                       TurnOptions,
                                       TurnOutcome).

ensure_session_not_running(SessionId) :-
    (   bridge_run(RunId, SessionId, Future, _, _),
        future_active(Future)
    ->  atom_string(RunId, RunIdString),
        throw(bridge_fault(session_busy(SessionId, RunIdString)))
    ;   true
    ).

future_active(Future) :-
    catch(rlm_async:rlm_future_status(Future, Status), _, fail),
    memberchk(Status.state, [pending, running]).

payload_run(Payload, RunId, SessionId, Future, Route, StartedAt) :-
    require_string_key(Payload, run_id, RunIdString),
    atom_string(RunId, RunIdString),
    (   bridge_run(RunId, SessionId, Future, Route, StartedAt)
    ->  true
    ;   throw(bridge_fault(unknown_run(RunIdString)))
    ).

run_status_view(RunId, SessionId, StartedAt, Status, Result) :-
    atom_string(Status.state, State),
    run_identity_view(RunId, SessionId, StartedAt, State, Base),
    (   Status.state == completed
    ->  terminal_outcome_kind(Status.outcome, Kind),
        put_dict(outcome_kind, Base, Kind, Result)
    ;   Result = Base
    ).

terminal_outcome_kind(ok(_), "ok") :- !.
terminal_outcome_kind(error(_), "error") :- !.
terminal_outcome_kind(_, "unknown").

run_result_view(RunId,
                SessionId,
                StartedAt,
                Future,
                Route,
                Status,
                Result) :-
    (   Status.state == completed
    ->  consume_completed_run(RunId,
                              SessionId,
                              StartedAt,
                              Future,
                              Route,
                              Status.outcome,
                              Result)
    ;   Status.state == cancelled
    ->  consume_cancelled_run(RunId,
                              SessionId,
                              StartedAt,
                              Future,
                              Result)
    ;   atom_string(Status.state, State),
        run_identity_view(RunId, SessionId, StartedAt, State, Result)
    ).

consume_completed_run(RunId,
                      SessionId,
                      StartedAt,
                      Future,
                      Route,
                      ok(Turn),
                      Result) :-
    !,
    turn_view(Turn, Route, TurnView),
    run_identity_view(RunId,
                      SessionId,
                      StartedAt,
                      "completed",
                      Base),
    put_dict(turn, Base, TurnView, Result),
    forget_run(RunId, Future).
consume_completed_run(RunId,
                      SessionId,
                      StartedAt,
                      Future,
                      _,
                      error(Error),
                      Result) :-
    !,
    wire_safe(Error, ErrorView),
    run_identity_view(RunId,
                      SessionId,
                      StartedAt,
                      "failed",
                      Base),
    put_dict(error, Base, ErrorView, Result),
    forget_run(RunId, Future).
consume_completed_run(RunId,
                      SessionId,
                      StartedAt,
                      Future,
                      _,
                      Outcome,
                      Result) :-
    wire_safe(Outcome, OutcomeView),
    run_identity_view(RunId,
                      SessionId,
                      StartedAt,
                      "failed",
                      Base),
    put_dict(error, Base, OutcomeView, Result),
    forget_run(RunId, Future).

consume_cancelled_run(RunId, SessionId, StartedAt, Future, Result) :-
    run_identity_view(RunId,
                      SessionId,
                      StartedAt,
                      "cancelled",
                      Result),
    forget_run(RunId, Future).

forget_run(RunId, Future) :-
    retractall(bridge_run(RunId, _, Future, _, _)),
    catch(rlm_async:rlm_future_destroy(Future), _, true).

cancel_outcome_state(ok(cancelled), "cancelled") :- !.
cancel_outcome_state(ok(already_cancelled), "cancelled") :- !.
cancel_outcome_state(ok(already_completed), "completed") :- !.
cancel_outcome_state(_, "unknown").

run_identity_view(RunId, SessionId, StartedAt, State,
                  _{run_id:RunIdString,
                    session_id:SessionIdString,
                    state:State,
                    started_at:StartedAt,
                    canonical_agent_runtime:"prolog-rlm"}) :-
    atom_string(RunId, RunIdString),
    atom_string(SessionId, SessionIdString).

deepseek_bridge_completion_options(Settings, Options, Route) :-
    deepseek_prolog_settings:deepseek_settings_provider(Settings,
                                                       ProviderOutcome),
    require_ok(ProviderOutcome, Selection),
    Options = [provider(Selection.provider),
               provider_name(Selection.name)],
    atom_string(Selection.name, ProviderName),
    atom_string(Selection.model, Model),
    Route = _{provider:ProviderName,
              model:Model,
              history_mode:"lossless_rlm",
              compaction:false}.

create_options(Payload, Options) :-
    dict_default(Payload, metadata, _{}, Metadata),
    require_dict(Metadata, metadata),
    (   get_dict(id, Payload, Id0)
    ->  require_string(Id0, id),
        atom_string(Id, Id0),
        Options = [id(Id), metadata(Metadata)]
    ;   Options = [metadata(Metadata)]
    ).

open_payload_conversation(Payload, Conversation) :-
    require_string_key(Payload, session_id, Id0),
    atom_string(Id, Id0),
    current_runtime(_, _, Store),
    rlm_conversation:conversation_open(Store, Id, Outcome),
    require_ok(Outcome, Conversation).

runtime_info(Settings,
             _{provider:Settings.provider,
               model:Settings.model,
               persist_sessions:Settings.persist_sessions,
               conversation_store:Settings.conversation_store,
               history_mode:"lossless_rlm",
               compaction:false,
               turn_execution:"rlm_async"}).

conversation_view(Conversation, View) :-
    atom_string(Conversation.id, Id),
    View = _{session_id:Id,
             created_at:Conversation.created_at,
             metadata:Conversation.metadata,
             history_mode:"lossless_rlm",
             compaction:false}.

message_view(Message, View) :-
    atom_string(Message.role, Role),
    content_text(Message.content, Content),
    View = _{sequence:Message.sequence,
             role:Role,
             content:Content,
             created_at:Message.created_at}.

stats_view(Stats, View) :-
    atom_string(Stats.conversation_id, Id),
    View = _{session_id:Id,
             messages:Stats.messages,
             user_messages:Stats.user_messages,
             assistant_messages:Stats.assistant_messages,
             tool_messages:Stats.tool_messages,
             system_messages:Stats.system_messages,
             history_mode:"lossless_rlm",
             compaction:false}.

turn_view(Turn, Route, View) :-
    message_view(Turn.user, User),
    message_view(Turn.assistant, Assistant),
    length(Turn.context.selected, SelectedCount),
    View = _{user:User,
             assistant:Assistant,
             route:Route,
             context:_{selected_units:SelectedCount,
                       history_mode:"lossless_rlm",
                       complete_transcript_retained:true,
                       cold_history_available:true,
                       compaction:false}}.

content_text(Content, Content) :-
    string(Content),
    !.
content_text(Content, Text) :-
    atom(Content),
    !,
    atom_string(Content, Text).
content_text(Content, Text) :-
    with_output_to(string(Text),
                   write_term(Content,
                              [ quoted(true),
                                portray(false),
                                max_depth(20)
                              ])).

wire_safe(Value, "<unbound>") :-
    var(Value),
    !.
wire_safe(Value, Value) :-
    string(Value),
    !.
wire_safe(Value, Value) :-
    number(Value),
    !.
wire_safe(true, true) :- !.
wire_safe(false, false) :- !.
wire_safe(null, null) :- !.
wire_safe(Value, String) :-
    atom(Value),
    !,
    atom_string(Value, String).
wire_safe(Value, Safe) :-
    is_dict(Value),
    !,
    dict_pairs(Value, Tag, Pairs0),
    maplist(wire_safe_pair, Pairs0, Pairs),
    dict_pairs(Safe, Tag, Pairs).
wire_safe(Value, Safe) :-
    is_list(Value),
    !,
    maplist(wire_safe, Value, Safe).
wire_safe(Value, String) :-
    with_output_to(string(String),
                   write_term(Value,
                              [ quoted(true),
                                portray(false),
                                max_depth(20)
                              ])).

wire_safe_pair(Key-Value, Key-Safe) :-
    wire_safe(Value, Safe).

current_runtime(SettingsPath, Settings, Store) :-
    bridge_runtime(SettingsPath, Settings, Store),
    !.
current_runtime(_, _, _) :-
    throw(bridge_fault(not_open)).

message_limit("all", all) :- !.
message_limit(all, all) :- !.
message_limit(Value, Value) :-
    require_nonnegative_integer(Value, limit).

request_id(Request, RequestId) :-
    (   is_dict(Request),
        get_dict(request_id, Request, Id),
        string(Id)
    ->  RequestId = Id
    ;   RequestId = null
    ).

response_ok(RequestId, Result,
            _{protocol:"prolog_rlm_deepseek_bridge_v1",
              request_id:RequestId,
              ok:true,
              result:Result}).

response_error(RequestId, Exception,
               _{protocol:"prolog_rlm_deepseek_bridge_v1",
                 request_id:RequestId,
                 ok:false,
                 error:Safe}) :-
    safe_exception(Exception, Safe).

bridge_outcome(Phase, Goal, Outcome) :-
    catch(( call(Goal, Value),
            Outcome = ok(Value)
          ),
          Exception,
          bridge_exception(Phase, Exception, Outcome)).

bridge_exception(Phase, bridge_fault(Detail), error(Error)) :-
    !,
    Error = bridge_error{phase:Phase,
                         kind:bridge_error,
                         detail:Detail,
                         message:"DeepSeek Harness Prolog bridge operation failed"}.
bridge_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = bridge_error{phase:Phase,
                         kind:exception,
                         exception:Safe,
                         message:"DeepSeek Harness Prolog bridge operation raised an exception"}.

require_ok(ok(Value), Value) :-
    !.
require_ok(error(Error), _) :-
    throw(bridge_fault(dependency_failed(Error))).

require_dict(Value, _) :-
    is_dict(Value),
    !.
require_dict(Value, Name) :-
    throw(bridge_fault(expected_dict(Name, Value))).

require_dict_key(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(bridge_fault(missing_key(Key)))
    ).

require_string_key(Dict, Key, Value) :-
    require_dict_key(Dict, Key, Value),
    require_string(Value, Key).

require_string(Value, _) :-
    string(Value),
    !.
require_string(Value, Name) :-
    throw(bridge_fault(expected_string(Name, Value))).

require_nonnegative_integer(Value, _) :-
    integer(Value),
    Value >= 0,
    !.
require_nonnegative_integer(Value, Name) :-
    throw(bridge_fault(expected_nonnegative_integer(Name, Value))).

require_positive_integer(Value, _) :-
    integer(Value),
    Value > 0,
    !.
require_positive_integer(Value, Name) :-
    throw(bridge_fault(expected_positive_integer(Name, Value))).

dict_default(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

path_atom(Value, Value) :-
    atom(Value),
    !.
path_atom(Value, Atom) :-
    string(Value),
    !,
    atom_string(Atom, Value).
path_atom(Value, _) :-
    throw(bridge_fault(expected_path(Value))).

safe_exception(Exception, Safe) :-
    with_output_to(string(Safe),
                   write_term(Exception,
                              [ quoted(true),
                                portray(false),
                                max_depth(16)
                              ])).
