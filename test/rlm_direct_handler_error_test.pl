:- begin_tests(rlm_direct_handler_error).

% Live Auto-Dig dogfood failure (run 33473498248, pinned Prolog-RLM
% a89711d): a registered remote-MCP tool answered a tool call with a
% JSON-RPC protocol error (-32603 invalid_format at path ["proxy"]).
% The MCP adapter raised the typed adapter exception, the direct loop
% classified it as a handler_exception and fatally aborted the whole
% run, so the model never got the chance to repair its arguments even
% though it demonstrably repaired comparable error observations earlier
% in the same run.
%
% Contract under test:
%   * a registered-tool failure during invoke is per-call tool data:
%     the observation for exactly that call carries the stable error
%     kind, the execution phase, the canonical tool name, the provider
%     call id, and the bounded typed cause;
%   * valid sibling calls in the same batch still execute;
%   * the repair loop stays bounded by the existing batch budgets;
%   * authority invariants (approval, replay) are untouched and remain
%     fatal (covered by the direct/effect suites).

:- use_module(library(http/json)).
:- use_module('../prolog/rlm_authority').
:- use_module('../prolog/rlm_completion').
:- use_module('../prolog/rlm_direct').
:- use_module('../prolog/rlm_tool').

:- dynamic handler_scenario/1.
:- dynamic handler_call_count/1.
:- dynamic handler_request/2.

handler_reset(Scenario) :-
    retractall(handler_scenario(_)),
    retractall(handler_call_count(_)),
    retractall(handler_request(_, _)),
    assertz(handler_scenario(Scenario)),
    assertz(handler_call_count(0)).

handler_next_call(Call) :-
    retract(handler_call_count(N0)),
    Call is N0+1,
    assertz(handler_call_count(Call)).

handler_scripted_model(Request, ok(Response)) :-
    handler_next_call(Call),
    handler_scenario(Scenario),
    handler_response(Scenario, Call, Request, Text, ToolCalls, Reasoning),
    assertz(handler_request(Call, Request)),
    fake_handler_response(Call, Text, ToolCalls, Reasoning, Response).

handler_provider_options(Capabilities, Extra,
                         [ provider(provider(openai_compatible, [])),
                           provider_name(openai_compatible),
                           model_handler(plunit_rlm_direct_handler_error:handler_scripted_model),
                           capabilities(Capabilities),
                           prompt_compile_mode(all_tools)
                         | Extra
                         ]).

fake_handler_response(Call, Text, ToolCalls, Reasoning,
                      model_response{
                          provider:fake,
                          requested_model:fake,
                          selected_model:fake,
                          response_id:ResponseId,
                          assistant:message{role:assistant,
                                            content:Text,
                                            tool_calls:ToolCalls,
                                            reasoning:Reasoning,
                                            reasoning_details:[]},
                          text:Text,
                          tool_calls:ToolCalls,
                          reasoning:Reasoning,
                          reasoning_details:[],
                          finish_reason:FinishReason,
                          usage:usage{present:true,
                                      prompt_tokens:2,
                                      completion_tokens:1,
                                      total_tokens:3,
                                      cost:0.0},
                          metadata:provider_metadata{provider:fake,
                                                     http_status:200,
                                                     response_received:true}
                      }) :-
    format(string(ResponseId), "handler_response_~d", [Call]),
    (ToolCalls == [] -> FinishReason = stop ; FinishReason = tool_calls).

handler_raw_call(Id, Name, Arguments, Call) :-
    Call = _{id:Id,
             type:"function",
             function:_{name:Name,arguments:Arguments}}.

handler_call(Id, Name, Args, Call) :-
    atom_json_dict(ArgumentsAtom, Args, [width(0)]),
    atom_string(ArgumentsAtom, Arguments),
    handler_raw_call(Id, Name, Arguments, Call).

