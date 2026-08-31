:- begin_tests(rlm_direct).

:- use_module(library(http/json)).
:- use_module(library(filesex)).
:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_authority').
:- use_module('../prolog/rlm_completion').
:- use_module('../prolog/rlm_direct').
:- use_module('../prolog/rlm_effect').
:- use_module('../prolog/rlm_skill').
:- use_module('../prolog/rlm_tool').
:- use_module('support/tool_effect_test_support').

:- dynamic direct_scenario/1.
:- dynamic direct_request/2.
:- dynamic direct_call_count/1.
:- dynamic direct_tool_count/1.
:- dynamic direct_test_directory/1.
:- prolog_load_context(directory, DirectTestDirectory),
   assertz(direct_test_directory(DirectTestDirectory)).

reset_direct(Scenario) :-
    retractall(direct_scenario(_)),
    retractall(direct_request(_, _)),
    retractall(direct_call_count(_)),
    retractall(direct_tool_count(_)),
    assertz(direct_scenario(Scenario)),
    assertz(direct_call_count(0)),
    assertz(direct_tool_count(0)).

next_direct_call(Call) :-
    retract(direct_call_count(N0)),
    Call is N0+1,
    assertz(direct_call_count(Call)).

record_direct_request(Call, Request) :-
    assertz(direct_request(Call, Request)).

direct_provider_options(Capabilities, Extra,
                        [ provider(provider(openai_compatible, [])),
                          provider_name(openai_compatible),
                          model_handler(plunit_rlm_direct:scripted_direct_model),
                          capabilities(Capabilities),
                          prompt_compile_mode(all_tools)
                        | Extra
                        ]).

scripted_direct_model(Request, ok(Response)) :-
    next_direct_call(Call),
    record_direct_request(Call, Request),
    direct_scenario(Scenario),
    scenario_response(Scenario, Call, Request, Text, ToolCalls, Reasoning),
    fake_direct_response(Call, Text, ToolCalls, Reasoning, Response0),
    scenario_wire_response(Scenario, Response0, Response).

scenario_wire_response(assistant_call_mismatch, Response0, Response) :-
    !,
    native_call("different_1", "context_search", _{query:"needle"}, Other),
    put_dict(tool_calls, Response0.assistant, [Other], Assistant),
    put_dict(assistant, Response0, Assistant, Response).
scenario_wire_response(_, Response, Response).

typed_plan_model_step_plan(Plan) :-
    Plan = _{steps:[_{op:"model",
                      provider:"openai_compatible",
                      prompt:"fetch the runtime token value",
                      bind:"reply"},
                    _{op:"final",
                      value:_{ref:"field",
                              value:_{ref:"var",name:"reply"},
                              key:"text"}}]}.

typed_plan_model_step_plan(ExtraModelOptions, Plan) :-
    Plan = _{steps:[_{op:"model",
                      provider:"openai_compatible",
                      prompt:"fetch the runtime token value",
                      options:ExtraModelOptions,
                      bind:"reply"},
                    _{op:"final",
                      value:_{ref:"field",
                              value:_{ref:"var",name:"reply"},
                              key:"text"}}]}.

scenario_response(context_search(UUID), 1, _, "", [ToolCall], "") :-
    native_call("ctx_1", "context_search",
                _{query:"DIRECT_NEEDLE"}, ToolCall),
    assertion(string(UUID)).
scenario_response(context_search(UUID), 2, Request, UUID, [], "") :-
    request_tool_message(Request, "ctx_1", context_search, Content),
    assertion(sub_string(Content, _, _, _, UUID)).

scenario_response(registered_tool(Token), 1, _, "", [ToolCall], "") :-
    native_call("tool_1", "runtime_token", _{}, ToolCall),
    assertion(string(Token)).
scenario_response(registered_tool(Token), 2, Request, "", [ToolCall], "") :-
    request_tool_message(Request, "tool_1", runtime_token, Content),
    assertion(sub_string(Content, _, _, _, "result_tool_1")),
    native_call("tool_ctx_1", "context_peek",
                _{context:"result_tool_1",
                  selector:_{type:"item",index:0}}, ToolCall),
    assertion(string(Token)).
scenario_response(registered_tool(Token), 3, Request, Token, [], "") :-
    request_tool_message(Request, "tool_ctx_1", context_peek, Content),
    assertion(sub_string(Content, _, _, _, Token)).

scenario_response(malicious_call(Name, Args), 1, _, "", [ToolCall], "") :-
    native_call("bad_1", Name, Args, ToolCall).
% Issue #313: an unavailable native tool is a per-call recoverable fault, so
% the bounded loop continues after the structured fault observation instead
% of rejecting the whole batch.
scenario_response(malicious_call(_, _), 2, _, "CALL_REJECTED", [], "").

scenario_response(malformed_with_text, 1, _, "MUST_NOT_SUCCEED",
                  [_{id:"bad id",type:"function",
                     function:_{name:"context_search",arguments:"{}"}}], "").

