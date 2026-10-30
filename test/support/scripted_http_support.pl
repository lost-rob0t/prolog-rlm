:- module(scripted_http_support, [with_scripted_http/3]).

/** <module> Bounded, synthetic production-transport fixture

Only the remote responses are scripted. The caller uses its ordinary provider
configuration, schema projection, scheduler and tool execution path. Failed
request expectations are recorded in the server thread and rethrown in the
test thread, so an HTTP 500 cannot hide a failed wire assertion.
*/

:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_json)).
:- use_module(library(socket)).
:- use_module(library(time)).

:- meta_predicate with_scripted_http(+, 1, -).
:- dynamic fixture/3, captured/4, fixture_fault/2.

with_scripted_http(Script, Goal, Requests) :-
    length(Script, Count),
    between(1, 16, Count),
    setup_call_cleanup(
        start_fixture(Script, Port, Provider),
        ( catch((call_with_time_limit(10, call(Goal, Provider)) -> true;
                 throw(fixture_goal_failed)), Error, true),
          ( fixture_fault(Port, Fault) -> throw(Fault); true ),
          ( nonvar(Error) -> throw(Error); true ),
          fixture_complete(Port, Count, Requests)
        ),
        stop_fixture(Port)).

start_fixture(Script, Port, Provider) :-
    http_server(scripted_http_support:dispatch(Port),
                [port('127.0.0.1':Port), workers(1),
                 timeout(2), keep_alive_timeout(0)]),
    assertz(fixture(Port, 0, Script)),
    format(atom(Endpoint), 'http://127.0.0.1:~d/v1/chat/completions', [Port]),
    Provider = provider(openai_compatible,
                        [endpoint(Endpoint), credential(none),
                         model('fixture/model'), timeout(2)]).

stop_fixture(Port) :-
    http_stop_server(Port, []),
    retractall(fixture(Port, _, _)),
    retractall(captured(Port, _, _, _)),
    retractall(fixture_fault(Port, _)),
    ( http_current_server(_, Port) -> throw(fixture_server_leaked(Port)); true ),
    % Rebinding the same loopback port independently proves listener cleanup.
    setup_call_cleanup(tcp_socket(Socket),
                       ( tcp_setopt(Socket, reuseaddr),
                         tcp_bind(Socket, '127.0.0.1':Port) ),
                       tcp_close_socket(Socket)).

dispatch(Port, Request) :-
    catch((dispatch_(Port, Request) -> true; throw(unexpected_request)), Error,
          ( assertz(fixture_fault(Port, Error)),
            reply_json_dict(_{error:_{message:"script expectation failed"}},
                            [status(500)]) )).

dispatch_(Port, Request) :-
    memberchk(method(post), Request),
    memberchk(path(Path), Request),
    ( Path == '/v1/chat/completions' -> true; throw(unexpected_path(Path)) ),
    memberchk(content_length(Bytes), Request),
    ( Bytes =< 65536 -> true; throw(request_too_large(Bytes)) ),
    http_read_json_dict(Request, Body),
    retract(fixture(Port, Previous, [Step|Rest])),
    Index is Previous+1,
    assertz(fixture(Port, Index, Rest)),
    assertz(captured(Port, Index, Path, Body)),
    reply_step(Step, Check, Response, Options),
    ( call(Check, Body) -> true; throw(request_mismatch(Index, Body)) ),
    reply_json_dict(Response, Options).

reply_step(reply(Check, Response), Check, Response, []).
reply_step(http_error(Status), scripted_http_support:any_request,
           _{error:_{message:"synthetic unavailable"}},
           [status(Status), 'Retry-After'('1')]).

any_request(_).

fixture_complete(Port, Count, Requests) :-
    ( fixture_fault(Port, Error) -> throw(Error); true ),
    ( fixture(Port, Count, []) -> true; throw(incomplete_script(Port)) ),
    findall(request{index:Index,path:Path,body:Body},
            captured(Port, Index, Path, Body), Requests).
