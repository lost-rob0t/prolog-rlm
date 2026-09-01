:- begin_tests(rlm_direct_deadline).

% Deadline-facing direct-mode contracts:
%
%   1. A provider request that dies from a wall-clock deadline surfaces as a
%      typed deadline error (phase=deadline), never as the generic
%      provider_failed classification.
%   2. A clean wall-clock alarm escaping the direct loop is a typed deadline
%      outcome (phase=deadline kind=run_deadline_exceeded).
%   3. A wall-clock synthesis reservation stops evidence acquisition before
%      the hard deadline and forces one final tool-free synthesis request.
%   4. The request deadline caps the provider HTTP timeout without loosening
%      an operator-configured shorter timeout.
%   5. A host-required minimum substantive final output is enforced.

:- use_module(library(lists)).
:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_completion').
:- use_module('../prolog/rlm_direct').

:- dynamic deadline_scenario/1.
:- dynamic deadline_call_count/1.
:- dynamic deadline_request/2.

reset_deadline(Scenario) :-
    retractall(deadline_scenario(_)),
    retractall(deadline_request(_, _)),
    retractall(deadline_call_count(_)),
    assertz(deadline_scenario(Scenario)),
    assertz(deadline_call_count(0)).

next_deadline_call(Call) :-
    retract(deadline_call_count(N0)),
    Call is N0+1,
    assertz(deadline_call_count(Call)).

record_deadline_request(Call, Request) :-
    assertz(deadline_request(Call, Request)).

scripted_deadline_model(Request, Outcome) :-
    next_deadline_call(Call),
    record_deadline_request(Call, Request),
    deadline_scenario(Scenario),
    deadline_scenario_response(Scenario, Call, Request, Outcome).

% Provider reports a wall-clock deadline through the transport boundary (the
% shape produced by a capped HTTP timeout or a cleanly caught request alarm).
deadline_scenario_response(provider_timeout, 1, _,
                           error(provider_error{
                                    provider:openai_compatible,
                                    kind:timeout,
                                    exception:"error(timeout_error(read, socket))",
                                    response_received:false})).

% Provider classification of an interrupted request deadline.
deadline_scenario_response(provider_deadline_exception, 1, _,
                           error(provider_error{
                                    provider:openai_compatible,
                                    kind:deadline_exceeded,
                                    exception:"time_limit_exceeded",
                                    response_received:false})).

% The clean wall-clock alarm leak: the exception escapes the provider call.
deadline_scenario_response(provider_alarm_leak, 1, _, _) :-
    throw(time_limit_exceeded).

% Non-deadline transport failures must keep the legacy provider_failed shape.
deadline_scenario_response(transport_failure, 1, _,
                           error(provider_error{
                                    provider:openai_compatible,
                                    kind:transport_error,
                                    exception:"error(syntax_error(json(unexpected_end_of_file)))",
                                    response_received:false})).

% The reservation must stop evidence acquisition inside the reserved window.
% The scenario dispatches on the request shape instead of the call number so
% setup jitter can only shift where the transition lands, not whether it
% happens: requests carrying tools model a slow evidence turn (sleep is
% provider latency, the resource under budget), tool-free requests are the
% synthesis turn and must carry the directive.
deadline_scenario_response(synthesis_reserved, Call, Request, ok(Response)) :-
    request_has_tools(Request),
    sleep(9.0),
    native_deadline_call("ctx_1", "context_search", _{query:"NEEDLE"}, ToolCall),
    fake_deadline_response(Call, "", [ToolCall], "", Response).

deadline_scenario_response(synthesis_reserved, Call, Request, ok(Response)) :-
    \+ request_has_tools(Request),
    last_message_content(Request, Content),
    assertion(sub_string(Content, _, _, _, "final synthesis")),
    fake_deadline_response(Call, "RESERVED_SYNTHESIS", [], "", Response).

