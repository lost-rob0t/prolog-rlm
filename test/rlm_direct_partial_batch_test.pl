:- begin_tests(rlm_direct_partial_batch).

% Issue #313: per-call recoverable preflight isolation for native call
% batches. One recoverable schema fault must not abort valid sibling calls,
% while batch-fatal protocol/policy violations (duplicate IDs, effectful
% batches, budget exhaustion, unclassified faults, cancellation) must still
% reject the whole requested batch before any operation executes.

:- use_module(library(http/json)).
:- use_module('../prolog/rlm_authority').
:- use_module('../prolog/rlm_completion').
:- use_module('../prolog/rlm_direct').
:- use_module('../prolog/rlm_effect').
:- use_module('../prolog/rlm_tool').
:- use_module('support/tool_effect_test_support').

:- dynamic partial_scenario/1.
:- dynamic partial_call_count/1.
:- dynamic partial_request/2.
:- dynamic partial_cancel_token/1.
:- dynamic partial_probe_count/1.

partial_reset(Scenario) :-
    retractall(partial_scenario(_)),
    retractall(partial_call_count(_)),
    retractall(partial_request(_, _)),
    retractall(partial_cancel_token(_)),
    retractall(partial_probe_count(_)),
    assertz(partial_scenario(Scenario)),
    assertz(partial_call_count(0)),
    assertz(partial_probe_count(0)).

partial_next_call(Call) :-
    retract(partial_call_count(N0)),
    Call is N0+1,
    assertz(partial_call_count(Call)).

partial_next_probe(Count) :-
    retract(partial_probe_count(N0)),
    Count is N0+1,
    assertz(partial_probe_count(Count)).

partial_provider_options(Capabilities,
                         Extra,
                         [ provider(provider(openai_compatible, [])),
                           provider_name(openai_compatible),
                           model_handler(plunit_rlm_direct_partial_batch:partial_scripted_model),
                           capabilities(Capabilities),
                           prompt_compile_mode(all_tools)
                         | Extra
                         ]).

partial_scripted_model(Request, ok(Response)) :-
    partial_next_call(Call),
    partial_scenario(Scenario),
    partial_maybe_cancel(Scenario),
    partial_response(Scenario, Call, Request, Text, ToolCalls, Reasoning),
    assertz(partial_request(Call, Request)),
    fake_partial_response(Call, Text, ToolCalls, Reasoning, Response).

% Deterministic cancellation: the token is cancelled before the scripted
% response is returned, so the next runtime cancellation boundary fires
% without any sleeps.
partial_maybe_cancel(cancel_before_classification) :- !,
    partial_cancel_token(Token),
    rlm_cancel(Token).
partial_maybe_cancel(_).

