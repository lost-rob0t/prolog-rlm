:- module(rlm_mcp_async,
          [ mcp_client_connect_async/5,
            mcp_client_command_async/4,
            mcp_client_close_async/2,
            mcp_server_handle_async/6
          ]).

/** <module> Compatibility facade for canonical asynchronous MCP APIs

The canonical async/task implementation lives in rlm_mcp. This module is kept
for source compatibility with callers that import the historical async facade.
It delegates only to asynchronous predicates and never enters synchronous public
wrappers.

Stateful operations resolve to structured results:

  * mcp_client_command_async/4 ->
    mcp_command_async_result{client:Client, outcome:Outcome}
  * mcp_server_handle_async/6 ->
    mcp_server_async_result{server:Server, outcome:Outcome}

The third argument of mcp_client_command_async/4 and fifth argument of
mcp_server_handle_async/6 are host metadata/options lists. Historical output
variables in those positions could never be returned across a worker boundary.
*/

:- use_module(rlm_mcp, []).

mcp_client_connect_async(TransportSpec, ClientInfo, ClientCaps, Options, Future) :-
    rlm_mcp:mcp_client_connect_async(TransportSpec,
                                      ClientInfo,
                                      ClientCaps,
                                      Options,
                                      Future).

mcp_client_command_async(Client, Command, Options, Future) :-
    rlm_mcp:mcp_client_command_async(Client, Command, Options, Future).

mcp_client_close_async(Client, Future) :-
    rlm_mcp:mcp_client_close_async(Client, Future).

mcp_server_handle_async(Server, Wire, RequestMeta, Dispatch, Options, Future) :-
    rlm_mcp:mcp_server_handle_async(Server,
                                     Wire,
                                     RequestMeta,
                                     Dispatch,
                                     Options,
                                     Future).
