:- begin_tests(rlm_completion_planner_validation_retry).

:- use_module('../prolog/rlm_completion').
:- use_module('../prolog/rlm_tool').

:- dynamic planner_call_count/1.
:- dynamic model_call_count/1.
:- dynamic planner_request/2.

reset_retry_fixture :-
    retractall(planner_call_count(_)),
    retractall(model_call_count(_)),
    retractall(planner_request(_, _)),
    assertz(planner_call_count(0)),
    assertz(model_call_count(0)).

bump_count(Predicate, Count) :-
    Goal0 =.. [Predicate, Previous],
    retract(Goal0),
    Count is Previous+1,
    Goal =.. [Predicate, Count],
    assertz(Goal).

planner_output(Plan,
               planner_output{plan:Plan,
                              usage:_{prompt_tokens:1,
                                      completion_tokens:1,
                                      total_tokens:2,
                                      cost:0.0}}).

structurally_invalid_then_valid_planner(Request, ok(Output)) :-
    bump_count(planner_call_count, Call),
    assertz(planner_request(Call, Request)),
    (   Call =:= 1
    ->  Plan = plan([model(openrouter,
                          literal("MUST_NOT_EXECUTE"),
                          _{},
                          forbidden),
                     final(literal("first-final")),
                     final(literal("second-final"))])
    ;   Plan = plan([final(literal("recovered"))])
    ),
    planner_output(Plan, Output).

always_structurally_invalid_planner(_, ok(Output)) :-
    bump_count(planner_call_count, _),
    Plan = plan([model(openrouter,
                       literal("MUST_NOT_EXECUTE"),
                       _{},
                       forbidden),
                  final(literal("first-final")),
                  final(literal("second-final"))]),
    planner_output(Plan, Output).

capability_denied_then_valid_planner(_, ok(Output)) :-
    bump_count(planner_call_count, Call),
    (   Call =:= 1
    ->  Plan = plan([model(openrouter,
                        literal("MUST_NOT_EXECUTE"),
                        _{},
                        forbidden),
                   final(literal("denied"))])
    ;   Plan = plan([final(literal("MUST_NOT_REPAIR_POLICY"))])
    ),
    planner_output(Plan, Output).

invalid_direct_then_direct_planner(Request, ok(Response)) :-
    bump_count(planner_call_count, Call),
    assertz(planner_request(Call, Request)),
    (   Call =:= 1
    ->  fake_retry_response(
            "UNIQUE_REJECTED_CANDIDATE {\"mode\":\"direct\",\"answer\":\"\"}",
            Response)
    ;   fake_retry_response(
            "{\"mode\":\"direct\",\"answer\":\"direct-after-repair\"}",
            Response)
    ).

envelope_hop_then_valid_planner(Request, ok(Output)) :-
    bump_count(planner_call_count, Call),
    assertz(planner_request(Call, Request)),
    (   Call =:= 1
    ->  Plan = plan([tool(retry_evidence, literal(_{}), evidence),
                     final(field(var(evidence), content))])
    ;   Plan = plan([tool(retry_evidence, literal(_{}), evidence),
                     final(field(field(var(evidence), value), content))])
    ),
    planner_output(Plan, Output).

retry_evidence_schema(
    tool_schema{
        name:retry_evidence,
        description:"Bind one fixed evidence object for retry fixtures",
        capability:tool(retry_evidence),
        effect:read,
        arguments:_{type:object, additional_properties:false, properties:_{}} ,
        result:_{type:object},
        limits:tool_limits{time_limit:1.0, max_output_bytes:4096}
    }).

retry_evidence(_, _{content:"ENVELOPE_VALUE_OK"}).

direct_value(_, _{content:"DIRECT_FIELD_OK"}).

direct_tool_field_planner(_, ok(Output)) :-
    bump_count(planner_call_count, _),
    Plan = plan([tool(direct_value, literal(_{}), evidence),
                 final(field(var(evidence), content))]),
    planner_output(Plan, Output).

fake_retry_response(Text,
                    model_response{provider:fake,
                                   requested_model:fake,
                                   selected_model:fake,
                                   text:Text,
                                   reasoning:"",
                                   tool_calls:[],
                                   finish_reason:stop,
                                   usage:usage{present:true,
                                               prompt_tokens:1,
                                               completion_tokens:1,
                                               total_tokens:2,
                                               cost:0.0},
                                   metadata:metadata{http_status:200,
                                                     response_received:true}}).

must_not_execute_model(_, ok(_)) :-
    bump_count(model_call_count, _),
    throw(error(invalid_candidate_executed,
                context(rlm_completion_planner_validation_retry_test,
                        'invalid planner candidate executed'))).

retry_options(Planner, Capabilities, Options) :-
    Options = [ planner_handler(Planner),
                model_handler(plunit_rlm_completion_planner_validation_retry:must_not_execute_model),
                planner_attempts(2),
                skill_mode(off),
                capabilities(Capabilities),
                child_capabilities([])
              ].

test(structural_validation_failure_uses_configured_retry,
     [setup(reset_retry_fixture)]) :-
    retry_options(
        plunit_rlm_completion_planner_validation_retry:structurally_invalid_then_valid_planner,
        [model(openrouter)],
        Options),
    rlm_completion("recover a structurally invalid planner candidate",
                   text("opaque context"),
                   Options,
                   Outcome),
    Outcome = ok(Completion),
    assertion(Completion.value == "recovered"),
    assertion(Completion.usage.model_calls =:= 2),
    assertion(Completion.usage.total_tokens =:= 4),
    planner_call_count(PlannerCalls),
    model_call_count(ModelCalls),
    assertion(PlannerCalls =:= 2),
    assertion(ModelCalls =:= 0),
    planner_request(1, FirstRequest),
    planner_request(2, SecondRequest),
    append(FirstRequest.messages, [Repair], SecondRequest.messages),
    assertion(Repair.role == user),
    assertion(sub_string(Repair.content, _, _, _,
                         "final_must_be_unique_and_last")).