% The exact causal exception observed in the live artifact: the remote
% MCP server answered the tools/call with a JSON-RPC error and the MCP
% adapter raised its typed imported-tool fault.
mcp_remote_protocol_error(Exception) :-
    ValidationJson = "[\n  {\n    \"code\": \"invalid_format\",\n    \"format\": \"url\",\n    \"path\": [\n      \"proxy\"\n    ],\n    \"message\": \"Invalid URL\"\n  }\n]",
    Code = -32603,
    Exception = error(rlm_mcp_imported_tool(
                          error(mcp_error{
                                    detail:remote_error(
                                        mcp_remote_error{code:Code,
                                                         data:none,
                                                         message:ValidationJson}),
                                    kind:protocol_error,
                                    message:"MCP 2025-11-25 protocol operation failed",
                                    phase:adapter_2025_11_25,
                                    protocol_version:'2025-11-25'})),
                      _).

remote_fetch_handler(_, _) :-
    mcp_remote_protocol_error(Exception),
    throw(Exception).

plain_boom_handler(_, _) :-
    throw(handler_boom("disk-on-fire")).

web_search_handler(_, "web-value").

remote_fetch_schema(
    tool_schema{name:remote_fetch,
                description:"Remote MCP fetch probe that always fails at the server",
                capability:tool(remote_fetch),
                effect:read,
                arguments:_{type:object,
                            properties:_{url:_{type:string}},
                            required:[url],
                            additional_properties:false},
                result:_{type:string},
                limits:_{time_limit:2.0,max_output_bytes:1024}}).

plain_boom_schema(
    tool_schema{name:plain_boom,
                description:"Read probe whose handler throws a plain term",
                capability:tool(plain_boom),
                effect:read,
                arguments:_{type:object,
                            properties:_{},
                            required:[],
                            additional_properties:false},
                result:_{type:string},
                limits:_{time_limit:2.0,max_output_bytes:1024}}).

web_search_schema(
    tool_schema{name:web_search,
                description:"Healthy sibling search probe",
                capability:tool(web_search),
                effect:read,
                arguments:_{type:object,
                            properties:_{query:_{type:string}},
                            required:[query],
                            additional_properties:false},
                result:_{type:string},
                limits:_{time_limit:2.0,max_output_bytes:1024}}).

register_handler_tools(Registry, Tools) :-
    (   member(remote_fetch, Tools)
    ->  remote_fetch_schema(Schema1),
        tool_register(Registry, Schema1,
                      plunit_rlm_direct_handler_error:remote_fetch_handler,
                      ok(_))
    ;   true ),
    (   member(plain_boom, Tools)
    ->  plain_boom_schema(Schema2),
        tool_register(Registry, Schema2,
                      plunit_rlm_direct_handler_error:plain_boom_handler,
                      ok(_))
    ;   true ),
    (   member(web_search, Tools)
    ->  web_search_schema(Schema3),
        tool_register(Registry, Schema3,
                      plunit_rlm_direct_handler_error:web_search_handler,
                      ok(_))
    ;   true ).

handler_tool_ids(Call, Ids) :-
    handler_request(Call, Request),
    findall(Id,
            ( member(Message, Request.messages),
              Message.role == tool,
              Id = Message.tool_call_id ),
            Ids).

handler_tool_content_for(Call, Id, Content) :-
    handler_request(Call, Request),
    member(Message, Request.messages),
    Message.role == tool,
    Message.tool_call_id == Id,
    !,
    Content = Message.content.

trajectory_status_for(Result, CallId, Status) :-
    once(( member(Event, Result.trajectory),
           get_dict(call_id, Event, CallId),
           get_dict(status, Event, Status) )).

% --- The live Auto-Dig failure shape ----------------------------------------

