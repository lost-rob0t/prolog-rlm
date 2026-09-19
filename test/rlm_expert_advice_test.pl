:- begin_tests(rlm_expert_advice).

:- use_module('../prolog/rlm_expert_advice').
:- use_module('../prolog/rlm_expert').
:- use_module('../prolog/rlm_reasoning_mode').
:- use_module('../prolog/rlm_tool').
:- use_module('support/tool_test_support').

setup_registry(Registry) :-
    tool_registry_create(Registry),
    git_expert_contract(Git),
    web_expert_contract(Web),
    expert_register(
        Registry,
        Git,
        tool_test_support:echo_tool,
        ok(_)
    ),
    expert_register(
        Registry,
        Web,
        tool_test_support:echo_tool,
        ok(_)
    ),
    unrelated_tool_schema(Unrelated),
    tool_register(
        Registry,
        Unrelated,
        tool_test_support:echo_tool,
        ok(_)
    ).

cleanup_registry(Registry) :-
    tool_registry_destroy(Registry).

git_expert_contract(
    expert_contract{
        id:git_diff,
        version:1,
        goal:review,
        priority:100,
        description:"Review and inspect git diff changes in a repository",
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
        limits:_{
            time_limit:1.0,
            max_output_bytes:2048,
            inferences:10000
        }
    }).

web_expert_contract(
    expert_contract{
        id:web_search,
        version:1,
        goal:research,
        priority:50,
        description:"Search public web pages for current information",
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
        limits:_{
            time_limit:1.0,
            max_output_bytes:2048,
            inferences:10000
        }
    }).

unrelated_tool_schema(
    tool_schema{
        name:plain_tool,
        description:"Review git diff with a plain non-expert helper",
        capability:tool(plain_tool),
        effect:read,
        arguments:_{
            type:object,
            required:[],
            additional_properties:false,
            properties:_{}
        },
        result:_{type:any},
        limits:_{time_limit:1.0, max_output_bytes:2048}
    }).

full_context(
    expert_context{
        capabilities:[tool(git_diff), tool(web_search), tool(plain_tool)]
    }).

test(candidate_projection_contains_only_registered_experts) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( expert_tool_candidates(Registry, ok(Candidates)),
          assertion(length(Candidates, 2)),
          member(Git, Candidates),
          Git.name == git_diff,
          assertion(Git.id == expert(git_diff)),
          assertion(Git.goal == review),
          assertion(Git.required_capability == tool(git_diff)),
          assertion(Git.source == expert_registry),
          assertion(Git.effect == read),
          assertion(\+ get_dict(handler, Git, _)),
          assertion(is_dict(Git.schema, tool_schema)),
          assertion(\+ (member(C, Candidates), C.name == plain_tool))
        ),
        cleanup_registry(Registry)).

test(deterministic_query_selects_relevant_expert_then_canonical_goal_selection) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( full_context(Context),
          expert_tool_select(
              Registry,
              "review the git diff before merge",
              Context,
              ok(Selection)),
          assertion(Selection.applicable == true),
          assertion(Selection.candidate.name == git_diff),
          assertion(Selection.candidate.id == expert(git_diff)),
          assertion(Selection.candidate.goal == review),
          assertion(Selection.decision.reason == goal_and_capability),
          assertion(Selection.source == expert_registry),
          assertion(Selection.query_score > 0)
        ),
        cleanup_registry(Registry)).

test(unrelated_query_yields_no_applicable_expert) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( full_context(Context),
          expert_tool_select(
              Registry,
              "calculate orbital mechanics",
              Context,
              ok(Selection)),
          assertion(Selection.applicable == false),
          assertion(Selection.candidate == none)
        ),
        cleanup_registry(Registry)).

test(missing_expert_capability_prevents_applicability) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( Context = expert_context{capabilities:[tool(web_search)]},
          expert_tool_select(
              Registry,
              "review git diff",
              Context,
              ok(Selection)),
          assertion(Selection.applicable == false)
        ),
        cleanup_registry(Registry)).

