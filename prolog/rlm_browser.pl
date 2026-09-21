:- module(rlm_browser,
          [ browser_bridge_call/3,
            browser_bridge_endpoint/1
          ]).

/** <module> Zara browser bridge client

This module is the deterministic Prolog side of Zara browser control.  It does
not automate a browser directly and it never receives browser cookies or
credentials.  Calls are sent to the authenticated Zara loopback bridge, which
forwards only a closed action vocabulary to the installed browser add-on.

The bridge token is resolved at execution time from
`ZARA_BROWSER_BRIDGE_TOKEN`.  The endpoint defaults to the loopback-only Zara
service and may be overridden with `PROLOG_RLM_BROWSER_BRIDGE_URL`.

Browser mutation is not authorized here.  Model-facing callers should use the
`rlm_browser_tool_pack`, whose mutating schemas are `network_write` effects
and therefore cross the ordinary Prolog-RLM capability and authority gates.
*/

:- use_module(library(http/http_client)).
:- use_module(library(http/http_json)).
:- use_module(library(http/json)).

browser_bridge_endpoint(Endpoint) :-
    (   getenv('PROLOG_RLM_BROWSER_BRIDGE_URL', Candidate),
        Candidate \== ''
    ->  Endpoint = Candidate
    ;   Endpoint = 'http://127.0.0.1:8765/v1/rpc'
    ).

browser_bridge_call(Action0, Args, Outcome) :-
    catch(browser_bridge_call_(Action0, Args, Outcome),
          Exception,
          browser_exception(Exception, Outcome)).

browser_bridge_call_(Action0, Args, Outcome) :-
    browser_action(Action0, Action),
    require_args(Args),
    browser_bridge_endpoint(Endpoint),
    require_http_endpoint(Endpoint),
    browser_bridge_token(Token),
    atom_string(Action, ActionText),
    Payload = _{action:ActionText, args:Args},
    catch(http_post(Endpoint,
                    json(Payload),
                    Reply,
                    [ authorization(bearer(Token)),
                      timeout(20),
                      status_code(Status),
                      json_object(dict),
                      request_header('Accept'='application/json'),
                      user_agent('prolog-rlm-browser/0.1')
                    ]),
          Exception,
          true),
    (   var(Exception)
    ->  normalize_bridge_reply(Status, Reply, Outcome)
    ;   throw(Exception)
    ).

browser_action(tabs_list, 'tabs.list').
browser_action(page_read, 'page.read').
browser_action(page_elements, 'page.elements').
browser_action(page_extract, 'page.extract').
browser_action(page_screenshot, 'page.screenshot').
browser_action(tabs_open, 'tabs.open').
browser_action(tabs_navigate, 'tabs.navigate').
browser_action(page_click, 'page.click').
browser_action(page_type, 'page.type').
browser_action(page_submit, 'page.submit').

require_args(Args) :-
    is_dict(Args),
    ground(Args),
    !.
require_args(Args) :-
    throw(error(type_error(ground_dict, Args), _)).

browser_bridge_token(Token) :-
    getenv('ZARA_BROWSER_BRIDGE_TOKEN', Token),
    Token \== '',
    !.
browser_bridge_token(_) :-
    throw(error(existence_error(environment_variable,
                                'ZARA_BROWSER_BRIDGE_TOKEN'), _)).

require_http_endpoint(Endpoint) :-
    atom(Endpoint),
    (   sub_atom(Endpoint, 0, _, _, 'http://')
    ;   sub_atom(Endpoint, 0, _, _, 'https://')
    ),
    !.
require_http_endpoint(Endpoint) :-
    throw(error(domain_error(http_endpoint, Endpoint), _)).

normalize_bridge_reply(Status, Reply, Outcome) :-
    integer(Status),
    Status >= 200,
    Status < 300,
    is_dict(Reply),
    get_dict(ok, Reply, true),
    get_dict(result, Reply, Result),
    !,
    Outcome = ok(Result).
normalize_bridge_reply(Status, Reply, error(Error)) :-
    bridge_error_detail(Reply, Detail),
    Error = browser_error{
                kind:bridge_error,
                http_status:Status,
                detail:Detail,
                message:"Zara browser bridge rejected the request"
            }.

bridge_error_detail(Reply, Detail) :-
    is_dict(Reply),
    get_dict(error, Reply, Candidate),
    !,
    safe_detail(Candidate, Detail).
bridge_error_detail(_, "invalid bridge response").

safe_detail(Value, Value) :-
    string(Value),
    !.
safe_detail(Value, Text) :-
    atom(Value),
    !,
    atom_string(Value, Text).
safe_detail(_, "browser bridge error").

browser_exception(Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = browser_error{
                kind:transport_error,
                exception:Safe,
                message:"browser bridge request failed"
            }.

safe_exception(Exception, Safe) :-
    term_string(Exception, Text, [quoted(true), numbervars(true)]),
    string_length(Text, Length),
    (   Length =< 512
    ->  Safe = Text
    ;   sub_string(Text, 0, 512, _, Safe)
    ).
