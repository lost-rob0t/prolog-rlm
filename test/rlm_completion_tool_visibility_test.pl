:- begin_tests(rlm_completion_tool_visibility).

:- use_module('../prolog/rlm_completion').
:- use_module('../prolog/rlm_tool').
:- use_module('support/completion_test_support').

fixture_schema(Name, Description,
               tool_schema{
                   name:Name,
                   description:Description,
                   capability:tool(Name),
                   effect:read,
                   arguments:_{type:object,
                               properties:_{},
                               required:[],
                               additional_properties:false},
                   result:_{type:any},
                   limits:_{time_limit:1.0,
                            max_output_bytes:1024}
               }).

fixture_handler(_, ok).

register_fixture_tool(Registry, Name, Description) :-
    fixture_schema(Name, Description, Schema),
    tool_register(Registry,
                  Schema,
                  plunit_rlm_completion_tool_visibility:fixture_handler,
                  ok(_)).

planner_request_prompt(Request, Prompt) :-
    get_dict(messages, Request, Messages),
    member(Message, Messages),
    get_dict(role, Message, user),
    get_dict(content, Message, Prompt).

test(planner_sees_only_capability_allowed_registry_schemas,
     [setup(completion_test_support:reset_calls)]) :-
    tool_registry_create(Registry),
    setup_call_cleanup(
        ( register_fixture_tool(Registry,
                                allowed_research_tool,
                                "ALLOWED_SCHEMA_SENTINEL_191"),
          register_fixture_tool(Registry,
                                denied_admin_tool,
                                "DENIED_SCHEMA_SENTINEL_191")
        ),
        ( rlm_completion(
              "visibility test",
              text("opaque context"),
              [ planner_handler(completion_test_support:capture_planner),
                tool_registry(Registry),
                prompt_compile_mode(all_tools),
                capabilities([tool(allowed_research_tool)]),
                child_capabilities([])
              ],
              Outcome),
          assertion(Outcome = ok(_)),
          completion_test_support:last_planner_request(Request),
          planner_request_prompt(Request, Prompt),
          assertion(sub_string(Prompt, _, _, _,
                               "ALLOWED_SCHEMA_SENTINEL_191")),
          assertion(\+ sub_string(Prompt, _, _, _,
                                  "DENIED_SCHEMA_SENTINEL_191")),
          assertion(sub_string(Prompt, _, _, _,
                               "allowed_research_tool")),
          assertion(\+ sub_string(Prompt, _, _, _,
                                  "denied_admin_tool"))
        ),
        tool_registry_destroy(Registry)).

test(root_planner_uses_compiled_tool_projection,
     [setup(completion_test_support:reset_calls)]) :-
    tool_registry_create(Registry),
    setup_call_cleanup(
        ( register_fixture_tool(Registry,
                                weather_lookup,
                                "WEATHER_SCHEMA_SENTINEL_176"),
          register_fixture_tool(Registry,
                                unrelated_admin_export,
                                "UNRELATED_SCHEMA_SENTINEL_176")
        ),
        ( rlm_completion(
              "use weather_lookup for the weather lookup",
              text("opaque context"),
              [ planner_handler(completion_test_support:capture_planner),
                tool_registry(Registry),
                prompt_compile_mode(compiled),
                capabilities([tool(weather_lookup),
                              tool(unrelated_admin_export)]),
                child_capabilities([])
              ],
              CompletionOutcome),
          assertion(CompletionOutcome = ok(_)),
          completion_test_support:last_planner_request(Request),
          planner_request_prompt(Request, Prompt),
          assertion(sub_string(Prompt, _, _, _,
                               "WEATHER_SCHEMA_SENTINEL_176")),
          assertion(\+ sub_string(Prompt, _, _, _,
                                  "UNRELATED_SCHEMA_SENTINEL_176")),
          assertion(sub_string(Prompt, _, _, _,
                               "Active tool schemas:")),
          assertion(\+ sub_string(Prompt, _, _, _,
                                  "Registered tool schemas:"))
        ),
        tool_registry_destroy(Registry)).

test(all_tools_mode_preserves_compatibility_projection,
     [setup(completion_test_support:reset_calls)]) :-
    tool_registry_create(Registry),
    setup_call_cleanup(
        ( register_fixture_tool(Registry,
                                weather_lookup,
                                "WEATHER_SCHEMA_SENTINEL_ALL"),
          register_fixture_tool(Registry,
                                unrelated_admin_export,
                                "UNRELATED_SCHEMA_SENTINEL_ALL")
        ),
        ( rlm_completion(
              "query unrelated to either registered tool",
              text("opaque context"),
              [ planner_handler(completion_test_support:capture_planner),
                tool_registry(Registry),
                prompt_compile_mode(all_tools),
                capabilities([tool(weather_lookup),
                              tool(unrelated_admin_export)]),
                child_capabilities([])
              ],
              CompletionOutcome),
          assertion(CompletionOutcome = ok(_)),
          completion_test_support:last_planner_request(Request),
          planner_request_prompt(Request, Prompt),
          assertion(sub_string(Prompt, _, _, _,
                               "WEATHER_SCHEMA_SENTINEL_ALL")),
          assertion(sub_string(Prompt, _, _, _,
                               "UNRELATED_SCHEMA_SENTINEL_ALL"))
        ),
        tool_registry_destroy(Registry)).

test(invalid_prompt_compile_mode_fails_closed_before_planner,
     [setup(completion_test_support:reset_calls)]) :-
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_fixture_tool(Registry,
                              weather_lookup,
                              "WEATHER_SCHEMA_SENTINEL_176"),
        ( rlm_completion(
              "use weather_lookup",
              text("opaque context"),
              [ planner_handler(completion_test_support:capture_planner),
                tool_registry(Registry),
                prompt_compile_mode(garbage_mode),
                capabilities([tool(weather_lookup)]),
                child_capabilities([])
              ],
              CompletionOutcome),
          CompletionOutcome = error(Error),
          assertion(get_dict(kind, Error, invalid_prompt_compile_mode)),
          assertion(get_dict(mode, Error, garbage_mode)),
          completion_test_support:planner_calls(PlannerCalls),
          assertion(PlannerCalls =:= 0),
          assertion(\+ completion_test_support:last_planner_request(_))
        ),
        tool_registry_destroy(Registry)).

:- end_tests(rlm_completion_tool_visibility).
