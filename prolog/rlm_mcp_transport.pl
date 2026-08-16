:- module(rlm_mcp_transport,
          [ mcp_transport_open/3,
            mcp_transport_exchange/4,
            mcp_transport_close/2,
            mcp_transport_stop/2,
            mcp_transport_kind/2
          ]).

/** <module> MCP transport boundary

Transport code moves JSON-RPC envelopes but does not interpret MCP methods,
versions, capabilities, or sessions. Version adapters provide request headers
and consume response metadata.

An existing(Transport) spec creates a borrowed transport view. Borrowed clients
can connect and close without taking ownership of a server process/endpoint;
the lifecycle owner remains responsible for mcp_transport_stop/2.
*/

:- use_module(library(http/http_open)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_ssl_plugin)).
:- use_module(library(http/json)).
:- use_module(library(process)).
:- use_module(library(readutil)).
:- use_module(library(option)).

mcp_transport_open(Spec, Options, Outcome) :-
    catch(open_transport(Spec, Options, Transport),
          Exception,
          transport_exception(open, Exception, Outcome)),
    (   var(Outcome)
    ->  Outcome = ok(Transport)
    ;   true
    ).

open_transport(existing(Transport), _,
               mcp_transport{kind:Kind,
                             backend:borrowed(Transport)}) :-
    !,
    mcp_transport_kind(Transport, Kind).
open_transport(fixture(Kind, Handler), _,
               mcp_transport{kind:Kind,
                             backend:fixture(Handler)}) :-
    !,
    memberchk(Kind, [stdio,streamable_http]),
    callable(Handler).
open_transport(stdio(Executable, Args), _,
               mcp_transport{kind:stdio,
                             backend:stdio(Pid, In, Out, Err)}) :-
    !,
    atom(Executable),
    is_list(Args),
    process_create(path(Executable),
                   Args,
                   [ stdin(pipe(In, [encoding(utf8)])),
                     stdout(pipe(Out, [encoding(utf8)])),
                     stderr(pipe(Err, [encoding(utf8)])),
                     process(Pid)
                   ]).
open_transport(streamable_http(Endpoint0), Options,
               mcp_transport{kind:streamable_http,
                             backend:http(Endpoint, Timeout)}) :-
    !,
    text_atom(Endpoint0, Endpoint),
    option(timeout(Timeout), Options, 30),
    number(Timeout),
    Timeout > 0.
open_transport(Spec, _, _) :-
    throw(mcp_transport_fault(invalid_transport_spec(Spec))).

mcp_transport_kind(Transport, Kind) :-
    is_dict(Transport, mcp_transport),
    get_dict(kind, Transport, Kind).

mcp_transport_exchange(Transport, Wire, RequestMeta, Outcome) :-
    catch(exchange_transport(Transport, Wire, RequestMeta, Response),
          Exception,
          transport_exception(exchange, Exception, Outcome)),
    (   var(Outcome)
    ->  Outcome = ok(Response)
    ;   true
    ).

exchange_transport(Transport, Wire, RequestMeta, Response) :-
    is_dict(Transport, mcp_transport),
    get_dict(backend, Transport, Backend),
    exchange_backend(Backend, Wire, RequestMeta, Response).

exchange_backend(borrowed(Transport), Wire, RequestMeta, Response) :-
    !,
    exchange_transport(Transport, Wire, RequestMeta, Response).
exchange_backend(fixture(Handler), Wire, RequestMeta, Response) :-
    !,
    (   call(Handler, Wire, RequestMeta, Raw)
    ->  normalize_fixture_response(Raw, Response)
    ;   throw(mcp_transport_fault(fixture_handler_failed))
    ).
exchange_backend(stdio(_, In, Out, _), Wire, _, Response) :-
    !,
    json_write_dict(In, Wire, [width(0)]),
    nl(In),
    flush_output(In),
    read_line_to_string(Out, Line),
    (   Line == end_of_file
    ->  throw(mcp_transport_fault(stdio_end_of_file))
    ;   atom_string(Atom, Line),
        atom_json_dict(Atom, Body, []),
        Response = mcp_transport_response{status:200,
                                          body:Body,
                                          headers:transport_headers{},
                                          content_type:'application/json'}
    ).
exchange_backend(http(Endpoint, Timeout), Wire, RequestMeta, Response) :-
    request_headers(RequestMeta, RequestHeaders),
    maplist(request_header_option, RequestHeaders, HeaderOptions),
    append([ post(json(Wire)),
             timeout(Timeout),
             status_code(Status),
             headers(ResponseHeaders),
             header(content_type, ContentType0),
             user_agent('prolog-rlm/0.1')
           ],
           HeaderOptions,
           HttpOptions),
    setup_call_cleanup(
        http_open(Endpoint, In, HttpOptions),
        read_http_response(In, ContentType0, Body),
        close(In)),
    response_headers_dict(ResponseHeaders, Headers),
    normalize_content_type(ContentType0, ContentType),
    Response = mcp_transport_response{status:Status,
                                      body:Body,
                                      headers:Headers,
                                      content_type:ContentType}.

normalize_fixture_response(Response, Response) :-
    is_dict(Response, mcp_transport_response),
    !.
normalize_fixture_response(Body,
                           mcp_transport_response{status:200,
                                                  body:Body,
                                                  headers:transport_headers{},
                                                  content_type:'application/json'}) :-
    is_dict(Body),
    !.