test(remote_protocol_error_is_observed_and_loop_continues) :-
    handler_reset(remote_protocol_error),
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_handler_tools(Registry, [remote_fetch, web_search]),
        ( handler_provider_options([tool(remote_fetch), tool(web_search)],
                                   [tool_registry(Registry)],
                                   Options),
          rlm_direct("Handler error", text("opaque"), Options, ok(Result))
        ),
        tool_registry_destroy(Registry)),
    assertion(Result.value == "DIG_RECOVERED"),
    assertion(Result.turns =:= 2),
    assertion(Result.tool_calls =:= 2),
    handler_tool_ids(2, ["fetch_1", "web_1"]),
    handler_tool_content_for(2, "fetch_1", FetchContent),
    assertion(sub_string(FetchContent, _, _, _, "\"error\":\"handler_exception\"")),
    assertion(sub_string(FetchContent, _, _, _, "\"phase\":\"invoke\"")),
    assertion(sub_string(FetchContent, _, _, _, "tool handler raised an exception")),
    assertion(sub_string(FetchContent, _, _, _, "\"name\":\"remote_fetch\"")),
    assertion(sub_string(FetchContent, _, _, _, "\"call_id\":\"fetch_1\"")),
    assertion(sub_string(FetchContent, _, _, _, "invalid_format")),
    assertion(sub_string(FetchContent, _, _, _, "proxy")),
    handler_tool_content_for(2, "web_1", WebContent),
    assertion(sub_string(WebContent, _, _, _, "\"name\":\"web_search\"")),
    assertion(sub_string(WebContent, _, _, _, "\"id\":\"result_web_1\"")),
    trajectory_status_for(Result, "fetch_1", error),
    once(( member(WebEvent, Result.trajectory),
           get_dict(call_id, WebEvent, "web_1"),
           get_dict(result, WebEvent, WebResult) )),
    WebResult.trace.status == ok.

test(plain_handler_exception_preserves_typed_cause) :-
    handler_reset(plain_handler_exception),
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_handler_tools(Registry, [plain_boom]),
        ( handler_provider_options([tool(plain_boom)],
                                   [tool_registry(Registry)],
                                   Options),
          rlm_direct("Plain handler boom", text("opaque"), Options, ok(Result))
        ),
        tool_registry_destroy(Registry)),
    assertion(Result.value == "BOOM_RECOVERED"),
    assertion(Result.turns =:= 2),
    handler_tool_content_for(2, "boom_1", BoomContent),
    assertion(sub_string(BoomContent, _, _, _, "\"error\":\"handler_exception\"")),
    assertion(sub_string(BoomContent, _, _, _, "\"name\":\"plain_boom\"")),
    assertion(sub_string(BoomContent, _, _, _, "handler_boom")),
    assertion(sub_string(BoomContent, _, _, _, "disk-on-fire")).

% --- The repair loop must remain budget-bounded -----------------------------

handler_response(remote_protocol_error, 1, _, "", [Fetch, Search], "") :-
    handler_call("fetch_1", "remote_fetch",
                 _{url:"https://www.example.com/article"}, Fetch),
    handler_call("web_1", "web_search", _{query:"needle"}, Search).
handler_response(remote_protocol_error, 2, _, "DIG_RECOVERED", [], "").

handler_response(plain_handler_exception, 1, _, "", [Boom], "") :-
    handler_call("boom_1", "plain_boom", _{}, Boom).
handler_response(plain_handler_exception, 2, _, "BOOM_RECOVERED", [], "").

handler_response(budget_loop, Call, _, "", [Bad], "") :-
    Call =< 4,
    format(string(BadId), "fetch_~d", [Call]),
    handler_call(BadId, "remote_fetch", _{url:"https://example.invalid"}, Bad).

test(failing_tool_calls_still_consume_the_tool_budget) :-
    handler_reset(budget_loop),
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_handler_tools(Registry, [remote_fetch]),
        ( handler_provider_options([tool(remote_fetch)],
                                   [tool_registry(Registry),
                                    budget(_{max_tool_calls:2})],
                                   Options),
          rlm_direct("Handler budget", text("opaque"), Options, error(Error))
        ),
        tool_registry_destroy(Registry)),
    assertion(Error.kind == tool_call_budget_exhausted).

:- end_tests(rlm_direct_handler_error).
