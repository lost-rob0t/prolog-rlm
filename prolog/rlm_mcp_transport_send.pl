:- module(rlm_mcp_transport_send,
          [ mcp_transport_send/4
          ]).

/** <module> Send-only MCP transport operation

Notifications must not wait for a stdio response.  HTTP notifications may use
the ordinary request path and ignore the response body.
*/

:- use_module(library(http/json)).
:- use_module(rlm_mcp_transport,
              [ mcp_transport_exchange/4
              ]).

mcp_transport_send(Transport, Wire, Meta, Outcome) :-
    catch(( send_transport(Transport, Wire, Meta), Result = ok(sent) ),
          Exception,
          send_exception(Exception, Result)),
    Outcome = Result.

send_transport(Transport, Wire, Meta) :-
    is_dict(Transport, mcp_transport),
    get_dict(backend, Transport, Backend),
    send_backend(Backend, Transport, Wire, Meta).

send_backend(fixture(Handler), _, Wire, Meta) :-
    !,
    (   call(Handler, Wire, Meta, _)
    ->  true
    ;   throw(mcp_send_fault(fixture_handler_failed))
    ).
send_backend(stdio(_, Input, _, _), _, Wire, _) :-
    !,
    json_write_dict(Input, Wire, [width(0)]),
    nl(Input),
    flush_output(Input).
send_backend(http(_, _), Transport, Wire, Meta) :-
    !,
    mcp_transport_exchange(Transport, Wire, Meta, Outcome),
    (   Outcome = ok(_)
    ->  true
    ;   Outcome = error(Error),
        throw(mcp_send_fault(http_notification(Error)))
    ).
send_backend(Backend, _, _, _) :-
    throw(mcp_send_fault(unsupported_backend(Backend))).

send_exception(mcp_send_fault(Detail), error(Error)) :-
    !,
    Error = mcp_transport_error{kind:transport_error,
                                detail:Detail,
                                message:"MCP notification send failed"}.
send_exception(Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = mcp_transport_error{kind:transport_exception,
                                exception:Safe,
                                message:"MCP notification send raised an exception"}.