deadline_scenario_response(synthesis_immediate, 1, Request, ok(Response)) :-
    assertion(synthesis_request_has_no_tools(Request)),
    last_message_content(Request, Content),
    assertion(sub_string(Content, _, _, _, "final synthesis")),
    fake_deadline_response(1, "RESERVED_SYNTHESIS", [], "", Response).

deadline_scenario_response(substantive_short, 1, _, ok(Response)) :-
    fake_deadline_response(1, "short", [], "", Response).

deadline_scenario_response(substantive_long, 1, _, ok(Response)) :-
    length(Codes, 128),
    maplist(=(0'a), Codes),
    string_codes(Text, Codes),
    fake_deadline_response(1, Text, [], "", Response).

% A response-count tool cutoff bounds evidence acquisition even on fast
% providers: after the cutoff, requests are sent without tool schemas and
% the run closes with final text. Deterministic by construction (no wall
% clock): the scenario dispatches on the request shape.
deadline_scenario_response(tool_cutoff, Call, Request, ok(Response)) :-
    request_has_tools(Request),
    !,
    native_deadline_call("ctx_1", "context_search", _{query:"NEEDLE"}, ToolCall),
    fake_deadline_response(Call, "", [ToolCall], "", Response).
deadline_scenario_response(tool_cutoff, Call, Request, ok(Response)) :-
    \+ request_has_tools(Request),
    !,
    last_message_content(Request, Content),
    assertion(sub_string(Content, _, _, _, "final synthesis")),
    fake_deadline_response(Call, "CUTOFF_CLOSED", [], "", Response).

request_has_tools(Request) :-
    get_dict(options, Request, RequestOptions),
    get_dict(tools, RequestOptions, _).

synthesis_request_has_no_tools(Request) :-
    \+ request_has_tools(Request).

last_message_content(Request, Content) :-
    get_dict(messages, Request, Messages),
    last(Messages, LastMessage),
    get_dict(content, LastMessage, Content).

native_deadline_call(Id, Name, Args, Call) :-
    atom_json_dict(ArgumentsAtom, Args, [width(0)]),
    atom_string(ArgumentsAtom, Arguments),
    Call = _{id:Id,
             type:"function",
             function:_{name:Name,arguments:Arguments}}.

fake_deadline_response(Call, Text, ToolCalls, Reasoning,
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
    format(string(ResponseId), "response_~d", [Call]),
    (ToolCalls == [] -> FinishReason = stop ; FinishReason = tool_calls).

deadline_provider_options(Extra,
                          [ provider(provider(openai_compatible, [])),
                            provider_name(openai_compatible),
                            model_handler(plunit_rlm_direct_deadline:scripted_deadline_model),
                            capabilities([context(search)]),
                            prompt_compile_mode(all_tools)
                          | Extra ]).

test(provider_timeout_cause_is_typed_not_provider_failed) :-
    reset_deadline(provider_timeout),
    deadline_provider_options([], Options),
    rlm_direct("Research the needle", text("NEEDLE context"), Options,
               error(Error)),
    assertion(Error.phase == deadline),
    assertion(Error.kind == provider_deadline_exceeded),
    assertion(is_dict(Error.usage)).

test(provider_deadline_exceeded_cause_is_typed) :-
    reset_deadline(provider_deadline_exception),
    deadline_provider_options([], Options),
    rlm_direct("Research the needle", text("NEEDLE context"), Options,
               error(Error)),
    assertion(Error.phase == deadline),
    assertion(Error.kind == provider_deadline_exceeded).

test(clean_wall_clock_alarm_is_typed_run_deadline) :-
    reset_deadline(provider_alarm_leak),
    deadline_provider_options([], Options),
    rlm_direct("Research the needle", text("NEEDLE context"), Options,
               error(Error)),
    assertion(Error.phase == deadline),
    assertion(Error.kind == run_deadline_exceeded).

test(transport_failure_keeps_provider_failed_shape) :-
    reset_deadline(transport_failure),
    deadline_provider_options([], Options),
    rlm_direct("Research the needle", text("NEEDLE context"), Options,
               error(Error)),
    assertion(Error.phase == provider),
    assertion(Error.kind == provider_failed).

% The transition itself is a pure wall-clock decision over the injected
% deadline: deterministic margins (seconds versus milliseconds) cover both
% directions without racing the async scheduler. The end-to-end closing
% behavior is covered by the immediate-synthesis and tool-cutoff tests.
test(synthesis_transition_engages_inside_reservation_window) :-
    get_time(Now),
    Runtime = direct_runtime{synthesis:false,
                             deadline:Now + 10.0,
                             reservation:20.0},
    rlm_direct:direct_synthesis_transition(Runtime, Engaged),
    assertion(Engaged.synthesis == true).

test(synthesis_transition_holds_outside_reservation_window) :-
    get_time(Now),
    Runtime = direct_runtime{synthesis:false,
                             deadline:Now + 100.0,
                             reservation:1.0},
    rlm_direct:direct_synthesis_transition(Runtime, Same),
    assertion(Same.synthesis == false).

test(native_tool_cutoff_strips_tools_after_cutoff) :-
    reset_deadline(tool_cutoff),
    % A large alarm budget keeps the default wall-clock synthesis reservation
    % out of the picture entirely: only the response-count cutoff can make
    % turns tool-free, on any runner speed.
    deadline_provider_options([native_tool_cutoff_model_calls(1),
                               budget(_{time_limit:3600.0})],
                              Options),
    rlm_direct("Research the needle", text("NEEDLE context"), Options,
               ok(Result)),
    assertion(Result.value == "CUTOFF_CLOSED"),
    findall(Request, deadline_request(_, Request), Requests),
    Requests = [First|_],
    assertion(request_has_tools(First)),
    last(Requests, LastRequest),
    assertion(\+ request_has_tools(LastRequest)).

test(native_tool_cutoff_rejects_invalid_option) :-
    reset_deadline(tool_cutoff),
    deadline_provider_options([native_tool_cutoff_model_calls(-1)], Options),
    rlm_direct("Research the needle", text("NEEDLE context"), Options,
               error(Error)),
    assertion(Error.kind == invalid_native_tool_cutoff).

test(expired_wall_clock_deadline_goes_straight_to_synthesis) :-
    reset_deadline(synthesis_immediate),
    get_time(Now),
    Deadline is Now - 1.0,
    deadline_provider_options([wall_clock_deadline(Deadline),
                               synthesis_reservation(0.0)],
                              Options),
    rlm_direct("Research the needle", text("NEEDLE context"), Options,
               ok(Result)),
    assertion(Result.value == "RESERVED_SYNTHESIS").

test(request_deadline_caps_looser_provider_timeout) :-
    request_deadline_provider(provider(openai_compatible,
                                       [endpoint(e),
                                        credential(none),
                                        model(m),
                                        timeout(600)]),
                              5.0,
                              provider(openai_compatible,
                                       [endpoint(e),
                                        credential(none),
                                        model(m),
                                        timeout(5.0)])).

test(request_deadline_keeps_tighter_provider_timeout) :-
    request_deadline_provider(provider(openai_compatible, [timeout(3)]),
                              5.0,
                              provider(openai_compatible, [timeout(3)])).

test(request_deadline_ignores_non_openai_compatible_provider) :-
    request_deadline_provider(provider(fake, []), 5.0, provider(fake, [])).

test(substantive_final_output_required_when_configured) :-
    reset_deadline(substantive_short),
    deadline_provider_options([min_final_output_bytes(64)], Options),
    rlm_direct("Research the needle", text("NEEDLE context"), Options,
               error(Error)),
    assertion(Error.kind == insufficient_final_output),
    assertion(Error.bytes >= 1),
    assertion(Error.required == 64).

test(substantive_final_output_allows_long_output) :-
    reset_deadline(substantive_long),
    deadline_provider_options([min_final_output_bytes(64)], Options),
    rlm_direct("Research the needle", text("NEEDLE context"), Options,
               ok(Result)),
    string_length(Result.value, Length),
    assertion(Length >= 64).

:- end_tests(rlm_direct_deadline).