scenario_response(assistant_call_mismatch, 1, _, "", [ToolCall], "") :-
    native_call("ctx_1", "context_search", _{query:"needle"}, ToolCall).

scenario_response(duplicate_context_id, 1, _, "", [ToolCall], "") :-
    native_call("same_1", "context_search", _{query:"needle"}, ToolCall).
scenario_response(duplicate_context_id, 2, Request, "", [ToolCall], "") :-
    request_tool_message(Request, "same_1", context_search, _),
    native_call("same_1", "context_search", _{query:"needle"}, ToolCall).

scenario_response(peek_head_count_index, 1, _, "", [ToolCall], "") :-
    native_call("peek_head_1", "context_peek",
                _{context:"input",
                  selector:_{count:20, index:0, type:"head"}},
                ToolCall).
scenario_response(peek_head_count_index, 2, _, "HEAD_PEEK_DONE", [], "").

scenario_response(peek_head_default, 1, _, "", [ToolCall], "") :-
    native_call("peek_head_d1", "context_peek",
                _{context:"input", selector:_{type:"head"}},
                ToolCall).
scenario_response(peek_head_default, 2, _, "HEAD_DEFAULT_DONE", [], "").

scenario_response(two_context_calls, 1, _, "", [ToolCall], "") :-
    native_call("ctx_1", "context_search", _{query:"needle"}, ToolCall).
scenario_response(two_context_calls, 2, _, "", [ToolCall], "") :-
    native_call("ctx_2", "context_search", _{query:"needle"}, ToolCall).

scenario_response(two_registered_calls, 1, _, "", [ToolCall], "") :-
    native_call("tool_1", "runtime_token", _{}, ToolCall).
scenario_response(two_registered_calls, 2, _, "", [ToolCall], "") :-
    native_call("tool_2", "runtime_token", _{}, ToolCall).

scenario_response(missing_final, 1, _, "", [], "internal reasoning only").

scenario_response(truncated_context, 1, _, "", [ToolCall], "") :-
    native_call("ctx_1", "context_search",
                _{query:"DIRECT_NEEDLE"}, ToolCall).
scenario_response(truncated_context, 2, Request, "bounded", [], "") :-
    request_tool_message(Request, "ctx_1", context_search, Content),
    assertion(sub_string(Content, _, _, _, "\"truncated\":true")).

scenario_response(typed_plan_native, 1, _, "", [ToolCall], "") :-
    native_call("plan_1", "typed_plan_execute",
                _{plan:_{steps:[_{op:"final",value:"NATIVE_PLAN_OK"}]}},
                ToolCall).
scenario_response(typed_plan_native, 2, Request, "", [ToolCall], "") :-
    request_tool_message(Request, "plan_1", typed_plan_execute, Content),
    assertion(sub_string(Content, _, _, _, "result_plan_1")),
    native_call("plan_ctx_1", "context_peek",
                _{context:"result_plan_1",
                  selector:_{type:"item",index:0}}, ToolCall).
scenario_response(typed_plan_native, 3, Request, "NATIVE_PLAN_OK", [], "") :-
    request_tool_message(Request, "plan_ctx_1", context_peek, Content),
    assertion(sub_string(Content, _, _, _, "NATIVE_PLAN_OK")).

scenario_response(typed_plan_model_step, 1, _, "", [ToolCall], "") :-
    typed_plan_model_step_plan(Plan),
    native_call("plan_1", "typed_plan_execute", _{plan:Plan}, ToolCall).
scenario_response(typed_plan_model_step, 2, _, "", [ToolCall], "") :-
    native_call("child_tool_1", "runtime_token", _{}, ToolCall).
scenario_response(typed_plan_model_step, 3, Request, "", [ToolCall], "") :-
    request_tool_message(Request, "child_tool_1", runtime_token, Content),
    assertion(sub_string(Content, _, _, _, "result_child_tool_1")),
    native_call("child_ctx_1", "context_peek",
                _{context:"result_child_tool_1",
                  selector:_{type:"item",index:0}}, ToolCall).
scenario_response(typed_plan_model_step, 4, Request, FinalText, [], "") :-
    request_tool_message(Request, "child_ctx_1", context_peek, Content),
    assertion(sub_string(Content, _, _, _, "plan-model-token-value")),
    format(string(FinalText),
           "PLAN_MODEL token=plan-model-token-value", []).
scenario_response(typed_plan_model_step, 5, _, "", [ToolCall], "") :-
    native_call("plan_ctx_1", "context_peek",
                _{context:"result_plan_1",
                  selector:_{type:"item",index:0}}, ToolCall).
scenario_response(typed_plan_model_step, 6, Request, "TYPED_PLAN_MODEL_OK", [],
                  "") :-
    request_tool_message(Request, "plan_ctx_1", context_peek, Content),
    assertion(sub_string(Content, _, _, _, "PLAN_MODEL")).
