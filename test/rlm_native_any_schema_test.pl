:- begin_tests(rlm_native_any_schema).

:- use_module('../prolog/rlm_native_tool').

test(any_argument_property_projects_as_unconstrained_json_schema) :-
    Runtime = tool_schema{
                  name:mcp_test,
                  description:"Imported MCP schema with an unconstrained field",
                  capability:tool(mcp_test),
                  effect:read,
                  arguments:_{type:object,
                              properties:_{value:_{type:any}},
                              required:[],
                              additional_properties:true},
                  result:_{type:any},
                  limits:tool_limits{time_limit:1.0,max_output_bytes:1024}},
    native_tool_schema_normalize(Runtime, ok(Native)),
    native_tool_schema_wire(openai_compatible, Native, ok(Wire)),
    get_dict(value, Wire.function.parameters.properties, ValueSchema),
    assertion(is_dict(ValueSchema)),
    assertion(\+ get_dict(type, ValueSchema, _)).

:- end_tests(rlm_native_any_schema).
