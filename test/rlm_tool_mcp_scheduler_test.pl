:- begin_tests(rlm_tool_mcp_scheduler).

:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_mcp').

slow_tool_schema(
    tool_schema{
        name:scheduler_echo,
        description:"shared scheduler fixture",
        capability:tool(scheduler_echo),
        arguments:_{type:object,
                    required:[value],
                    additional_properties:false,
                    properties:_{value:_{type:integer}}},
        result:_{type:integer},
        limits:_{time_limit:2.0, max_output_bytes:1024}
    }).

slow_tool(Args, Value) :-
    sleep(0.03),
    Value = Args.value.

scheduler_client_info(_{name:"scheduler-client", version:"1.0"}).
scheduler_client_caps(_{roots:_{listChanged:false}}).
scheduler_server_info(_{name:"scheduler-server", version:"1.0"}).
scheduler_server_caps(_{tools:_{listChanged:false}}).

scheduler_fixture(Wire, _, Response) :-
    get_dict(method, Wire, Method),
    scheduler_method(Method, Wire, Response).

scheduler_method("initialize", Wire, Response) :-
    scheduler_server_info(Info),
    scheduler_server_caps(Caps),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{protocolVersion:"2025-11-25",
                                   capabilities:Caps,
                                   serverInfo:Info}},
                   headers:transport_headers{},
                   content_type:'application/json'}.
scheduler_method("notifications/initialized", _, null).
scheduler_method("tools/list", Wire, Response) :-
    sleep(0.03),
    Response = mcp_transport_response{
                   status:200,
                   body:_{jsonrpc:"2.0",
                          id:Wire.id,
                          result:_{tools:[]}},
                   headers:transport_headers{},
                   content_type:'application/json'}.

connect_scheduler_client(Client) :-
    scheduler_client_info(Info),
    scheduler_client_caps(Caps),
    mcp_client_connect(fixture(streamable_http,
                               plunit_rlm_tool_mcp_scheduler:scheduler_fixture),
                       Info,
                       Caps,
                       [protocol('2025-11-25')],
                       ok(Client)).

test(tool_and_mcp_tasks_share_one_bounded_runtime) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        shared_scheduler_case(Registry),
        tool_registry_destroy(Registry)).

shared_scheduler_case(Registry) :-
    slow_tool_schema(Schema),
    tool_register(Registry,
                  Schema,
                  plunit_rlm_tool_mcp_scheduler:slow_tool,
                  ok(_)),
    connect_scheduler_client(Client),
    setup_call_cleanup(
        submit_mixed_tasks(Registry, Client, Futures),
        ( rlm_async_runtime_status(Status),
          assertion(Status.worker_count =:= 8),
          assertion(Status.backlog_limit =:= 64),
          rlm_future_all(Futures, Outcomes),
          length(Outcomes, 12),
          assertion(forall(member(Outcome, Outcomes),
                           valid_mixed_outcome(Outcome)))
        ),
        ( maplist(rlm_future_destroy, Futures),
          mcp_client_close(Client, ok(closed))
        )).

submit_mixed_tasks(Registry, Client, Futures) :-
    findall(Future,
            ( between(1, 6, Value),
              tool_invoke_async(Registry,
                                [tool(scheduler_echo)],
                                scheduler_echo,
                                _{value:Value},
                                [],
                                Future)
            ),
            ToolFutures),
    findall(Future,
            ( between(1, 6, _),
              mcp_client_command_async(Client,
                                       list_tools,
                                       [],
                                       Future)
            ),
            McpFutures),
    append(ToolFutures, McpFutures, Futures).

valid_mixed_outcome(Result) :-
    is_dict(Result, tool_async_result),
    !,
    Result.outcome = ok(_).
valid_mixed_outcome(Result) :-
    is_dict(Result, mcp_command_async_result),
    Result.outcome = ok(_).

:- end_tests(rlm_tool_mcp_scheduler).