scenario_response(typed_plan_model_step, N, _, "", [], "") :-
    integer(N),
    N >= 7,
    !,
    throw(error(unexpected_provider_call(N),
                context(rlm_direct_test, typed_plan_model_step))).

scenario_response(typed_plan_reserved_options, 1, _, "", [ToolCall], "") :-
    typed_plan_model_step_plan(_{tools:[],stream:false}, Plan),
    native_call("plan_1", "typed_plan_execute", _{plan:Plan}, ToolCall).
scenario_response(typed_plan_reserved_options, N, _, "", [], "") :-
    integer(N),
    N >= 2,
    !,
    throw(error(unexpected_provider_call(N),
                context(rlm_direct_test, typed_plan_reserved_options))).

scenario_response(typed_plan_model_step_budget, 1, _, "", [ToolCall], "") :-
    typed_plan_model_step_plan(Plan),
    native_call("plan_1", "typed_plan_execute", _{plan:Plan}, ToolCall).
scenario_response(typed_plan_model_step_budget, 2, _, "", [ToolCall], "") :-
    native_call("child_tool_1", "runtime_token", _{}, ToolCall).
scenario_response(typed_plan_model_step_budget, N, _, "", [], "") :-
    integer(N),
    N >= 3,
    !,
    throw(error(unexpected_provider_call(N),
                context(rlm_direct_test, typed_plan_model_step_budget))).

scenario_response(spec_lifecycle, 1, _, "", [ToolCall], "") :-
    native_spec_source(Source),
    native_call("spec_1", "spec_compile",
                _{source:Source,series:"native_direct",version:1}, ToolCall).
scenario_response(spec_lifecycle, 2, Request, "", [ToolCall], "") :-
    request_tool_message(Request, "spec_1", spec_compile, Content),
    assertion(sub_string(Content, _, _, _, "result_spec_1")),
    native_call("observe_1", "spec_observe",
                _{spec_context:"result_spec_1"}, ToolCall).
scenario_response(spec_lifecycle, 3, Request, "", [ToolCall], "") :-
    request_tool_message(Request, "observe_1", spec_observe, Content),
    assertion(sub_string(Content, _, _, _, "result_observe_1")),
    native_call("verify_1", "spec_verify",
                _{spec_context:"result_spec_1",
                  observations_context:"result_observe_1"}, ToolCall).
scenario_response(spec_lifecycle, 4, Request, "", [ToolCall], "") :-
    request_tool_message(Request, "verify_1", spec_verify, Content),
    assertion(sub_string(Content, _, _, _, "result_verify_1")),
    native_call("verify_ctx_1", "context_peek",
                _{context:"result_verify_1",
                  selector:_{type:"item",index:0}}, ToolCall).
scenario_response(spec_lifecycle, 5, Request, "SPEC_OK", [], "") :-
    request_tool_message(Request, "verify_ctx_1", context_peek, Content),
    assertion(sub_string(Content, _, _, _, "passed")).

scenario_response(effectful_repeat, 1, _, "", [ToolCall], "") :-
    native_call("effect_1", "counting_write", _{value:7}, ToolCall).
scenario_response(effectful_repeat, 2, Request, "", [ToolCall], "") :-
    request_tool_message(Request, "effect_1", counting_write, Content),
    assertion(sub_string(Content, _, _, _, "result_effect_1")),
    native_call("effect_2", "counting_write", _{value:7}, ToolCall).
scenario_response(effectful_once, 1, _, "", [ToolCall], "") :-
    native_call("effect_1", "counting_write", _{value:7}, ToolCall).
scenario_response(cache_probe, 1, _, "CACHE_OK", [], "").

scenario_response(slow_provider(Queue), 1, _, "unused", [], "") :-
    thread_send_message(Queue, provider_started),
    sleep(5).

scenario_response(slow_tool(_), 1, _, "", [ToolCall], "") :-
    native_call("tool_1", "slow_read", _{}, ToolCall).

native_call(Id, Name, Args, Call) :-
    atom_json_dict(ArgumentsAtom, Args, [width(0)]),
    atom_string(ArgumentsAtom, Arguments),
    Call = _{id:Id,
             type:"function",
             function:_{name:Name,arguments:Arguments}}.

