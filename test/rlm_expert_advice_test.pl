:- begin_tests(rlm_expert_advice).

:- use_module('../prolog/rlm_expert_advice').
:- use_module('../prolog/rlm_reasoning_mode').
:- use_module('../prolog/rlm_tool').
:- use_module('support/tool_test_support').

setup_registry(Registry) :-
    tool_registry_create(Registry),
    git_diff_schema(GitSchema),
    web_search_schema(WebSchema),
    tool_register(Registry,
                  GitSchema,
                  tool_test_support:echo_tool,
                  ok(_)),
    tool_register(Registry,
                  WebSchema,
                  tool_test_support:echo_tool,
                  ok(_)).

cleanup_registry(Registry) :-
    tool_registry_destroy(Registry).

git_diff_schema(
    tool_schema{
        name:git_diff,
        description:"Review and inspect git diff changes in a repository",
        capability:tool(git_diff),
        effect:read,
        arguments:_{
            type:object,
            required:[],
            additional_properties:false,
            properties:_{}
        },
        result:_{
            type:object,
            required:[],
            additional_properties:true,
            properties:_{}
        },
        limits:_{time_limit:1.0, max_output_bytes:2048}
    }).

web_search_schema(
    tool_schema{
        name:web_search,
        description:"Search public web pages for current information",
        capability:tool(web_search),
        effect:read,
        arguments:_{
            type:object,
            required:[],
            additional_properties:false,
            properties:_{}
        },
        result:_{
            type:object,
            required:[],
            additional_properties:true,
            properties:_{}
        },
        limits:_{time_limit:1.0, max_output_bytes:2048}
    }).

test(candidate_projection_is_inert_and_handler_free) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( expert_tool_candidates(Registry, ok(Candidates)),
          assertion(length(Candidates, 2)),
          member(Git, Candidates),
          Git.name == git_diff,
          assertion(Git.id == tool(git_diff)),
          assertion(Git.required_capability == tool(git_diff)),
          assertion(Git.source == tool_registry),
          assertion(Git.effect == read),
          assertion(\+ get_dict(handler, Git, _)),
          assertion(is_dict(Git.schema, tool_schema))
        ),
        cleanup_registry(Registry)).

test(deterministic_query_selects_relevant_tool_expert) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( expert_tool_select(
              Registry,
              "review the git diff before merge",
              [],
              ok(Selection)),
          assertion(Selection.applicable == true),
          assertion(Selection.candidate.name == git_diff),
          assertion(Selection.candidate.id == tool(git_diff)),
          assertion(Selection.source == prompt_compiler),
          assertion(Selection.score > 0)
        ),
        cleanup_registry(Registry)).

test(unrelated_query_yields_no_applicable_expert) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( expert_tool_select(
              Registry,
              "calculate orbital mechanics",
              [],
              ok(Selection)),
          assertion(Selection.applicable == false),
          assertion(Selection.candidate == none)
        ),
        cleanup_registry(Registry)).

test(expert_selection_projects_auto_mode_signal) :-
    setup_call_cleanup(
        setup_registry(Registry),
        setup_call_cleanup(
            reasoning_mode_open(expert_mode_fixture, ok(_)),
            ( expert_tool_select(
                  Registry,
                  "review git diff",
                  [],
                  ok(Selection)),
              expert_mode_signal(Selection, Signal),
              assertion(Signal == _{expert_applicable:true}),
              reasoning_mode_select(
                  expert_mode_fixture,
                  Signal,
                  [],
                  ok(State)),
              assertion(State.effective == symbolic),
              assertion(State.reason == expert_applicable)
            ),
            reasoning_mode_destroy(expert_mode_fixture, _)
        ),
        cleanup_registry(Registry)).

test(advice_is_closed_bounded_inert_data) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( expert_tool_select(
              Registry,
              "review git diff",
              [],
              ok(Selection)),
          expert_advice_build(
              Selection,
              ["git repository is dirty", "review required"],
              ok(Advice)),
          assertion(Advice.expert == tool(git_diff)),
          assertion(Advice.recommendation == recommend_tool(git_diff)),
          assertion(Advice.stop_condition == one_model_step),
          assertion(Advice.source == tool_registry),
          assertion(Advice.evidence ==
                    ["git repository is dirty", "review required"]),
          assertion(\+ get_dict(handler, Advice, _))
        ),
        cleanup_registry(Registry)).

test(advice_request_exposes_only_selected_tool_schema) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( expert_tool_select(
              Registry,
              "review git diff",
              [],
              ok(Selection)),
          expert_advice_build(Selection, [], ok(Advice)),
          expert_advice_model_request(
              Advice,
              "Should I merge this change?",
              [max_tokens(96)],
              ok(Request)),
          assertion(Request = model_request{
                                  messages:[System, User],
                                  options:Options
                              }),
          assertion(System.role == system),
          assertion(User.role == user),
          assertion(User.content == "Should I merge this change?"),
          assertion(Options.max_tokens =:= 96),
          assertion(Options.temperature =:= 0),
          assertion(Options.tool_choice == auto),
          assertion(Options.tools = [Wire]),
          assertion(Wire.type == "function"),
          assertion(Wire.function.name == "git_diff"),
          assertion(\+ sub_string(System.content, _, _, _, "web_search"))
        ),
        cleanup_registry(Registry)).

test(advice_does_not_grant_tool_capability) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( expert_tool_select(
              Registry,
              "review git diff",
              [],
              ok(Selection)),
          Candidate = Selection.candidate,
          tool_invoke(
              Registry,
              [],
              Candidate.name,
              json{},
              [],
              error(Error),
              Trace),
          assertion(Error.kind == capability_denied),
          assertion(Trace.authorization == denied)
        ),
        cleanup_registry(Registry)).

test(expert_selection_options_reject_authority_smuggling) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( expert_tool_select(
              Registry,
              "review git diff",
              [capabilities([tool(git_diff)])],
              error(Error)),
          assertion(Error.kind == invalid_options)
        ),
        cleanup_registry(Registry)).

test(expert_evidence_is_bounded) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( expert_tool_select(
              Registry,
              "review git diff",
              [],
              ok(Selection)),
          length(Evidence, 17),
          maplist(=("x"), Evidence),
          expert_advice_build(Selection, Evidence, error(Error)),
          assertion(Error.kind == invalid_evidence)
        ),
        cleanup_registry(Registry)).

:- end_tests(rlm_expert_advice).
