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
    get_dict(messages, Request, [Message|_]),
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

:- end_tests(rlm_completion_tool_visibility).