fake_direct_response(Call, Text, ToolCalls, Reasoning,
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

request_tool_message(Request, Id, Name, Content) :-
    member(Message, Request.messages),
    Message.role == tool,
    Message.tool_call_id == Id,
    Message.name == Name,
    Content = Message.content,
    !.

runtime_token_schema(
    tool_schema{name:runtime_token,
                description:"Return the trusted runtime token",
                capability:tool(runtime_token),
                effect:read,
                arguments:_{type:object,
                            properties:_{},
                            required:[],
                            additional_properties:false},
                result:_{type:object,
                         properties:_{token:_{type:string}},
                         required:[token],
                         additional_properties:false},
                limits:_{time_limit:1.0,max_output_bytes:1024}}).

runtime_token_handler(_, json{token:Token}) :-
    retract(direct_tool_count(N0)),
    N is N0+1,
    assertz(direct_tool_count(N)),
    direct_scenario(Scenario),
    scenario_token(Scenario, Token).

scenario_token(registered_tool(Token), Token).
scenario_token(two_registered_calls, "budget-token").
scenario_token(typed_plan_model_step, "plan-model-token-value").
scenario_token(typed_plan_model_step_budget, "plan-model-token-value").

slow_read_schema(
    tool_schema{name:slow_read,
                description:"Block behind a deterministic cancellation barrier",
                capability:tool(slow_read),
                effect:read,
                arguments:_{type:object,properties:_{},required:[],
                            additional_properties:false},
                result:_{type:string},
                limits:_{time_limit:10.0,max_output_bytes:1024}}).

slow_read_handler(_, "late") :-
    direct_scenario(slow_tool(Queue)),
    thread_send_message(Queue, tool_started),
    sleep(5).

register_runtime_token(Registry) :-
    runtime_token_schema(Schema),
    tool_register(Registry, Schema,
                  plunit_rlm_direct:runtime_token_handler, ok(_)).

register_slow_read(Registry) :-
    slow_read_schema(Schema),
    tool_register(Registry, Schema,
                  plunit_rlm_direct:slow_read_handler, ok(_)).

native_assertion_registry([
    assertion_provider(native_true,
                       1,
                       plunit_rlm_direct:validate_native_true,
                       plunit_rlm_direct:evaluate_native_true,
                       plunit_rlm_direct:observe_native_true,
                       _{verifier:_{id:native_verifier,version:1},
                         collector:_{id:native_collector,version:1},
                         evidence_policy:_{required_evidence:true,
                                           source_classes:[native_test],
                                           trust_classes:[observed],
                                           freshness:current,
                                           coherence:none,
                                           state_ref:any},
                         latency:pure,
                         description:"native direct SPEC fixture"})
]).

validate_native_true(Args) :- is_dict(Args).

evaluate_native_true(_, Observation, Status) :-
    ( Observation.value == true -> Status=passed ; Status=failed ).

observe_native_true(_, Sources, _, Raw) :-
    memberchk(native_source, Sources),
    Raw = _{status:passed,
            value:true,
            evidence_refs:[native_evidence],
            source_class:native_test,
            trust_class:observed,
            provenance:_{provider:native_fixture},
            freshness:current,
            coherence:none,
            state_ref:none}.

native_spec_source(
    "spec([subject(native_direct),require(native_pass,assertion(native_true,_{}))])").

setup_direct_effect_store(File) :-
    tmp_file(rlm_direct_effect, File),
    rlm_effect_store_open(File),
    tool_effect_test_support:reset_tool_mutations.

cleanup_direct_effect_store(File) :-
    catch(rlm_effect_store_close, _, true),
    catch(delete_file(File), _, true),
    tool_effect_test_support:reset_tool_mutations.

register_counting_write(Registry) :-
    tool_effect_test_support:write_schema(Schema),
    tool_register(Registry, Schema,
                  tool_effect_test_support:counting_write_tool, ok(_)).

direct_skill_catalog(Catalog) :-
    direct_test_directory(TestDirectory),
    directory_file_path(TestDirectory, 'fixtures/skills', Root),
    skill_catalog_load([skill_root(test,Root)], [], ok(Catalog)).

compiled_projection(Query, Registry, Catalog, Projection) :-
    reset_direct(cache_probe),
    Options = [ provider(provider(openai_compatible, [])),
                provider_name(openai_compatible),
                model_handler(plunit_rlm_direct:scripted_direct_model),
                capabilities([tool(runtime_token)]),
                tool_registry(Registry),
                skill_catalog(Catalog),
                explicit_skills([tdd])
              ],
    rlm_direct(Query, text("dynamic context"), Options, ok(_)),
    direct_request(1, Request),
    append(StaticMessages, [_DynamicTask], Request.messages),
    (   get_dict(tools, Request.options, Tools)
    ->  true
    ;   Tools = []
    ),
    Projection = cache_projection{tools:Tools,
                                  messages:StaticMessages}.

test(native_context_search_round_trip_returns_exact_final_text) :-
    UUID = "7bff19a0-runtime-only-uuid",
    reset_direct(context_search(UUID)),
    direct_provider_options([context(search)], [], Options),
    format(string(Context), "prefix\nDIRECT_NEEDLE payload=~s\nsuffix", [UUID]),
    rlm_direct("Find the opaque UUID", text(Context), Options, ok(Result)),
    assertion(Result.value == UUID),
    assertion(Result.turns =:= 2),
    assertion(Result.context_calls =:= 1),
    assertion(Result.tool_calls =:= 0),
    direct_request(1, FirstRequest),
    direct_request(2, SecondRequest),
    term_string(FirstRequest, FirstText),
    assertion(\+ sub_string(FirstText, _, _, _, UUID)),
    assertion(\+ sub_string(FirstText, _, _, _, "{\"steps\"")),
    member(ContextSchema, FirstRequest.options.tools),
    assertion(ContextSchema.function.name == "context_search"),
    assertion(FirstRequest.options.tools == SecondRequest.options.tools).

test(native_registered_tool_round_trip_uses_canonical_registry) :-
    Token = "runtime-generated-tool-token",
    reset_direct(registered_tool(Token)),
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_runtime_token(Registry),
        ( direct_provider_options([tool(runtime_token),context(peek)],
                                  [tool_registry(Registry)], Options),
          rlm_direct("Use runtime_token", text("opaque"), Options, ok(Result)),
          assertion(Result.value == Token),
          assertion(Result.turns =:= 3),
          assertion(Result.context_calls =:= 1),
          assertion(Result.tool_calls =:= 1),
          direct_tool_count(1),
          once((member(ToolEvent, Result.trajectory),
                ToolEvent.type == native_tool)),
          assertion(ToolEvent.call_id == "tool_1"),
          assertion(ToolEvent.trace.authorization == allowed)
        ),
        tool_registry_destroy(Registry)).