partial_response(valid_then_malformed, 1, _, "", [Good, Bad], "") :-
    partial_native_call("ctx_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Good),
    partial_native_call("bad_1", "context_search",
                        _{unexpected:"field"}, Bad).
partial_response(valid_then_malformed, 2, _, "PARTIAL_FIXED", [], "").

partial_response(malformed_then_valid, 1, _, "", [Bad, Good], "") :-
    partial_native_call("bad_1", "context_search",
                        _{unexpected:"field"}, Bad),
    partial_native_call("ctx_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Good).
partial_response(malformed_then_valid, 2, _, "PARTIAL_FIXED", [], "").

partial_response(valid_then_unavailable, 1, _, "", [Good, Bad], "") :-
    partial_native_call("ctx_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Good),
    partial_native_call("bad_1", "not_a_tool", _{}, Bad).
partial_response(valid_then_unavailable, 2, _, "PARTIAL_RESUMED", [], "").

partial_response(unavailable_then_valid, 1, _, "", [Bad, Good], "") :-
    partial_native_call("bad_1", "not_a_tool", _{}, Bad),
    partial_native_call("ctx_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Good).
partial_response(unavailable_then_valid, 2, _, "PARTIAL_RESUMED", [], "").

partial_response(valid_fault_valid, 1, _, "", [Good1, Bad, Good2], "") :-
    partial_native_call("ctx_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Good1),
    partial_native_call("bad_1", "context_search",
                        _{unexpected:"field"}, Bad),
    partial_native_call("ctx_2", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Good2).
partial_response(valid_fault_valid, 2, _, "PARTIAL_THREE", [], "").

partial_response(mixed_faults, 1, _, "", [Bad1, Good1, Bad2, Good2], "") :-
    partial_native_call("bad_1", "context_search",
                        _{unexpected:"field"}, Bad1),
    partial_native_call("ctx_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Good1),
    partial_native_call("bad_2", "also_not_a_tool", _{}, Bad2),
    partial_native_call("ctx_2", "context_search",
                        _{query:"PARTIAL_SECOND"}, Good2).
partial_response(mixed_faults, 2, _, "PARTIAL_MIXED", [], "").

% All calls recoverably invalid: every call is observed as a fault and the
% bounded loop continues so the model can repair (issue #313).
partial_response(all_faults_then_repair, 1, _, "", [Bad1, Bad2], "") :-
    partial_native_call("bad_1", "context_search",
                        _{unexpected:"x"}, Bad1),
    partial_native_call("bad_2", "also_not_a_tool", _{}, Bad2).
partial_response(all_faults_then_repair, 2, _, "PARTIAL_REPAIRED", [], "").

% The repair loop must stay bounded: repeated all-fault batches consume
% model-call budget until the direct loop terminates.
partial_response(all_faults_forever, Call, _, "", Calls, "") :-
    Call =< 4,
    Id1 is Call*2-1,
    Id2 is Call*2,
    format(string(FirstId), "loop_bad_~d", [Id1]),
    format(string(SecondId), "loop_bad_~d", [Id2]),
    partial_native_call(FirstId, "context_search",
                        _{unexpected:"x"}, Bad1),
    partial_native_call(SecondId, "also_not_a_tool", _{}, Bad2),
    Calls = [Bad1, Bad2].

partial_response(duplicate_ids_in_batch, 1, _, "", [Call1, Call2], "") :-
    partial_native_call("dup_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Call1),
    partial_native_call("dup_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Call2).

partial_response(reuse_faulted_id, 1, _, "", [Bad, Good], "") :-
    partial_native_call("bad_1", "context_search",
                        _{unexpected:"field"}, Bad),
    partial_native_call("ctx_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Good).
partial_response(reuse_faulted_id, 2, _, "", [Bad], "") :-
    partial_native_call("bad_1", "context_search",
                        _{unexpected:"field"}, Bad).

partial_response(context_budget, 1, _, "", [Call1, Call2], "") :-
    partial_native_call("ctx_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Call1),
    partial_native_call("ctx_2", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Call2).

partial_response(tool_budget, 1, _, "", [Call1, Call2], "") :-
    partial_native_call("tok_1", "partial_probe", _{}, Call1),
    partial_native_call("tok_2", "partial_probe", _{}, Call2).

partial_response(faults_do_not_consume_budget, 1, _, "", [Bad, Good1, Good2], "") :-
    partial_native_call("bad_1", "context_search",
                        _{unexpected:"field"}, Bad),
    partial_native_call("ctx_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Good1),
    partial_native_call("ctx_2", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Good2).
partial_response(faults_do_not_consume_budget, 2, _, "PARTIAL_BUDGET", [], "").

% Effectful batch isolation: the effectful call is part of the ORIGINAL
% requested batch, so recoverable faults in siblings must not launder the
% request into an executable effectful singleton (issue #313).
partial_response(effectful_plus_malformed, 1, _, "", [Effect, Bad], "") :-
    partial_native_call("eff_1", "counting_write", _{value:7}, Effect),
    partial_native_call("bad_1", "context_search",
                        _{unexpected:"field"}, Bad).
partial_response(effectful_plus_malformed, 2, _, "PARTIAL_FORBIDDEN", [], "").

partial_response(malformed_plus_effectful, 1, _, "", [Bad, Effect], "") :-
    partial_native_call("bad_1", "context_search",
                        _{unexpected:"field"}, Bad),
    partial_native_call("eff_1", "counting_write", _{value:7}, Effect).
partial_response(malformed_plus_effectful, 2, _, "PARTIAL_FORBIDDEN", [], "").

partial_response(effectful_plus_unavailable, 1, _, "", [Effect, Bad], "") :-
    partial_native_call("eff_1", "counting_write", _{value:7}, Effect),
    partial_native_call("bad_1", "not_a_tool", _{}, Bad).
partial_response(effectful_plus_unavailable, 2, _, "PARTIAL_FORBIDDEN", [], "").

partial_response(unavailable_plus_effectful, 1, _, "", [Bad, Effect], "") :-
    partial_native_call("bad_1", "not_a_tool", _{}, Bad),
    partial_native_call("eff_1", "counting_write", _{value:7}, Effect).
partial_response(unavailable_plus_effectful, 2, _, "PARTIAL_FORBIDDEN", [], "").

partial_response(effectful_plus_valid_read, 1, _, "", [Effect, Good], "") :-
    partial_native_call("eff_1", "counting_write", _{value:7}, Effect),
    partial_native_call("ctx_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Good).
partial_response(effectful_plus_valid_read, 2, _, "PARTIAL_FORBIDDEN", [], "").

% Cancellation is never a model-repairable fault observation.
partial_response(cancel_before_classification, 1, _, "", [Bad, Good], "") :-
    partial_native_call("bad_1", "context_search",
                        _{unexpected:"field"}, Bad),
    partial_native_call("ctx_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Good).

partial_response(cancel_mid_batch, 1, _, "", [Probe, Bad], "") :-
    partial_native_call("tok_1", "partial_cancel_probe", _{}, Probe),
    partial_native_call("bad_1", "context_search",
                        _{unexpected:"field"}, Bad).

% Registered-tool schema faults must expose only bounded diagnostics.
partial_response(registry_tool_fault, 1, _, "", [Good, Bad], "") :-
    partial_native_call("tok_1", "partial_probe", _{}, Good),
    partial_native_call("tok_2", "partial_probe", _{unexpected:"field"}, Bad).
partial_response(registry_tool_fault, 2, _, "PARTIAL_BOUNDED", [], "").

% Issue #314 integration: a malformed context_peek selector is a per-call
% malformed_arguments fault beside an executable read-only sibling.
partial_response(peek_fault_beside_search, 1, _, "", [Peek, Good], "") :-
    partial_native_call("peek_1", "context_peek",
                        _{selector:_{type:"metadata", index: -1}}, Peek),
    partial_native_call("ctx_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Good).
partial_response(peek_fault_beside_search, 2, _, "PARTIAL_PEEK_REPAIRED", [], "").

% Issue #314: the valid Auto-Dig head selector shape stays executable.
partial_response(valid_peek_beside_search, 1, _, "", [Peek, Good], "") :-
    partial_native_call("peek_1", "context_peek",
                        _{selector:_{type:"head", index:0, count:20}}, Peek),
    partial_native_call("ctx_1", "context_search",
                        _{query:"PARTIAL_NEEDLE"}, Good).
partial_response(valid_peek_beside_search, 2, _, "PARTIAL_PEEK_OK", [], "").

fake_partial_response(Call, Text, ToolCalls, Reasoning,
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
    format(string(ResponseId), "partial_response_~d", [Call]),
    (ToolCalls == [] -> FinishReason = stop ; FinishReason = tool_calls).

partial_native_call(Id, Name, Args, Call) :-
    atom_json_dict(ArgumentsAtom, Args, [width(0)]),
    atom_string(ArgumentsAtom, Arguments),
    Call = _{id:Id,
             type:"function",
             function:_{name:Name,arguments:Arguments}}.

% Ordered tool-result inspection for a recorded request.
request_tool_ids(Request, Ids) :-
    findall(Id,
            ( member(Message, Request.messages),
              Message.role == tool,
              Id = Message.tool_call_id ),
            Ids).

partial_tool_ids(Call, Ids) :-
    partial_request(Call, Request),
    request_tool_ids(Request, Ids).

partial_tool_content_for(Call, Id, Content) :-
    partial_request(Call, Request),
    member(Message, Request.messages),
    Message.role == tool,
    Message.tool_call_id == Id,
    !,
    Content = Message.content.

% --- Recoverable per-call faults preserve valid siblings --------------------

test(valid_sibling_survives_malformed_context_arguments) :-
    partial_reset(valid_then_malformed),
    partial_provider_options([context(search)], [], Options),
    rlm_direct("Partial batch", text("PARTIAL_NEEDLE"), Options, ok(Result)),
    assertion(Result.value == "PARTIAL_FIXED"),
    assertion(Result.context_calls =:= 1),
    assertion(Result.tool_calls =:= 0),
    assertion(Result.turns =:= 2),
    partial_tool_ids(2, ["ctx_1", "bad_1"]),
    partial_tool_content_for(2, "ctx_1", GoodContent),
    assertion(sub_string(GoodContent, _, _, _, "PARTIAL_NEEDLE")),
    partial_tool_content_for(2, "bad_1", BadContent),
    assertion(sub_string(BadContent, _, _, _, "malformed_arguments")),
    assertion(\+ sub_string(BadContent, _, _, _, "PARTIAL_NEEDLE")).

test(malformed_sibling_before_valid_preserves_request_order) :-
    partial_reset(malformed_then_valid),
    partial_provider_options([context(search)], [], Options),
    rlm_direct("Reversed fault order", text("PARTIAL_NEEDLE"), Options,
               ok(Result)),
    assertion(Result.value == "PARTIAL_FIXED"),
    assertion(Result.context_calls =:= 1),
    assertion(Result.turns =:= 2),
    partial_tool_ids(2, ["bad_1", "ctx_1"]),
    partial_tool_content_for(2, "bad_1", BadContent),
    assertion(sub_string(BadContent, _, _, _, "malformed_arguments")),
    partial_tool_content_for(2, "ctx_1", GoodContent),
    assertion(sub_string(GoodContent, _, _, _, "PARTIAL_NEEDLE")).

test(unknown_tool_in_batch_is_isolated_per_call) :-
    partial_reset(valid_then_unavailable),
    partial_provider_options([context(search)], [], Options),
    rlm_direct("Isolated fault", text("PARTIAL_NEEDLE"), Options, ok(Result)),
    assertion(Result.value == "PARTIAL_RESUMED"),
    assertion(Result.turns =:= 2),
    partial_tool_ids(2, ["ctx_1", "bad_1"]),
    partial_tool_content_for(2, "bad_1", BadContent),
    assertion(sub_string(BadContent, _, _, _, "unavailable_tool_schema")),
    partial_tool_content_for(2, "ctx_1", GoodContent),
    assertion(sub_string(GoodContent, _, _, _, "PARTIAL_NEEDLE")).

test(unavailable_tool_before_valid_sibling_preserves_request_order) :-
    partial_reset(unavailable_then_valid),
    partial_provider_options([context(search)], [], Options),
    rlm_direct("Reversed unavailable order", text("PARTIAL_NEEDLE"), Options,
               ok(Result)),
    assertion(Result.value == "PARTIAL_RESUMED"),
    partial_tool_ids(2, ["bad_1", "ctx_1"]),
    partial_tool_content_for(2, "bad_1", BadContent),
    assertion(sub_string(BadContent, _, _, _, "unavailable_tool_schema")),
    partial_tool_content_for(2, "ctx_1", GoodContent),
    assertion(sub_string(GoodContent, _, _, _, "PARTIAL_NEEDLE")).

test(valid_fault_valid_batch_executes_only_valid_calls_in_order) :-
    partial_reset(valid_fault_valid),
    partial_provider_options([context(search)], [], Options),
    rlm_direct("Three call batch", text("PARTIAL_NEEDLE"), Options,
               ok(Result)),
    assertion(Result.value == "PARTIAL_THREE"),
    assertion(Result.context_calls =:= 2),
    assertion(Result.turns =:= 2),
    partial_tool_ids(2, ["ctx_1", "bad_1", "ctx_2"]),
    partial_tool_content_for(2, "bad_1", BadContent),
    assertion(sub_string(BadContent, _, _, _, "malformed_arguments")),
    partial_tool_content_for(2, "ctx_1", Good1),
    assertion(sub_string(Good1, _, _, _, "PARTIAL_NEEDLE")),
    partial_tool_content_for(2, "ctx_2", Good2),
    assertion(sub_string(Good2, _, _, _, "PARTIAL_NEEDLE")).

test(mixed_recoverable_faults_and_valid_reads_keep_stable_order) :-
    partial_reset(mixed_faults),
    partial_provider_options([context(search)], [], Options),
    rlm_direct("Mixed faults", text("PARTIAL_NEEDLE and PARTIAL_SECOND"),
               Options, ok(Result)),
    assertion(Result.value == "PARTIAL_MIXED"),
    assertion(Result.context_calls =:= 2),
    assertion(Result.tool_calls =:= 0),
    assertion(Result.turns =:= 2),
    partial_tool_ids(2, ["bad_1", "ctx_1", "bad_2", "ctx_2"]),
    partial_tool_content_for(2, "bad_1", Fault1),
    assertion(sub_string(Fault1, _, _, _, "malformed_arguments")),
    partial_tool_content_for(2, "bad_2", Fault2),
    assertion(sub_string(Fault2, _, _, _, "unavailable_tool_schema")),
    partial_tool_content_for(2, "ctx_1", Good1),
    assertion(sub_string(Good1, _, _, _, "PARTIAL_NEEDLE")),
    partial_tool_content_for(2, "ctx_2", Good2),
    assertion(sub_string(Good2, _, _, _, "PARTIAL_SECOND")).

% --- All calls recoverably invalid continue the bounded loop ----------------

test(all_calls_recoverably_invalid_continue_the_bounded_loop) :-
    partial_reset(all_faults_then_repair),
    partial_provider_options([context(search)], [], Options),
    rlm_direct("All faulty", text("opaque"), Options, ok(Result)),
    assertion(Result.value == "PARTIAL_REPAIRED"),
    assertion(Result.turns =:= 2),
    assertion(Result.context_calls =:= 0),
    assertion(Result.tool_calls =:= 0),
    partial_tool_ids(2, ["bad_1", "bad_2"]),
    partial_tool_content_for(2, "bad_1", Fault1),
    assertion(sub_string(Fault1, _, _, _, "malformed_arguments")),
    partial_tool_content_for(2, "bad_2", Fault2),
    assertion(sub_string(Fault2, _, _, _, "unavailable_tool_schema")).

test(repeated_repair_attempts_stay_inside_the_model_call_budget) :-
    partial_reset(all_faults_forever),
    partial_provider_options([context(search)], [], Options),
    rlm_direct("Unbounded repair probe", text("opaque"), Options,
               error(Error)),
    assertion(Error.kind == model_call_budget_exhausted),
    assertion(Error.iterations =:= 4).

% --- Batch-fatal protocol and policy violations -----------------------------

test(duplicate_call_ids_inside_one_batch_are_batch_fatal) :-
    partial_reset(duplicate_ids_in_batch),
    partial_provider_options([context(search)], [], Options),
    rlm_direct("Duplicate ids", text("opaque"), Options, error(Error)),
    assertion(Error.kind == duplicate_call_id),
    assertion(Error.context_calls =:= 0),
    assertion(Error.tool_calls =:= 0).

test(faulted_call_ids_may_not_be_reused_in_a_later_batch) :-
    partial_reset(reuse_faulted_id),
    partial_provider_options([context(search)], [], Options),
    rlm_direct("Reuse faulted id", text("PARTIAL_NEEDLE"), Options,
               error(Error)),
    assertion(Error.kind == duplicate_call_id).

test(context_budget_exhaustion_rejects_the_whole_batch) :-
    partial_reset(context_budget),
    partial_provider_options([context(search)],
                             [budget(_{max_context_ops:1})],
                             Options),
    rlm_direct("Context budget", text("opaque"), Options, error(Error)),
    assertion(Error.kind == context_call_budget_exhausted),
    \+ partial_request(2, _).

test(tool_budget_exhaustion_rejects_the_whole_batch) :-
    partial_reset(tool_budget),
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_partial_probe(Registry),
        ( partial_provider_options([tool(partial_probe)],
                                   [tool_registry(Registry),
                                    budget(_{max_tool_calls:1})],
                                   Options),
           rlm_direct("Tool budget", text("opaque"), Options, error(Error)),
           assertion(Error.kind == tool_call_budget_exhausted),
           partial_probe_count(0)
         ),
        tool_registry_destroy(Registry)).

test(faulted_siblings_do_not_consume_batch_budget) :-
    partial_reset(faults_do_not_consume_budget),
    partial_provider_options([context(search)],
                             [budget(_{max_context_ops:2})],
                             Options),
    rlm_direct("Fault budget", text("PARTIAL_NEEDLE"), Options, ok(Result)),
    assertion(Result.value == "PARTIAL_BUDGET"),
    assertion(Result.context_calls =:= 2),
    assertion(Result.tool_calls =:= 0),
    assertion(Result.turns =:= 2).

% --- Effect isolation is evaluated against the ORIGINAL request -------------

test(effectful_call_with_malformed_sibling_is_batch_fatal) :-
    effectful_batch(effectful_plus_malformed,
                    [context(search), tool(counting_write)],
                    Error),
    assertion(Error.kind == effectful_batch_unsupported),
    assertion(Error.context_calls =:= 0),
    assertion(Error.tool_calls =:= 0),
    tool_effect_test_support:tool_mutation_count(0).

test(malformed_call_with_effectful_sibling_is_batch_fatal) :-
    effectful_batch(malformed_plus_effectful,
                    [context(search), tool(counting_write)],
                    Error),
    assertion(Error.kind == effectful_batch_unsupported),
    assertion(Error.context_calls =:= 0),
    assertion(Error.tool_calls =:= 0),
    tool_effect_test_support:tool_mutation_count(0).

test(effectful_call_with_unavailable_sibling_is_batch_fatal) :-
    effectful_batch(effectful_plus_unavailable,
                    [context(search), tool(counting_write)],
                    Error),
    assertion(Error.kind == effectful_batch_unsupported),
    assertion(Error.context_calls =:= 0),
    assertion(Error.tool_calls =:= 0),
    tool_effect_test_support:tool_mutation_count(0).

test(unavailable_call_with_effectful_sibling_is_batch_fatal) :-
    effectful_batch(unavailable_plus_effectful,
                    [context(search), tool(counting_write)],
                    Error),
    assertion(Error.kind == effectful_batch_unsupported),
    assertion(Error.context_calls =:= 0),
    assertion(Error.tool_calls =:= 0),
    tool_effect_test_support:tool_mutation_count(0).

test(effectful_call_with_valid_read_sibling_is_batch_fatal) :-
    effectful_batch(effectful_plus_valid_read,
                    [context(search), tool(counting_write)],
                    Error),
    assertion(Error.kind == effectful_batch_unsupported),
    assertion(Error.context_calls =:= 0),
    assertion(Error.tool_calls =:= 0),
    tool_effect_test_support:tool_mutation_count(0).

% --- Cancellation is never a recoverable fault observation ------------------

test(cancellation_before_classification_is_not_a_repairable_fault) :-
    rlm_cancellation_token(Token),
    partial_reset(cancel_before_classification),
    assertz(partial_cancel_token(Token)),
    partial_provider_options([context(search)],
                             [cancel_token(Token)],
                             Options),
    rlm_direct("Cancel provider", text("opaque"), Options,
               error(Error)),
    assertion(Error.kind == cancelled),
    partial_call_count(1),
    \+ partial_request(2, _).

test(cancellation_mid_batch_is_not_a_repairable_fault) :-
    rlm_cancellation_token(Token),
    partial_reset(cancel_mid_batch),
    assertz(partial_cancel_token(Token)),
    tool_registry_create(Registry),
    setup_call_cleanup(
        ( register_partial_probe(Registry),
          register_cancel_probe(Registry) ),
        ( partial_provider_options([tool(partial_cancel_probe),
                                    context(search)],
                                   [tool_registry(Registry),
                                    cancel_token(Token)],
                                   Options),
          rlm_direct("Cancel mid batch", text("opaque"), Options,
                     error(Error)),
          assertion(Error.kind == cancelled),
          partial_probe_count(1)
        ),
        tool_registry_destroy(Registry)).

% --- Bounded, stable recoverable fault observations -------------------------

test(registry_tool_fault_observations_stay_bounded) :-
    partial_reset(registry_tool_fault),
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_partial_probe(Registry),
        ( partial_provider_options([tool(partial_probe),
                                    context(search)],
                                   [tool_registry(Registry)],
                                   Options),
          rlm_direct("Bounded fault", text("PARTIAL_NEEDLE"), Options,
                     ok(Result)),
          assertion(Result.value == "PARTIAL_BOUNDED"),
          assertion(Result.tool_calls =:= 1),
          partial_tool_content_for(2, "tok_2", BadContent),
          assertion(sub_string(BadContent, _, _, _, "malformed_arguments")),
          assertion(\+ sub_string(BadContent, _, _, _, "schema_validation_failed")),
          assertion(\+ sub_string(BadContent, _, _, _,
                                  "tool value does not match its declared schema")),
          assertion(\+ sub_string(BadContent, _, _, _, "$term")),
          partial_tool_content_for(2, "tok_1", GoodContent),
          assertion(sub_string(GoodContent, _, _, _, "result_tok_1"))
        ),
        tool_registry_destroy(Registry)).

% --- Issue #314 integration: the peek selector contract ---------------------

test(malformed_peek_selector_is_recoverable_beside_valid_search) :-
    partial_reset(peek_fault_beside_search),
    partial_provider_options([context(peek), context(search)], [], Options),
    rlm_direct("Peek fault", text("PARTIAL_NEEDLE"), Options, ok(Result)),
    assertion(Result.value == "PARTIAL_PEEK_REPAIRED"),
    assertion(Result.context_calls =:= 1),
    assertion(Result.turns =:= 2),
    partial_tool_ids(2, ["peek_1", "ctx_1"]),
    partial_tool_content_for(2, "peek_1", Fault),
    assertion(sub_string(Fault, _, _, _, "malformed_arguments")),
    assertion(sub_string(Fault, _, _, _, "invalid_selector_field")),
    partial_tool_content_for(2, "ctx_1", Good),
    assertion(sub_string(Good, _, _, _, "PARTIAL_NEEDLE")).

test(valid_head_selector_beside_search_executes_both_in_order) :-
    partial_reset(valid_peek_beside_search),
    partial_provider_options([context(peek), context(search)], [], Options),
    rlm_direct("Valid peek", text("PARTIAL_NEEDLE"), Options, ok(Result)),
    assertion(Result.value == "PARTIAL_PEEK_OK"),
    assertion(Result.context_calls =:= 2),
    assertion(Result.turns =:= 2),
    partial_tool_ids(2, ["peek_1", "ctx_1"]).

% --- Positive recoverability policy (centralized, fatal by default) ---------

test(only_whitelisted_fault_kinds_are_recoverable) :-
    findall(Kind, rlm_direct:recoverable_fault_kind(Kind), Kinds),
    sort(Kinds, Sorted),
    assertion(Sorted == [malformed_arguments, unavailable_tool_schema]),
    forall(member(FutureKind,
                  [duplicate_call_id,
                   effectful_batch_unsupported,
                   context_call_budget_exhausted,
                   tool_call_budget_exhausted,
                   unknown_context_alias,
                   missing_assertion_registry,
                   future_runtime_corruption]),
           \+ rlm_direct:recoverable_fault_kind(FutureKind)).

test(whitelisted_fault_becomes_a_recoverable_status) :-
    Call = native_tool_call{id:"wb_1",
                            name:context_search,
                            arguments:_{},
                            type:function},
    Cause = direct_error{phase:schema,
                         kind:malformed_arguments,
                         message:"probe"},
    rlm_direct:recoverable_fault_status(Call, Cause, Status),
    assertion(Status == fault(Call, Cause)).

test(unclassified_fault_kind_escapes_classification) :-
    Cause = direct_error{phase:runtime,
                         kind:future_runtime_corruption,
                         message:"unclassified fault probe"},
    catch(rlm_direct:recoverable_fault_status(probe_call, Cause, _Status),
          direct_fault(Thrown),
          Thrown == Cause),
    assertion(Thrown == Cause).

test(unavailable_tool_classification_produces_a_recoverable_fault_status) :-
    Runtime = direct_runtime{bindings:[], registry:none},
    Call = native_tool_call{id:"wb_2",
                            name:context_search,
                            arguments:_{},
                            type:function},
    rlm_direct:preflight_call_status(Runtime, Call, Status),
    Status = fault(Call, Cause),
    assertion(Cause.kind == unavailable_tool_schema).

test(malformed_context_arguments_classification_produces_a_fault_status) :-
    Binding = native_binding{name:context_search,
                             kind:context(search),
                             effect:read,
                             schema:none},
    Runtime = direct_runtime{bindings:[Binding], registry:none},
    Call = native_tool_call{id:"wb_3",
                            name:context_search,
                            arguments:_{unexpected:"field"},
                            type:function},
    rlm_direct:preflight_call_status(Runtime, Call, Status),
    Status = fault(Call, Cause),
    assertion(Cause.kind == malformed_arguments).

test(valid_context_arguments_classification_is_resolved) :-
    Binding = native_binding{name:context_search,
                             kind:context(search),
                             effect:read,
                             schema:none},
    Runtime = direct_runtime{bindings:[Binding], registry:none},
    Call = native_tool_call{id:"wb_4",
                            name:context_search,
                            arguments:_{query:"PARTIAL_NEEDLE"},
                            type:function},
    rlm_direct:preflight_call_status(Runtime, Call,
                                     resolved_call{call:Call,
                                                   binding:Binding}).

% --- Fixtures ----------------------------------------------------------------

partial_probe_schema(
    tool_schema{name:partial_probe,
                description:"Counting read probe",
                capability:tool(partial_probe),
                effect:read,
                arguments:_{type:object,
                            properties:_{},
                            required:[],
                            additional_properties:false},
                result:_{type:string},
                limits:_{time_limit:2.0,max_output_bytes:1024}}).

partial_probe_handler(_, "probe-value") :-
    partial_next_probe(_).

partial_cancel_schema(
    tool_schema{name:partial_cancel_probe,
                description:"Read probe whose handler cancels the session token",
                capability:tool(partial_cancel_probe),
                effect:read,
                arguments:_{type:object,
                            properties:_{},
                            required:[],
                            additional_properties:false},
                result:_{type:string},
                limits:_{time_limit:2.0,max_output_bytes:1024}}).

partial_cancel_handler(_, "cancelled-probe") :-
    partial_next_probe(_),
    partial_cancel_token(Token),
    rlm_cancel(Token).

register_partial_probe(Registry) :-
    partial_probe_schema(Schema),
    tool_register(Registry, Schema,
                  plunit_rlm_direct_partial_batch:partial_probe_handler,
                  ok(_)).

register_cancel_probe(Registry) :-
    partial_cancel_schema(Schema),
    tool_register(Registry, Schema,
                  plunit_rlm_direct_partial_batch:partial_cancel_handler,
                  ok(_)).

effectful_batch(Scenario, Capabilities, Error) :-
    setup_call_cleanup(
        partial_setup_effect_store(Store),
        ( partial_reset(Scenario),
          Context = session(Scenario),
          rlm_set_authority(Context, dangerous, ok(_)),
          tool_registry_create(Registry),
          setup_call_cleanup(
              register_counting_write(Registry),
              ( partial_provider_options(Capabilities,
                                         [tool_registry(Registry),
                                          authority_context(Context)],
                                         Options),
                rlm_direct("Effectful batch", text("opaque"), Options,
                           error(Error))
              ),
              ( tool_registry_destroy(Registry),
                rlm_authority_clear(Context) ))
        ),
        partial_cleanup_effect_store(Store)).

partial_setup_effect_store(Store) :-
    tmp_file(rlm_direct_partial_effect, Store),
    rlm_effect_store_open(Store),
    tool_effect_test_support:reset_tool_mutations.

partial_cleanup_effect_store(Store) :-
    catch(rlm_effect_store_close, _, true),
    catch(delete_file(Store), _, true),
    tool_effect_test_support:reset_tool_mutations.

register_counting_write(Registry) :-
    tool_effect_test_support:write_schema(Schema),
    tool_register(Registry, Schema,
                  tool_effect_test_support:counting_write_tool, ok(_)).

:- end_tests(rlm_direct_partial_batch).
