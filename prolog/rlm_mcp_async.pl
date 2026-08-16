:- module(rlm_mcp_async,
          [ mcp_client_connect_async/5,
            mcp_client_command_async/4,
            mcp_client_close_async/2,
            mcp_server_handle_async/6
          ]).

/** <module> Asynchronous facade for MCP lifecycle and commands

These predicates schedule the canonical version-neutral MCP operations through
rlm_async. Awaiting the future returns the same Outcome term produced by the
synchronous MCP facade.
*/

:- use_module(rlm_async).
:- use_module(rlm_mcp).

mcp_client_connect_async(TransportSpec, ClientInfo, ClientCaps, Options, Future) :-
    rlm_async_submit(mcp_connect_task(TransportSpec,
                                      ClientInfo,
                                      ClientCaps,
                                      Options),
                     Future).

mcp_connect_task(TransportSpec, ClientInfo, ClientCaps, Options, Outcome) :-
    rlm_mcp:mcp_client_connect(TransportSpec,
                               ClientInfo,
                               ClientCaps,
                               Options,
                               Outcome).

mcp_client_command_async(Client, Command, Options, Future) :-
    rlm_async_submit(mcp_command_task(Client, Command, Options), Future).

mcp_command_task(Client, Command, Options, Outcome) :-
    rlm_mcp:mcp_client_command(Client, Command, Options, Outcome).

mcp_client_close_async(Client, Future) :-
    rlm_async_submit(mcp_close_task(Client), Future).

mcp_close_task(Client, Outcome) :-
    rlm_mcp:mcp_client_close(Client, Outcome).

mcp_server_handle_async(Server, Session, Command, Options, Context, Future) :-
    rlm_async_submit(mcp_server_handle_task(Server,
                                            Session,
                                            Command,
                                            Options,
                                            Context),
                     Future).

mcp_server_handle_task(Server, Session, Command, Options, Context, Outcome) :-
    rlm_mcp:mcp_server_handle(Server,
                              Session,
                              Command,
                              Options,
                              Context,
                              Outcome).