test(typed_plan_mode_is_available_as_capability_gated_native_tool) :-
    reset_direct(typed_plan_native),
    direct_provider_options([plan(execute),context(peek)], [], Options),
    rlm_direct("Execute a typed plan", text("opaque"), Options, ok(Result)),
    assertion(Result.value == "NATIVE_PLAN_OK"),
    assertion(Result.turns =:= 3),
    assertion(Result.tool_calls =:= 1),
    assertion(Result.context_calls =:= 1),
    once((member(Event, Result.trajectory),
          Event.type == native_tool,
          Event.name == typed_plan_execute)).

test(typed_plan_steps_consume_shared_iteration_budget) :-
    reset_direct(typed_plan_native),
    direct_provider_options([plan(execute),context(peek)],
                            [budget(_{max_iterations:2})], Options),
    rlm_direct("Execute a typed plan", text("opaque"), Options, error(Error)),
    assertion(Error.kind == iteration_budget_exhausted),
    assertion(Error.iterations =:= 2),
    direct_call_count(1).

test(typed_plan_model_step_runs_native_session_with_compiler_selected_schemas) :-
    reset_direct(typed_plan_model_step),
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_runtime_token(Registry),
        ( typed_plan_compiled_options(Registry, Options),
          rlm_direct("Execute a typed plan", text("opaque"), Options,
                     ok(Result)),
          assertion(Result.value == "TYPED_PLAN_MODEL_OK"),
          assertion(Result.turns =:= 6),
          assertion(Result.iterations =:= 7),
          direct_call_count(6),
          direct_tool_count(1),
          Result.usage.total_tokens =:= 18,
          once((member(Event, Result.trajectory),
                Event.type == native_tool,
                Event.name == typed_plan_execute)),
          assertion(Event.trace.nested_iterations =:= 4),
          assertion(Event.trace.nested_model_calls =:= 3),
          assertion(Event.trace.nested_tool_calls =:= 1),
          assertion(Event.trace.nested_context_calls =:= 1),
          direct_request(1, OuterReq),
          assertion(wire_names(OuterReq,
                               ["context_peek", "typed_plan_execute"])),
          direct_request(2, ChildReq1),
          assertion(wire_names(ChildReq1,
                               ["context_peek", "typed_plan_execute",
                                "runtime_token"])),
          ChildReq1.messages = [_, ChildSystem, ChildTask|_],
          assertion(sub_string(ChildSystem.content, _, _, _,
                               "bounded direct agent")),
          assertion(sub_string(ChildTask.content, _, _, _,
                               "fetch the runtime token value")),
          direct_request(3, ChildReq2),
          assertion(ChildReq2.options.tools == ChildReq1.options.tools),
          ChildReq2.messages = [_, _, _, ChildAssistant, ChildTool],
          assertion(ChildAssistant.role == assistant),
          ChildAssistant.tool_calls = [AssistantCall],
          assertion(AssistantCall.id == "child_tool_1"),
          assertion(ChildTool.role == tool),
          assertion(ChildTool.tool_call_id == "child_tool_1"),
          assertion(ChildTool.name == runtime_token),
          direct_request(4, ChildReq3),
          assertion(ChildReq3.options.tools == ChildReq1.options.tools)
        ),
        tool_registry_destroy(Registry)).