test(structural_validation_retry_exhaustion_is_explicit_and_accounted,
     [setup(reset_retry_fixture)]) :-
    retry_options(
        plunit_rlm_completion_planner_validation_retry:always_structurally_invalid_planner,
        [model(openrouter)],
        Options),
    rlm_completion("exhaust structurally invalid planner candidates",
                   text("opaque context"),
                   Options,
                   Outcome),
    Outcome = error(Error),
    assertion(Error.phase == planner),
    assertion(Error.kind == plan_validation_failed),
    assertion(Error.attempts =:= 2),
    assertion(Error.usage.model_calls =:= 2),
    assertion(Error.usage.total_tokens =:= 4),
    assertion(Error.cause.phase == validate),
    assertion(Error.cause.kind == invalid_plan),
    assertion(Error.cause.detail == final_must_be_unique_and_last),
    planner_call_count(PlannerCalls),
    model_call_count(ModelCalls),
    assertion(PlannerCalls =:= 2),
    assertion(ModelCalls =:= 0).

test(capability_denial_is_not_a_planner_repair_signal,
     [setup(reset_retry_fixture)]) :-
    retry_options(
        plunit_rlm_completion_planner_validation_retry:capability_denied_then_valid_planner,
        [],
        Options),
    rlm_completion("do not repair around host capability denial",
                   text("opaque context"),
                   Options,
                   Outcome),
    Outcome = error(Error),
    assertion(Error.phase == validate),
    assertion(Error.kind == capability_denied),
    assertion(Error.capability == model(openrouter)),
    planner_call_count(PlannerCalls),
    model_call_count(ModelCalls),
    assertion(PlannerCalls =:= 1),
    assertion(ModelCalls =:= 0).

test(invalid_direct_envelope_repairs_to_direct_with_both_forms,
     [setup(reset_retry_fixture)]) :-
    retry_options(
        plunit_rlm_completion_planner_validation_retry:invalid_direct_then_direct_planner,
        [model(openrouter)],
        Options),
    rlm_completion("repair an invalid direct root decision",
                   text("opaque context"),
                   Options,
                   Outcome),
    Outcome = ok(Completion),
    assertion(Completion.value == "direct-after-repair"),
    assertion(Completion.plan == none),
    assertion(Completion.usage.model_calls =:= 2),
    planner_call_count(PlannerCalls),
    model_call_count(ModelCalls),
    assertion(PlannerCalls =:= 2),
    assertion(ModelCalls =:= 0),
    planner_request(1, FirstRequest),
    planner_request(2, SecondRequest),
    append(FirstRequest.messages, [Repair], SecondRequest.messages),
    assertion(Repair.role == user),
    assertion(sub_string(Repair.content, _, _, _,
                         "Previous planner candidate was rejected")),
    assertion(sub_string(Repair.content, _, _, _, "invalid_root_decision")),
    assertion(sub_string(Repair.content, _, _, _,
                         "direct_answer_must_be_nonempty_text")),
    assertion(sub_string(Repair.content, _, _, _,
                         "{\"mode\":\"direct\"")),
    assertion(sub_string(Repair.content, _, _, _,
                         "{\"steps\":[...]}")),
    assertion(\+ sub_string(Repair.content, _, _, _,
                            "UNIQUE_REJECTED_CANDIDATE")),
    string_length(Repair.content, Length),
    assertion(Length =< 1024).

test(tool_envelope_field_hop_is_repairable_without_execution,
     [setup(reset_retry_fixture)]) :-
    tool_registry_create(Registry),
    setup_call_cleanup(
        ( retry_evidence_schema(Schema),
          tool_register(Registry,
                        Schema,
                        plunit_rlm_completion_planner_validation_retry:retry_evidence,
                        ok(_))
        ),
        ( retry_options(
              plunit_rlm_completion_planner_validation_retry:envelope_hop_then_valid_planner,
              [tool(retry_evidence)],
              Base),
          append([tool_registry(Registry)], Base, Options),
          rlm_completion("compose a registry tool result field correctly",
                         text("opaque context"),
                         Options,
                         Outcome),
          Outcome = ok(Completion),
          assertion(Completion.value == "ENVELOPE_VALUE_OK"),
          assertion(Completion.plan \== none),
          assertion(Completion.usage.model_calls =:= 2),
          planner_call_count(PlannerCalls),
          model_call_count(ModelCalls),
          assertion(PlannerCalls =:= 2),
          assertion(ModelCalls =:= 0),
          planner_request(1, FirstRequest),
          planner_request(2, SecondRequest),
          append(FirstRequest.messages, [Repair], SecondRequest.messages),
          assertion(sub_string(Repair.content, _, _, _,
                               "tool_result_envelope_field(content,evidence)"))
        ),
        tool_registry_destroy(Registry)).

test(direct_host_tools_are_exempt_from_envelope_field_rule,
     [setup(reset_retry_fixture)]) :-
    Direct = [ planner_handler(
                   plunit_rlm_completion_planner_validation_retry:direct_tool_field_planner),
               planner_attempts(1),
               skill_mode(off),
               capabilities([tool(direct_value)]),
               child_capabilities([]),
               tools([tool(direct_value,
                           plunit_rlm_completion_planner_validation_retry:direct_value)])
             ],
    rlm_completion("compose a direct host tool result field",
                   text("opaque context"),
                   Direct,
                   Outcome),
    Outcome = ok(Completion),
    assertion(Completion.value == "DIRECT_FIELD_OK").

:- end_tests(rlm_completion_planner_validation_retry).
