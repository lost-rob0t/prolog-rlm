:- begin_tests(rlm_native_tool).

:- use_module('../prolog/rlm_native_tool').

test(normalizes_openai_function_call_to_closed_runtime_data) :-
    Wire = _{id:"call_123",
             type:"function",
             function:_{name:"weather_lookup",
                        arguments:"{\"city\":\"Oslo\"}"}},
    native_tool_call_normalize(Wire, ok(Call)),
    assertion(Call == native_tool_call{
                          id:"call_123",
                          name:weather_lookup,
                          arguments:json{city:"Oslo"},
                          type:function}).

test(rejects_malformed_call_id) :-
    Wire = _{id:"bad id",
             type:"function",
             function:_{name:"lookup",arguments:"{}"}},
    native_tool_call_normalize(Wire, error(Error)),
    assertion(Error.kind == malformed_call_id).

test(rejects_non_object_arguments) :-
    Wire = _{id:"call_1",
             type:"function",
             function:_{name:"lookup",arguments:"[]"}},
    native_tool_call_normalize(Wire, error(Error)),
    assertion(Error.kind == malformed_arguments).

test(rejects_duplicate_ids_before_returning_batch) :-
    Call = _{id:"call_1",
             type:"function",
             function:_{name:"lookup",arguments:"{}"}},
    native_tool_calls_normalize([Call,Call], error(Error)),
    assertion(Error.kind == duplicate_call_id),
    assertion(Error.call_id == "call_1").

test(classifies_attributable_argument_fault_without_weakening_strict_api) :-
    Good = _{id:"call_1",
             type:"function",
             function:_{name:"lookup",arguments:"{\"city\":\"Oslo\"}"}},
    BadArguments = "{\"city\":\"Oslo\",\"city\":\"Bergen\"}",
    Bad = _{id:"call_2",
            type:"function",
            function:_{name:"lookup",arguments:BadArguments}},
    native_tool_calls_normalize([Good, Bad], error(StrictError)),
    assertion(StrictError.kind == malformed_arguments),
    native_tool_calls_classify([Good, Bad], ok([GoodEntry, BadEntry])),
    assertion(GoodEntry.status == normalized),
    assertion(GoodEntry.call.arguments == json{city:"Oslo"}),
    BadEntry.status = fault(Cause),
    assertion(Cause.phase == normalize),
    assertion(Cause.kind == malformed_arguments),
    assertion(BadEntry.call == native_tool_call{id:"call_2",
                                                name:lookup,
                                                type:function}),
    assertion(BadEntry.arguments == BadArguments).

test(classified_faults_still_participate_in_duplicate_id_rejection) :-
    Good = _{id:"call_1",
             type:"function",
             function:_{name:"lookup",arguments:"{}"}},
    Bad = _{id:"call_1",
            type:"function",
            function:_{name:"lookup",
                       arguments:"{\"x\":1,\"x\":2}"}},
    native_tool_calls_classify([Good, Bad], error(Error)),
    assertion(Error.kind == duplicate_call_id),
    assertion(Error.call_id == "call_1").

test(classified_argument_faults_retain_payload_identity) :-
    First = _{id:"call_1",
              type:"function",
              function:_{name:"lookup",
                         arguments:"{\"x\":1,\"x\":2}"}},
    Second = _{id:"call_1",
               type:"function",
               function:_{name:"lookup",
                          arguments:"{\"x\":3,\"x\":4}"}},
    native_tool_calls_classify([First], ok([FirstEntry])),
    native_tool_calls_classify([Second], ok([SecondEntry])),
    assertion(FirstEntry \== SecondEntry).

test(classified_batch_keeps_malformed_envelopes_batch_fatal) :-
    Wire = _{id:"bad id",
             type:"function",
             function:_{name:"lookup",
                        arguments:"{\"x\":1,\"x\":2}"}},
    native_tool_calls_classify([Wire], error(Error)),
    assertion(Error.kind == malformed_call_id).

test(classified_batch_does_not_retain_non_wire_argument_terms) :-
    Wire = _{id:"call_1",
             type:"function",
             function:_{name:"lookup",arguments:call(host_predicate)}},
    native_tool_calls_classify([Wire], error(Error)),
    assertion(Error.kind == malformed_arguments).

test(rejects_unsupported_native_call_type) :-
    Wire = _{id:"call_1",
             type:"computer",
             function:_{name:"lookup",arguments:"{}"}},
    native_tool_call_normalize(Wire, error(Error)),
    assertion(Error.kind == unsupported_call_type).

test(result_message_preserves_exact_call_id) :-
    Call = native_tool_call{id:"call_1",
                            name:lookup,
                            arguments:json{},
                            type:function},
    Result = native_tool_result{call_id:"call_1",
                                name:lookup,
                                operation:tool(lookup),
                                value:json{answer:42},
                                truncated:false,
                                trace:json{status:ok}},
    native_tool_result_message(Call, Result, ok(Message)),
    assertion(Message.role == tool),
    assertion(Message.tool_call_id == "call_1"),
    assertion(Message.name == lookup),
    assertion(sub_string(Message.content, _, _, _, "\"answer\":42")).

test(result_message_rejects_call_id_mismatch) :-
    Call = native_tool_call{id:"call_1",
                            name:lookup,
                            arguments:json{},
                            type:function},
    Result = native_tool_result{call_id:"call_2",
                                name:lookup,
                                operation:tool(lookup),
                                value:json{},
                                truncated:false,
                                trace:json{}},
    native_tool_result_message(Call, Result, error(Error)),
    assertion(Error.kind == tool_result_id_mismatch).

test(registry_schema_renders_without_runtime_capability_or_effect_fields) :-
    Runtime = tool_schema{
                  name:weather_lookup,
                  description:"Look up bounded weather data",
                  capability:tool(weather_lookup),
                  effect:read,
                  arguments:_{type:object,
                              properties:_{days:_{type:integer,
                                                  minimum:1,
                                                  maximum:7}},
                              required:[days],
                              additional_properties:false},
                  result:_{type:any},
                  limits:tool_limits{time_limit:1.0,max_output_bytes:1024}},
    native_tool_schema_normalize(Runtime, ok(Native)),
    native_tool_schema_wire(openai_compatible, Native, ok(Wire)),
    assertion(Wire.type == "function"),
    assertion(Wire.function.name == "weather_lookup"),
    assertion(Wire.function.parameters.type == "object"),
    assertion(Wire.function.parameters.additionalProperties == false),
    assertion(\+ get_dict(capability, Wire.function, _)),
    assertion(\+ get_dict(effect, Wire.function, _)).

test(unsupported_wire_format_fails_closed) :-
    Native = native_tool_schema{name:lookup,
                                description:"lookup",
                                parameters:json{type:"object"},
                                source:registry,
                                capability:tool(lookup),
                                effect:read},
    native_tool_schema_wire(unsupported_provider, Native, error(Error)),
    assertion(Error.kind == unsupported_provider_tool_format).

:- end_tests(rlm_native_tool).