test(typed_plan_model_step_rejects_reserved_options_before_provider_dispatch) :-
    reset_direct(typed_plan_reserved_options),
    direct_provider_options([model(openai_compatible),plan(execute)], [],
                            Options),
    rlm_direct("Execute a typed plan", text("opaque"), Options, error(Error)),
    assertion(Error.kind == model_error),
    assertion(sub_string(Error.cause.cause, _, _, _,
                         "reserved_native_request_option")),
    direct_call_count(1).

test(typed_plan_model_step_budget_exhaustion_blocks_extra_provider_call) :-
    reset_direct(typed_plan_model_step_budget),
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_runtime_token(Registry),
        ( direct_provider_options([model(openai_compatible),plan(execute),
                                   tool(runtime_token)],
                                  [tool_registry(Registry),
                                   budget(_{max_model_calls:2})],
                                  Options),
          rlm_direct("Execute a typed plan", text("opaque"), Options,
                     error(Error)),
          assertion(Error.kind == model_error),
          assertion(sub_string(Error.cause.cause, _, _, _,
                               "model_call_budget_exhausted")),
          direct_call_count(2),
          direct_tool_count(1)
        ),
        tool_registry_destroy(Registry)).

typed_plan_compiled_options(Registry, Options) :-
    Options = [ provider(provider(openai_compatible, [])),
                provider_name(openai_compatible),
                model_handler(plunit_rlm_direct:scripted_direct_model),
                capabilities([model(openai_compatible),
                              plan(execute),
                              context(peek),
                              tool(runtime_token)]),
                tool_registry(Registry),
                budget(_{max_iterations:16,
                         max_model_calls:8,
                         max_tool_calls:8,
                         max_context_ops:8})
              ].

wire_names(Request, Names) :-
    (   get_dict(tools, Request.options, Tools)
    ->  maplist(wire_tool_name, Tools, Names)
    ;   Names = []
    ).

wire_tool_name(Tool, Name) :-
    Name = Tool.function.name.

test(full_spec_compile_observe_verify_lifecycle_uses_native_tools) :-
    reset_direct(spec_lifecycle),
    native_assertion_registry(Registry),
    direct_provider_options([spec(freeze),spec(observe),spec(verify),
                             context(peek)],
                            [ assertion_registry(Registry),
                              observation_sources([native_source]),
                              budget(_{max_model_calls:6,
                                       max_tool_calls:4})
                            ], Options),
    rlm_direct("Compile and verify the SPEC", text("opaque"), Options,
               ok(Result)),
    assertion(Result.value == "SPEC_OK"),
    assertion(Result.turns =:= 5),
    assertion(Result.tool_calls =:= 3),
    assertion(Result.context_calls =:= 1),
    once((member(Event, Result.trajectory),
          Event.type == native_tool,
          Event.name == spec_verify)).

test(effectful_native_retry_does_not_resubmit_without_fresh_authority) :-
    setup_call_cleanup(
        setup_direct_effect_store(Store),
        ( reset_direct(effectful_repeat),
          Context = session(direct_effect_repeat),
          rlm_set_authority(Context, dangerous, ok(_)),
          tool_registry_create(Registry),
          setup_call_cleanup(
              register_counting_write(Registry),
              ( direct_provider_options([tool(counting_write)],
                                        [ tool_registry(Registry),
                                          authority_context(Context)
                                        ], Options),
                rlm_direct("Repeat an effect", text("opaque"), Options,
                           error(Error)),
                assertion(Error.kind == effectful_replay_denied),
                tool_effect_test_support:tool_mutation_count(1)
              ),
              ( tool_registry_destroy(Registry),
                rlm_authority_clear(Context)
              ))
        ),
        cleanup_direct_effect_store(Store)).

test(effectful_native_tool_needing_approval_terminates_without_mutation) :-
    setup_call_cleanup(
        setup_direct_effect_store(Store),
        ( reset_direct(effectful_once),
          Context = session(direct_effect_pending),
          tool_registry_create(Registry),
          setup_call_cleanup(
              register_counting_write(Registry),
              ( direct_provider_options([tool(counting_write)],
                                        [ tool_registry(Registry),
                                          authority_context(Context)
                                        ], Options),
                rlm_direct("Request an effect", text("opaque"), Options,
                           error(Error)),
                assertion(Error.kind == approval_required),
                tool_effect_test_support:tool_mutation_count(0)
              ),
              ( tool_registry_destroy(Registry),
                rlm_authority_clear(Context)
              ))
        ),
        cleanup_direct_effect_store(Store)).

test(ten_fresh_compiler_runs_are_deterministic_for_the_same_query) :-
    tool_registry_create(Registry),
    setup_call_cleanup(
        ( register_runtime_token(Registry),
          direct_skill_catalog(Catalog)
        ),
        ( findall(Projection,
                  ( between(1,10,_),
                    compiled_projection("use runtime_token to diagnose a broken regression",
                                        Registry, Catalog, Projection)
                  ),
                  Projections),
          sort(Projections, Unique),
          assertion(Unique = [_]),
          Projections = [First|_],
          length(First.tools, 1),
          term_string(First.messages, StaticText),
          assertion(sub_string(StaticText, _, _, _, "TDD_SKILL_MARKER")),
          assertion(sub_string(StaticText, _, _, _, "DEBUG_SKILL_MARKER"))
        ),
        tool_registry_destroy(Registry)).

