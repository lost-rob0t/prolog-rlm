:- module(deepseek_prolog_host_bridge,
          [ deepseek_host_bridge_ready/0,
            deepseek_host_bridge_open/2,
            deepseek_host_bridge_close/1,
            deepseek_host_bridge_handle/2
          ]).

/** <module> Lossless DeepSeek Harness host projection boundary

This decorates the core NDJSON authority bridge with the one piece of durable
projection metadata DeepSeek Harness requires but the current generic
conversation record does not yet retain: provider/model provenance for each
assistant message.

Message content remains canonical in `rlm_conversation`. The side ledger stores
no prompts or content and is used only to reconstruct an honest Harness
`AssistantMessage.source` on resume. A missing historical route is surfaced as
missing provenance; the host must fail closed rather than relabel the old
message with today's provider setting.
*/

:- use_module(deepseek_prolog_bridge).
:- use_module(deepseek_prolog_route_store).

deepseek_host_bridge_ready :-
    deepseek_prolog_bridge:deepseek_bridge_ready,
    deepseek_prolog_route_store:deepseek_route_store_ready.

deepseek_host_bridge_open(SettingsPath, Outcome) :-
    host_outcome(open,
                 deepseek_host_bridge_open_(SettingsPath),
                 Outcome).

deepseek_host_bridge_open_(SettingsPath, Info) :-
    deepseek_prolog_bridge:deepseek_bridge_open(SettingsPath, BridgeOutcome),
    require_ok(BridgeOutcome, Info),
    route_store_spec(Info, RouteSpec),
    deepseek_prolog_route_store:deepseek_route_store_open(RouteSpec,
                                                         RouteOutcome),
    (   RouteOutcome = ok(_)
    ->  true
    ;   deepseek_prolog_bridge:deepseek_bridge_close(_),
        require_ok(RouteOutcome, _)
    ).

deepseek_host_bridge_close(Outcome) :-
    host_outcome(close,
                 deepseek_host_bridge_close_,
                 Outcome).

deepseek_host_bridge_close_(closed) :-
    deepseek_prolog_route_store:deepseek_route_store_close(RouteOutcome),
    deepseek_prolog_bridge:deepseek_bridge_close(BridgeOutcome),
    require_ok(RouteOutcome, _),
    require_ok(BridgeOutcome, _).

deepseek_host_bridge_handle(Request, Response) :-
    deepseek_prolog_bridge:deepseek_bridge_handle(Request, BaseResponse),
    catch(decorate_response(Request, BaseResponse, Response),
          Exception,
          decoration_error(BaseResponse, Exception, Response)).

decorate_response(Request, BaseResponse, Response) :-
    (   BaseResponse.ok == true
    ->  command_name(Request, Command),
        decorate_success(Command, Request, BaseResponse, Response)
    ;   Response = BaseResponse
    ).

decorate_success("session/turn", Request, BaseResponse, Response) :-
    !,
    request_session_id(Request, SessionId),
    persist_turn_route(SessionId, BaseResponse.result),
    Response = BaseResponse.
decorate_success("run/result", _, BaseResponse, Response) :-
    !,
    maybe_persist_async_route(BaseResponse.result),
    Response = BaseResponse.
decorate_success("session/messages", Request, BaseResponse, Response) :-
    !,
    request_session_id(Request, SessionId),
    maplist(enrich_message(SessionId), BaseResponse.result, Messages),
    put_dict(result, BaseResponse, Messages, Response).
decorate_success("session/search", Request, BaseResponse, Response) :-
    !,
    request_session_id(Request, SessionId),
    maplist(enrich_message(SessionId), BaseResponse.result, Messages),
    put_dict(result, BaseResponse, Messages, Response).
decorate_success(_, _, Response, Response).

persist_turn_route(SessionId, Turn) :-
    Assistant = Turn.assistant,
    Route = Turn.route,
    require_route(Route, Provider, Model),
    deepseek_prolog_route_store:deepseek_route_store_put(
        SessionId,
        Assistant.sequence,
        Provider,
        Model,
        Outcome),
    require_ok(Outcome, _).

maybe_persist_async_route(Result) :-
    (   Result.state == "completed",
        get_dict(turn, Result, Turn)
    ->  SessionId = Result.session_id,
        persist_turn_route(SessionId, Turn)
    ;   true
    ).

enrich_message(SessionId, Message0, Message) :-
    (   Message0.role == "assistant"
    ->  deepseek_prolog_route_store:deepseek_route_store_get(
            SessionId,
            Message0.sequence,
            RouteOutcome),
        route_projection(RouteOutcome, Route),
        put_dict(route, Message0, Route, Message)
    ;   Message = Message0
    ).

route_projection(ok(Route0), Route) :-
    !,
    atom_string(Route0.provider, Provider),
    atom_string(Route0.model, Model),
    Route = _{provider:Provider, model:Model}.
route_projection(error(_), null).

route_store_spec(Info, memory) :-
    Info.persist_sessions == false,
    !.
route_store_spec(Info, persist(RoutePath)) :-
    atom_string(StorePath, Info.conversation_store),
    atom_concat(StorePath, '.deepseek-routes.db', RoutePath).

require_route(Route, Provider, Model) :-
    (   is_dict(Route),
        get_dict(provider, Route, Provider0),
        get_dict(model, Route, Model0),
        string(Provider0),
        string(Model0),
        Provider0 \== "",
        Model0 \== ""
    ->  atom_string(Provider, Provider0),
        atom_string(Model, Model0)
    ;   throw(host_bridge_fault(invalid_completion_route(Route)))
    ).

command_name(Request, Command) :-
    (   is_dict(Request),
        get_dict(command, Request, Command0),
        string(Command0)
    ->  Command = Command0
    ;   Command = ""
    ).

request_session_id(Request, SessionId) :-
    Payload = Request.payload,
    (   get_dict(session_id, Payload, SessionId0),
        string(SessionId0)
    ->  SessionId = SessionId0
    ;   throw(host_bridge_fault(missing_session_id))
    ).

require_ok(ok(Value), Value) :-
    !.
require_ok(error(Error), _) :-
    throw(host_bridge_fault(dependency_failed(Error))).

decoration_error(BaseResponse, Exception, Response) :-
    safe_exception(Exception, Safe),
    Response = _{protocol:BaseResponse.protocol,
                 request_id:BaseResponse.request_id,
                 ok:false,
                 error:_{kind:"host_projection_error",
                         message:"DeepSeek Harness host projection failed after canonical Prolog operation",
                         detail:Safe}}.

host_outcome(Phase, Goal, Outcome) :-
    catch(( call(Goal, Value),
            Outcome = ok(Value)
          ),
          Exception,
          host_exception(Phase, Exception, Outcome)).

host_exception(Phase, host_bridge_fault(Detail), error(Error)) :-
    !,
    Error = host_bridge_error{phase:Phase,
                              kind:host_bridge_error,
                              detail:Detail,
                              message:"DeepSeek Harness host bridge operation failed"}.
host_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = host_bridge_error{phase:Phase,
                              kind:exception,
                              exception:Safe,
                              message:"DeepSeek Harness host bridge raised an exception"}.

safe_exception(Exception, Safe) :-
    with_output_to(string(Safe),
                   write_term(Exception,
                              [ quoted(true),
                                portray(false),
                                max_depth(14)
                              ])).
