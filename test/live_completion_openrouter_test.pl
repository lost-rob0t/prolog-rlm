:- begin_tests(live_completion_openrouter).

:- use_module('../prolog/rlm_completion').
:- use_module('../prolog/rlm_tool').

test(real_openrouter_root_tool_context_and_depth_one_child) :-
    require_live_completion_credential,
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_live_completion_tool(Registry),
        run_live_completion_case(Registry),
        tool_registry_destroy(Registry)).

register_live_completion_tool(Registry) :-
    register_project_read_tool(Registry,
                               '.',
                               [max_file_bytes(2048), time_limit(1.0)],
                               Outcome),
    (   Outcome = ok(_)
    ->  true
    ;   Outcome = error(Error),
        throw(error(live_completion_tool_registration_failure(Error),
                    context(live_completion_openrouter_test,
                            'project_read registration failed')))
    ).

run_live_completion_case(Registry) :-
    Context = text("You are the depth-one recursive child model. Reply briefly with the token RLM_CHILD_OK. This instruction was obtained from an opaque external context handle."),
    live_completion_instruction(Instruction),
    Options = [ capabilities([rlm,
                              context(slice),
                              tool(project_read),
                              model(openrouter)]),
                child_capabilities([model(openrouter)]),
                tool_registry(Registry),
                planner_instruction(Instruction),
                planner_attempts(2),
                planner_max_tokens(1400),
                context_options([max_bytes(2048), time_limit(1.0)]),
                budget(_{max_iterations:12,
                         max_recursion_depth:1,
                         max_concurrent_subcalls:1,
                         max_model_calls:4,
                         max_tool_calls:1,
                         max_context_ops:1,
                         max_total_tokens:12000,
                         max_cost_usd:0.25,
                         max_output_bytes:32768,
                         time_limit:150.0})
              ],
    rlm_completion("Execute the required depth-one RLM acceptance plan.",
                   Context,
                   Options,
                   Outcome),
    require_live_completion_success(Outcome, Result),
    validate_live_completion(Result),
    log_live_completion_evidence(Result).

live_completion_instruction(
"For this CI acceptance case you MUST return exactly this plan shape, changing nothing except JSON whitespace.\n\
1. Slice the opaque context input from start 0 for length 180 and bind it as snippet.\n\
2. Invoke project_read on test/fixtures/tool-readable.txt and bind it as file.\n\
3. Execute exactly one rlm child plan. The child plan must call provider openrouter with prompt snippet, max_tokens 128, bind child_response, then final child_response. Bind the rlm result as child.\n\
4. Final child.\n\
Return ONLY this JSON object:\n\
{\"steps\":[\
{\"op\":\"context\",\"handle\":{\"ref\":\"input\",\"name\":\"context\"},\"action\":{\"type\":\"slice\",\"start\":0,\"length\":180},\"bind\":\"snippet\"},\
{\"op\":\"tool\",\"name\":\"project_read\",\"args\":{\"path\":\"test/fixtures/tool-readable.txt\"},\"bind\":\"file\"},\
{\"op\":\"rlm\",\"plan\":{\"steps\":[\
{\"op\":\"model\",\"provider\":\"openrouter\",\"prompt\":{\"ref\":\"var\",\"name\":\"snippet\"},\"options\":{\"max_tokens\":128},\"bind\":\"child_response\"},\
{\"op\":\"final\",\"value\":{\"ref\":\"var\",\"name\":\"child_response\"}}]},\"bind\":\"child\"},\
{\"op\":\"final\",\"value\":{\"ref\":\"var\",\"name\":\"child\"}}]}" ).

require_live_completion_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '', Key \== ""
    ->  true
    ;   throw(error(missing_live_credential('OPENROUTER_API_KEY'),
                    context(live_completion_openrouter_test,
                            'OPENROUTER_API_KEY is not configured for live completion CI')))
    ).

require_live_completion_success(ok(Result), Result) :- !.
require_live_completion_success(error(Error), _) :-
    throw(error(live_completion_failure(Error),
                context(live_completion_openrouter_test,
                        'real recursive completion failed'))).

validate_live_completion(Result) :-
    assertion(Result.recursion.max_depth =:= 1),
    assertion(Result.recursion.recursive_calls =:= 1),
    assertion(Result.child_capabilities == [model(openrouter)]),
    get_dict(file, Result.vars, FileEnvelope),
    assertion(FileEnvelope.authorization == allowed),
    assertion(FileEnvelope.status == ok),
    assertion(sub_string(FileEnvelope.value.content,
                         _, _, _, "PROLOG_RLM_TOOL_OK")),
    get_dict(child, Result.vars, ChildResponse),
    assertion(ChildResponse.metadata.http_status =:= 200),
    assertion(ChildResponse.metadata.response_received == true),
    assertion(Result.usage.model_calls >= 2),
    assertion(member(plan_transition{operation:context(slice),
                                     status:ok,
                                     bind:snippet,
                                     sequence:_},
                     Result.transitions)),
    assertion(member(plan_transition{operation:tool(project_read),
                                     status:ok,
                                     bind:file,
                                     sequence:_},
                     Result.transitions)),
    assertion(member(plan_transition{operation:model(openrouter),
                                     status:ok,
                                     bind:child_response,
                                     sequence:_},
                     Result.transitions)),
    assertion(member(plan_transition{operation:rlm,
                                     status:ok,
                                     bind:child,
                                     sequence:_},
                     Result.transitions)).

log_live_completion_evidence(Result) :-
    get_dict(file, Result.vars, FileEnvelope),
    get_dict(child, Result.vars, ChildResponse),
    format('completion_provider: openrouter~n', []),
    format('completion_root_http_status: ~d~n',
           [Result.trajectory.root_event.http_status]),
    format('completion_plan_parsed: true~n', []),
    format('completion_context_executed: true~n', []),
    format('completion_tool_executed: true~n', []),
    format('completion_tool_authorization: ~w~n',
           [FileEnvelope.authorization]),
    format('completion_tool_status: ~w~n', [FileEnvelope.status]),
    format('completion_recursive_model_http_status: ~d~n',
           [ChildResponse.metadata.http_status]),
    format('completion_recursive_depth: ~d~n',
           [Result.recursion.max_depth]),
    format('completion_recursive_calls: ~d~n',
           [Result.recursion.recursive_calls]),
    format('completion_total_model_calls: ~d~n',
           [Result.usage.model_calls]),
    format('completion_file_token_seen: true~n', []),
    format('completion_final_ok: true~n', []).

:- end_tests(live_completion_openrouter).