test(default_direct_compilation_uses_query_context) :-
    tool_registry_create(Registry),
    setup_call_cleanup(
        ( register_runtime_token(Registry),
          direct_skill_catalog(Catalog)
        ),
        ( once(compiled_projection(
                   "use runtime_token to diagnose a broken regression",
                   Registry, Catalog, Relevant)),
          once(compiled_projection("paint a watercolor landscape",
                                   Registry, Catalog, Unrelated)),
          length(Relevant.tools, 1),
          assertion(Unrelated.tools == []),
          term_string(Relevant.messages, RelevantText),
          term_string(Unrelated.messages, UnrelatedText),
          assertion(sub_string(RelevantText, _, _, _, "TDD_SKILL_MARKER")),
          assertion(sub_string(RelevantText, _, _, _, "DEBUG_SKILL_MARKER")),
          assertion(sub_string(UnrelatedText, _, _, _, "TDD_SKILL_MARKER")),
          assertion(\+ sub_string(UnrelatedText, _, _, _, "DEBUG_SKILL_MARKER"))
        ),
        tool_registry_destroy(Registry)).

test(schema_not_active_fails_before_registered_handler) :-
    reset_direct(malicious_call("runtime_token", _{})),
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_runtime_token(Registry),
        ( direct_provider_options([], [tool_registry(Registry)], Options),
          rlm_direct("Try hidden tool", text("opaque"), Options, ok(Result)),
          assertion(Result.value == "CALL_REJECTED"),
          assertion(Result.turns =:= 2),
          assertion(Result.tool_calls =:= 0),
          direct_tool_count(0),
          direct_request(2, SecondRequest),
          request_tool_message(SecondRequest, "bad_1", runtime_token, Content),
          assertion(sub_string(Content, _, _, _, "unavailable_tool_schema"))
        ),
        tool_registry_destroy(Registry)).

test(malformed_arguments_fail_before_registered_handler) :-
    reset_direct(malicious_call("runtime_token", [])),
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_runtime_token(Registry),
        ( direct_provider_options([tool(runtime_token)],
                                  [tool_registry(Registry)], Options),
          rlm_direct("Use runtime_token", text("opaque"), Options, error(Error)),
          assertion(Error.kind == malformed_arguments),
          direct_tool_count(0)
        ),
        tool_registry_destroy(Registry)).

test(unknown_native_tool_name_fails_closed) :-
    reset_direct(malicious_call("not_registered", _{})),
    direct_provider_options([], [], Options),
    rlm_direct("Unknown tool", text("opaque"), Options, ok(Result)),
    assertion(Result.value == "CALL_REJECTED"),
    assertion(Result.turns =:= 2),
    assertion(Result.tool_calls =:= 0),
    direct_request(2, SecondRequest),
    request_tool_message(SecondRequest, "bad_1", not_registered, Content),
    assertion(sub_string(Content, _, _, _, "unavailable_tool_schema")).

test(text_does_not_rescue_malformed_native_calls) :-
    reset_direct(malformed_with_text),
    direct_provider_options([context(search)], [], Options),
    rlm_direct("Malformed call", text("opaque"), Options, error(Error)),
    assertion(Error.kind == malformed_call_id).

test(assistant_message_must_match_normalized_call_batch) :-
    reset_direct(assistant_call_mismatch),
    direct_provider_options([context(search)], [], Options),
    rlm_direct("Reject mismatched assistant calls", text("needle"), Options,
               error(Error)),
    assertion(Error.kind == assistant_tool_calls_mismatch),
    assertion(Error.context_calls =:= 0).

test(duplicate_call_id_is_rejected_before_second_execution) :-
    reset_direct(duplicate_context_id),
    direct_provider_options([context(search)], [], Options),
    rlm_direct("Duplicate call", text("needle"), Options, error(Error)),
    assertion(Error.kind == duplicate_call_id),
    assertion(Error.context_calls =:= 1).