normalize_fixture_response(Response, _) :-
    throw(mcp_transport_fault(invalid_fixture_response(Response))).

request_headers(RequestMeta, Headers) :-
    (   is_dict(RequestMeta),
        get_dict(headers, RequestMeta, Candidate),
        is_list(Candidate)
    ->  Headers = Candidate
    ;   Headers = []
    ).

request_header_option(Name=Value, request_header(Name=Value)) :-
    atom(Name),
    atomic(Value),
    !.
request_header_option(Header, _) :-
    throw(mcp_transport_fault(invalid_request_header(Header))).

read_http_response(In, ContentType0, Body) :-
    read_string(In, _, Text),
    normalize_content_type(ContentType0, ContentType),
    (   sub_atom(ContentType, 0, _, _, 'text/event-stream')
    ->  parse_sse_response(Text, Body)
    ;   parse_json_response(Text, Body)
    ).

parse_json_response("", null) :- !.
parse_json_response(Text, Body) :-
    atom_string(Atom, Text),
    atom_json_dict(Atom, Body, []).

parse_sse_response(Text, Body) :-
    split_string(Text, "\n", "\r", Lines),
    member(Line, Lines),
    sub_string(Line, 0, 5, _, "data:"),
    sub_string(Line, 5, _, 0, Data0),
    normalize_sse_data(Data0, Data),
    Data \== "",
    Data \== "[DONE]",
    atom_string(Atom, Data),
    catch(atom_json_dict(Atom, Candidate, []), _, fail),
    is_dict(Candidate),
    !,
    Body = Candidate.
parse_sse_response(_, _) :-
    throw(mcp_transport_fault(sse_without_json_response)).

normalize_sse_data(Data0, Data) :-
    (   sub_string(Data0, 0, 1, _, " ")
    ->  sub_string(Data0, 1, _, 0, Data)
    ;   Data = Data0
    ).

response_headers_dict(Headers0, Headers) :-
    findall(Key-Value,
            ( member(Header, Headers0),
              Header =.. [Name, Value0],
              Name \== status_code,
              normalize_header_name(Name, Key),
              header_text(Value0, Value)
            ),
            Pairs0),
    sort(Pairs0, Pairs),
    dict_pairs(Headers, transport_headers, Pairs).

normalize_header_name(Name, Key) :-
    atom(Name),
    atomic_list_concat(Parts, '_', Name),
    atomic_list_concat(Parts, '-', HeaderName),
    downcase_atom(HeaderName, Key).

header_text(Value, Value) :- string(Value), !.
header_text(Value, Text) :- atom(Value), !, atom_string(Value, Text).
header_text(Value, Text) :- term_string(Value, Text).

normalize_content_type('', 'application/json') :- !.
normalize_content_type(Value, Value) :- atom(Value), !.
normalize_content_type(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
normalize_content_type(_, 'application/json').

mcp_transport_close(Transport, Outcome) :-
    catch(close_transport(Transport),
          Exception,
          transport_exception(close, Exception, Outcome)),
    (   var(Outcome)
    ->  Outcome = ok(closed)
    ;   true
    ).

close_transport(Transport) :-
    is_dict(Transport, mcp_transport),
    get_dict(backend, Transport, Backend),
    close_backend(Backend).

close_backend(borrowed(_)) :- !.
close_backend(fixture(_)) :- !.
close_backend(http(_, _)) :- !.
close_backend(stdio(Pid, In, Out, Err)) :-
    !,
    close_quietly(In),
    close_quietly(Out),
    close_quietly(Err),
    process_wait(Pid, _).

mcp_transport_stop(Transport, Outcome) :-
    catch(stop_transport(Transport),
          Exception,
          transport_exception(stop, Exception, Outcome)),
    (   var(Outcome)
    ->  Outcome = ok(stopped)
    ;   true
    ).

stop_transport(Transport) :-
    is_dict(Transport, mcp_transport),
    get_dict(backend, Transport, Backend),
    stop_backend(Backend).

stop_backend(borrowed(_)) :- !.
stop_backend(fixture(_)) :- !.
stop_backend(http(_, _)) :- !.
stop_backend(stdio(Pid, In, Out, Err)) :-
    !,
    catch(process_kill(Pid, term), _, true),
    close_quietly(In),
    close_quietly(Out),
    close_quietly(Err),
    catch(process_wait(Pid, _), _, true).

close_quietly(Stream) :- catch(close(Stream), _, true).

text_atom(Value, Value) :- atom(Value), !.
text_atom(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
text_atom(Value, _) :- throw(mcp_transport_fault(expected_text(Value))).

transport_exception(_, Exception, _) :-
    transport_control_exception(Exception),
    !,
    throw(Exception).
transport_exception(_, mcp_transport_fault(Detail), error(Error)) :-
    !,
    Error = mcp_transport_error{kind:transport_error,
                                detail:Detail,
                                message:"MCP transport operation failed"}.
transport_exception(Operation, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = mcp_transport_error{kind:transport_exception,
                                operation:Operation,
                                exception:Safe,
                                message:"MCP transport raised an exception"}.

transport_control_exception(rlm_async_cancelled(_)).
transport_control_exception(rlm_cancelled(_)).
transport_control_exception(chain_cancelled(_)).
transport_control_exception(graph_cancelled(_)).
transport_control_exception(cancelled(_)).
transport_control_exception('$aborted').
transport_control_exception(abort).
