:- begin_tests(live_rlm_operator_behavior_openrouter).

:- use_module('../../prolog/rlm_completion').
:- use_module('../../prolog/rlm_tool').

behavior_tool_schema(
    tool_schema{
        name:behavior_lookup,
        description:"Return the authoritative opaque code for the live RLM operator behavior acceptance fixture.",
        capability:tool(behavior_lookup),
        effect:read,
        arguments:_{type:object,
                    properties:_{},
                    required:[],
                    additional_properties:false},
        result:_{type:string},
        limits:_{time_limit:1.0,
                 max_output_bytes:1024}
    }).

behavior_tool_handler(_, "RLM_BEHAVIOR_TOOL_EVIDENCE_183").

register_behavior_tool(Registry) :-
    behavior_tool_schema(Schema),
    tool_register(Registry,
                  Schema,
                  plunit_live_rlm_operator_behavior_openrouter:behavior_tool_handler,
                  Outcome),
    (   Outcome = ok(_)
    ->  true
    ;   Outcome = error(Error),
        throw(error(live_behavior_tool_registration_failure(Error),
                    context(live_rlm_operator_behavior_openrouter_test,
                            'behavior tool registration failed')))
    ).

live_behavior_budget(
    _{max_iterations:12,
      max_recursion_depth:1,
      max_concurrent_subcalls:1,
      max_model_calls:6,
      max_tool_calls:2,
      max_context_ops:2,
      max_total_tokens:12000,
      max_cost_usd:0.25,
      max_output_bytes:32768,
      time_limit:150.0}).

live_behavior_common_options(Capabilities, ChildCapabilities, Extra, Options) :-
    live_behavior_budget(Budget),
    append([ capabilities(Capabilities),
             child_capabilities(ChildCapabilities),
             planner_attempts(2),
             planner_max_tokens(2600),
             context_options([max_bytes(4096), time_limit(1.0)]),
             budget(Budget)
           ],
           Extra,
           Options).

require_live_behavior_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '', Key \== ""
    ->  true
    ;   throw(error(missing_live_credential('OPENROUTER_API_KEY'),
                    context(live_rlm_operator_behavior_openrouter_test,
                            'OPENROUTER_API_KEY is not configured for live behavior CI')))
    ).

require_live_behavior_success(ok(Result), Result) :- !.
require_live_behavior_success(error(Error), _) :-
    throw(error(live_rlm_operator_behavior_failure(Error),
                context(live_rlm_operator_behavior_openrouter_test,
                        'live RLM operator behavior case failed'))).

transition_operation(Result, Operation) :-
    member(Transition, Result.transitions),
    Transition.operation = Operation,
    Transition.status == ok.

result_value_contains(Result, Needle) :-
    term_string(Result.value, Text, [quoted(false)]),
    sub_string(Text, _, _, _, Needle).

test(trivial_task_does_not_recurse_without_spoon_fed_plan) :-
    require_live_behavior_credential,
    live_behavior_common_options([rlm, model(openrouter)],
                                 [model(openrouter)],
                                 [],
                                 Options),
    rlm_completion(
        "Return the literal string RLM_TRIVIAL_OK. No external information or decomposition is needed. Choose the appropriate bounded runtime plan yourself.",
        text("irrelevant opaque context"),
        Options,
        Outcome),
    require_live_behavior_success(Outcome, Result),
    assertion(Result.value == "RLM_TRIVIAL_OK"),
    assertion(Result.recursion.recursive_calls =:= 0),
    assertion(\+ transition_operation(Result, rlm)),
    format('operator_behavior_trivial_no_recursion: true~n', []).

test(unknown_information_uses_available_typed_tool_without_spoon_fed_plan) :-
    require_live_behavior_credential,
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_behavior_tool(Registry),
        ( live_behavior_common_options(
              [tool(behavior_lookup)],
              [],
              [tool_registry(Registry)],
              Options),
          rlm_completion(
              "The answer is not present in the prompt or context. The available behavior_lookup tool is the authoritative source. Return the exact code it provides. Choose the runtime plan yourself.",
              text("No authoritative code is stored here."),
              Options,
              Outcome),
          require_live_behavior_success(Outcome, Result),
          assertion(transition_operation(Result, tool(behavior_lookup))),
          assertion(is_dict(Result.value, tool_result)),
          assertion(Result.value.status == ok),
          assertion(Result.value.value == "RLM_BEHAVIOR_TOOL_EVIDENCE_183"),
          format('operator_behavior_typed_tool_used: true~n', [])
        ),
        tool_registry_destroy(Registry)).

test(decomposable_task_chooses_bounded_recursion_without_spoon_fed_plan) :-
    require_live_behavior_credential,
    Context = terms([
        "evidence_stream_alpha(code=RLM_EVID_ALPHA_7Q9X,confidence=high)",
        "evidence_stream_beta(code=RLM_EVID_BETA_4M2K,confidence=high)"
    ]),
    live_behavior_common_options(
        [rlm, context(peek), model(openrouter)],
        [context(peek), model(openrouter)],
        [],
        Options),
    rlm_completion(
        "The opaque context contains exactly two independent evidence records. Investigate each record as a separate subproblem before synthesizing them. Produce one concise synthesis that reports the exact code from each evidence stream and distinguishes the streams. Choose the appropriate bounded runtime strategy yourself and combine only evidence you actually obtain.",
        Context,
        Options,
        Outcome),
    require_live_behavior_success(Outcome, Result),
    assertion(Result.recursion.recursive_calls >= 1),
    assertion(Result.recursion.max_depth >= 1),
    assertion(transition_operation(Result, rlm)),
    assertion(Result.usage.model_calls >= 2),
    assertion(Result.usage.model_calls =< 6),
    assertion(result_value_contains(Result, "RLM_EVID_ALPHA_7Q9X")),
    assertion(result_value_contains(Result, "RLM_EVID_BETA_4M2K")),
    format('operator_behavior_decomposable_recursion_used: true~n', []).

:- end_tests(live_rlm_operator_behavior_openrouter).