test(context_output_truncation_remains_explicit) :-
    UUID = "uuid-after-large-prefix",
    reset_direct(truncated_context),
    direct_provider_options([context(search)],
                            [context_options([max_results(1),
                                              max_bytes(48),
                                              time_limit(1.0)])],
                            Options),
    length(PrefixCodes, 200),
    maplist(=(0'x), PrefixCodes),
    string_codes(Prefix, PrefixCodes),
    format(string(Context),
           "DIRECT_NEEDLE ~s payload=~s", [Prefix, UUID]),
    rlm_direct("Find bounded evidence", text(Context), Options, ok(Result)),
    once((member(Event, Result.trajectory), Event.type == native_context)),
    assertion(Event.result.truncated == true).

test(context_call_budget_exhaustion_precedes_second_context_call) :-
    reset_direct(two_context_calls),
    direct_provider_options([context(search)],
                            [budget(_{max_context_ops:1})], Options),
    rlm_direct("Budget context", text("needle"), Options, error(Error)),
    assertion(Error.kind == context_call_budget_exhausted),
    assertion(Error.context_calls =:= 1).

test(tool_call_budget_exhaustion_precedes_second_handler_call) :-
    reset_direct(two_registered_calls),
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_runtime_token(Registry),
        ( direct_provider_options([tool(runtime_token)],
                                  [ tool_registry(Registry),
                                    budget(_{max_tool_calls:1})
                                  ], Options),
          rlm_direct("Budget tools", text("opaque"), Options, error(Error)),
          assertion(Error.kind == tool_call_budget_exhausted),
          direct_tool_count(1)
        ),
        tool_registry_destroy(Registry)).

test(model_call_budget_exhaustion_precedes_continuation_request) :-
    reset_direct(two_context_calls),
    direct_provider_options([context(search)],
                            [budget(_{max_model_calls:1})], Options),
    rlm_direct("Budget model", text("needle"), Options, error(Error)),
    assertion(Error.kind == model_call_budget_exhausted),
    direct_call_count(1).

test(reasoning_without_final_text_is_terminal_failure) :-
    reset_direct(missing_final),
    direct_provider_options([], [], Options),
    rlm_direct("Need final", text("opaque"), Options, error(Error)),
    assertion(Error.kind == missing_final_output),
    assertion(Error.usage.model_calls =:= 1).

test(cancellation_interrupts_active_provider_turn) :-
    setup_call_cleanup(
        message_queue_create(Queue),
        ( reset_direct(slow_provider(Queue)),
          rlm_cancellation_token(Token),
          direct_provider_options([], [cancel_token(Token)], Options),
          rlm_direct_async("Cancel provider", text("opaque"), Options, Future),
          thread_get_message(Queue, provider_started),
          rlm_cancel(Token),
          rlm_future_await(Future, error(Error)),
          assertion(Error.kind == cancelled),
          rlm_future_destroy(Future)
        ),
        message_queue_destroy(Queue)).

test(cancellation_interrupts_active_registered_tool) :-
    setup_call_cleanup(
        message_queue_create(Queue),
        ( reset_direct(slow_tool(Queue)),
          retractall(direct_scenario(_)),
          assertz(direct_scenario(slow_tool(Queue))),
          tool_registry_create(Registry),
          setup_call_cleanup(
              register_slow_read(Registry),
              ( rlm_cancellation_token(Token),
                direct_provider_options([tool(slow_read)],
                                        [ tool_registry(Registry),
                                          cancel_token(Token)
                                        ], Options),
                rlm_direct_async("Cancel tool", text("opaque"), Options,
                                 Future),
                thread_get_message(Queue, tool_started),
                rlm_cancel(Token),
                rlm_future_await(Future, error(Error)),
                assertion(Error.kind == cancelled),
                rlm_future_destroy(Future)
              ),
              tool_registry_destroy(Registry))
        ),
        message_queue_destroy(Queue)).


test(native_context_peek_executes_reported_head_count_index_shape) :-
    reset_direct(peek_head_count_index),
    direct_provider_options([context(peek)], [], Options),
    rlm_direct("Peek the head", text("HEAD_PEEK_NEEDLE payload"), Options,
               ok(Result)),
    assertion(Result.value == "HEAD_PEEK_DONE"),
    assertion(Result.context_calls =:= 1),
    assertion(Result.turns =:= 2),
    direct_request(1, FirstRequest),
    member(Schema, FirstRequest.options.tools),
    assertion(Schema.function.name == "context_peek"),
    direct_request(2, SecondRequest),
    request_tool_message(SecondRequest, "peek_head_1", context_peek, Content),
    assertion(sub_string(Content, _, _, _, "HEAD_PEEK_NEEDLE")),
    assertion(sub_string(Content, _, _, _, "\"truncated\":true")),
    assertion(\+ sub_string(Content, _, _, _, "payload")).

test(native_context_peek_head_omitted_count_executes_with_default) :-
    reset_direct(peek_head_default),
    direct_provider_options([context(peek)], [], Options),
    rlm_direct("Peek the head", text("HEAD_DEFAULT_NEEDLE payload"), Options,
               ok(Result)),
    assertion(Result.value == "HEAD_DEFAULT_DONE"),
    assertion(Result.context_calls =:= 1),
    assertion(Result.turns =:= 2),
    direct_request(2, SecondRequest),
    request_tool_message(SecondRequest, "peek_head_d1", context_peek, Content),
    assertion(sub_string(Content, _, _, _, "HEAD_DEFAULT_NEEDLE payload")).

:- end_tests(rlm_direct).