test(expert_selection_projects_auto_mode_signal) :-
    setup_call_cleanup(
        setup_registry(Registry),
        setup_call_cleanup(
            reasoning_mode_open(expert_mode_fixture, ok(_)),
            ( full_context(Context),
              expert_tool_select(
                  Registry,
                  "review git diff",
                  Context,
                  ok(Selection)),
              expert_mode_signal(Selection, Signal),
              assertion(Signal.expert_applicable == true),
              assertion(ground(Signal)),
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

test(expert_auto_route_selects_symbolic) :-
    setup_call_cleanup(
        setup_registry(Registry),
        setup_call_cleanup(
            reasoning_mode_open(auto_route_symbolic, ok(_)),
            ( full_context(Context),
              expert_auto_route(
                  auto_route_symbolic,
                  Registry,
                  "review git diff",
                  Context,
                  _{},
                  ok(Route)),
              assertion(Route.selection.applicable == true),
              assertion(Route.mode.effective == symbolic),
              assertion(Route.mode.reason == expert_applicable),
              assertion(Route.signals.expert_applicable == true)
            ),
            reasoning_mode_destroy(auto_route_symbolic, _)
        ),
        cleanup_registry(Registry)).

test(expert_auto_route_selects_symbolic_recursive_when_trusted_signals_allow) :-
    setup_call_cleanup(
        setup_registry(Registry),
        setup_call_cleanup(
            reasoning_mode_open(auto_route_recursive, ok(_)),
            ( full_context(Context),
              expert_auto_route(
                  auto_route_recursive,
                  Registry,
                  "review git diff",
                  Context,
                  _{decomposable:true, recursion_allowed:true},
                  ok(Route)),
              assertion(Route.mode.effective == 'symbolic-recursive'),
              assertion(Route.mode.reason == expert_decomposition),
              assertion(Route.signals.expert_applicable == true)
            ),
            reasoning_mode_destroy(auto_route_recursive, _)
        ),
        cleanup_registry(Registry)).

test(expert_auto_route_without_expert_falls_back_direct) :-
    setup_call_cleanup(
        setup_registry(Registry),
        setup_call_cleanup(
            reasoning_mode_open(auto_route_direct, ok(_)),
            ( full_context(Context),
              expert_auto_route(
                  auto_route_direct,
                  Registry,
                  "calculate orbital mechanics",
                  Context,
                  _{},
                  ok(Route)),
              assertion(Route.selection.applicable == false),
              assertion(Route.mode.effective == direct),
              assertion(Route.mode.reason == flexible_default),
              assertion(Route.signals.expert_applicable == false)
            ),
            reasoning_mode_destroy(auto_route_direct, _)
        ),
        cleanup_registry(Registry)).

test(expert_auto_route_cannot_spoof_expert_signal) :-
    setup_call_cleanup(
        setup_registry(Registry),
        setup_call_cleanup(
            reasoning_mode_open(auto_route_spoof, ok(_)),
            ( full_context(Context),
              expert_auto_route(
                  auto_route_spoof,
                  Registry,
                  "review git diff",
                  Context,
                  _{expert_applicable:false},
                  error(Error)),
              assertion(Error.kind == invalid_route_signals)
            ),
            reasoning_mode_destroy(auto_route_spoof, _)
        ),
        cleanup_registry(Registry)).

test(advice_is_closed_bounded_inert_data) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( full_context(Context),
          expert_tool_select(
              Registry,
              "review git diff",
              Context,
              ok(Selection)),
          expert_advice_build(
              Selection,
              ["git repository is dirty", "review required"],
              ok(Advice)),
          assertion(Advice.expert == expert(git_diff)),
          assertion(Advice.expert_goal == review),
          assertion(Advice.recommendation == recommend_tool(git_diff)),
          assertion(Advice.stop_condition == one_model_step),
          assertion(Advice.source == expert_registry),
          assertion(Advice.evidence ==
                    ["git repository is dirty", "review required"]),
          assertion(\+ get_dict(handler, Advice, _))
        ),
        cleanup_registry(Registry)).

test(advice_request_exposes_only_selected_expert_tool_schema) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( full_context(Context),
          expert_tool_select(
              Registry,
              "review git diff",
              Context,
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
          assertion(\+ sub_string(System.content, _, _, _, "web_search")),
          assertion(\+ sub_string(System.content, _, _, _, "plain_tool"))
        ),
        cleanup_registry(Registry)).

test(advice_does_not_grant_expert_tool_capability) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( full_context(Context),
          expert_tool_select(
              Registry,
              "review git diff",
              Context,
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

test(selection_context_rejects_authority_smuggling) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( expert_tool_select(
              Registry,
              "review git diff",
              expert_context{
                  capabilities:[tool(git_diff)],
                  authority:dangerous
              },
              error(Error)),
          assertion(Error.kind == invalid_context)
        ),
        cleanup_registry(Registry)).

test(expert_evidence_is_bounded) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( full_context(Context),
          expert_tool_select(
              Registry,
              "review git diff",
              Context,
              ok(Selection)),
          length(Evidence, 17),
          maplist(=("x"), Evidence),
          expert_advice_build(Selection, Evidence, error(Error)),
          assertion(Error.kind == invalid_evidence)
        ),
        cleanup_registry(Registry)).

:- end_tests(rlm_expert_advice).
