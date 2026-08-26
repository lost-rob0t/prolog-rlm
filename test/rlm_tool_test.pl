:- begin_tests(rlm_tool).

:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_plan').
:- use_module('support/tool_test_support').

setup_registry(Registry) :-
    tool_registry_create(Registry).

cleanup_registry(Registry) :-
    tool_registry_destroy(Registry).

bounded_echo(Args, json{seen:Args.value}) :-
    tool_test_support:counting_tool(Args, _).

bounded_zero_result(Args, json{seen:0}) :-
    tool_test_support:counting_tool(Args, _).

test(capabilities_normalize_and_deduplicate) :-
    capabilities_normalize([tool(alpha), context(search), tool(alpha)],
                           ok(Caps)),
    assertion(memberchk(tool(alpha), Caps)),
    assertion(memberchk(context(search), Caps)),
    assertion(length(Caps, 2)).

test(child_capabilities_may_only_narrow) :-
    Parent = [tool(project_read), context(search), model(openrouter)],
    capabilities_narrow(Parent,
                        [tool(project_read), context(search)],
                        ok(Child)),
    assertion(memberchk(tool(project_read), Child)),
    assertion(\+ memberchk(model(openrouter), Child)).

test(child_capability_widening_is_denied) :-
    capabilities_narrow([tool(project_read)],
                        [tool(project_read), process(shell)],
                        error(Error)),
    assertion(Error.kind == widening_denied),
    assertion(memberchk(process(shell), Error.unauthorized)).

test(registry_discovery_exposes_schema_not_handler) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( counting_schema(Schema),
          tool_register(Registry, Schema,
                        tool_test_support:counting_tool,
                        ok(_)),
          tool_discover(Registry, Schemas),
          assertion(length(Schemas, 1)),
          Schemas = [Discovered],
          assertion(Discovered.name == counting),
          assertion(Discovered.capability == tool(counting)),
          assertion(Discovered.effect == read)
        ),
        cleanup_registry(Registry)).

test(allowed_project_read_succeeds_and_traces_authorization) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( register_project_read_tool(Registry, '.', [], ok(_)),
          tool_invoke(Registry,
                      [tool(project_read)],
                      project_read,
                      json{path:"test/fixtures/tool-readable.txt"},
                      [],
                      ok(Execution),
                      Trace),
          assertion(Trace.authorization == allowed),
          assertion(Trace.authority == approve_diff),
          assertion(Trace.status == ok),
          assertion(Execution.value.truncated == false),
          assertion(sub_string(Execution.value.content, _, _, _,
                               "PROLOG_RLM_TOOL_OK"))
        ),
        cleanup_registry(Registry)).

test(denied_tool_fails_before_handler_invocation) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( tool_test_support:reset_invocations,
          counting_schema(Schema),
          tool_register(Registry, Schema,
                        tool_test_support:counting_tool,
                        ok(_)),
          tool_invoke(Registry,
                      [],
                      counting,
                      json{value:7},
                      [],
                      error(Error),
                      Trace),
          tool_test_support:invocation_count(Count),
          assertion(Error.kind == capability_denied),
          assertion(Trace.authorization == denied),
          assertion(Count =:= 0)
        ),
        cleanup_registry(Registry)).

test(malformed_arguments_fail_schema_before_handler) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( tool_test_support:reset_invocations,
          counting_schema(Schema),
          tool_register(Registry, Schema,
                        tool_test_support:counting_tool,
                        ok(_)),
          tool_invoke(Registry,
                      [tool(counting)],
                      counting,
                      json{},
                      [],
                      error(Error),
                      Trace),
          tool_test_support:invocation_count(Count),
          assertion(Error.kind == schema_validation_failed),
          assertion(Trace.status == malformed_args),
          assertion(Count =:= 0)
        ),
        cleanup_registry(Registry)).

test(malformed_arguments_win_before_capability_denial) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( counting_schema(Schema),
          tool_register(Registry, Schema,
                        tool_test_support:counting_tool,
                        ok(_)),
          tool_invoke(Registry,
                      [],
                      counting,
                      json{},
                      [],
                      error(Error),
                      Trace),
          assertion(Error.kind == schema_validation_failed),
          assertion(Trace.status == malformed_args)
        ),
        cleanup_registry(Registry)).

test(exclusive_minimum_rejects_boundary_before_handler) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( tool_test_support:reset_invocations,
          numeric_argument_schema(bounded_number,
                                  _{type:number, exclusiveMinimum:0},
                                  Schema),
          tool_register(Registry, Schema,
                        plunit_rlm_tool:bounded_echo,
                        ok(_)),
          tool_invoke(Registry,
                      [tool(bounded_number)],
                      bounded_number,
                      json{value:0},
                      [],
                      error(Error),
                      Trace),
          tool_test_support:invocation_count(Count),
          assertion(Error.kind == schema_validation_failed),
          assertion(Error.detail ==
                    numeric_bound_violation(args-value,
                                            exclusiveMinimum,
                                            0,
                                            0)),
          assertion(Trace.status == malformed_args),
          assertion(Count =:= 0)
        ),
        cleanup_registry(Registry)).

test(exclusive_minimum_rejects_negative_before_handler) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( tool_test_support:reset_invocations,
          numeric_argument_schema(bounded_number_negative,
                                  _{type:number, exclusiveMinimum:0},
                                  Schema),
          tool_register(Registry, Schema,
                        plunit_rlm_tool:bounded_echo,
                        ok(_)),
          tool_invoke(Registry,
                      [tool(bounded_number_negative)],
                      bounded_number_negative,
                      json{value: -1},
                      [],
                      error(Error),
                      _Trace),
          tool_test_support:invocation_count(Count),
          assertion(Error.kind == schema_validation_failed),
          assertion(Count =:= 0)
        ),
        cleanup_registry(Registry)).

test(exclusive_minimum_accepts_positive_value) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( tool_test_support:reset_invocations,
          numeric_argument_schema(bounded_number_positive,
                                  _{type:number, exclusiveMinimum:0},
                                  Schema),
          tool_register(Registry, Schema,
                        plunit_rlm_tool:bounded_echo,
                        ok(_)),
          tool_invoke(Registry,
                      [tool(bounded_number_positive)],
                      bounded_number_positive,
                      json{value:1},
                      [],
                      ok(Execution),
                      Trace),
          tool_test_support:invocation_count(Count),
          assertion(Execution.value.seen =:= 1),
          assertion(Trace.status == ok),
          assertion(Count =:= 1)
        ),
        cleanup_registry(Registry)).

test(integer_minimum_and_maximum_are_enforced) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( tool_test_support:reset_invocations,
          numeric_argument_schema(bounded_integer,
                                  _{type:integer, minimum:1, maximum:32},
                                  Schema),
          tool_register(Registry, Schema,
                        plunit_rlm_tool:bounded_echo,
                        ok(_)),
          tool_invoke(Registry,
                      [tool(bounded_integer)],
                      bounded_integer,
                      json{value:0},
                      [],
                      error(LowError),
                      _),
          assertion(LowError.detail ==
                    numeric_bound_violation(args-value, minimum, 1, 0)),
          tool_invoke(Registry,
                      [tool(bounded_integer)],
                      bounded_integer,
                      json{value:33},
                      [],
                      error(HighError),
                      _),
          assertion(HighError.detail ==
                    numeric_bound_violation(args-value, maximum, 32, 33)),
          tool_invoke(Registry,
                      [tool(bounded_integer)],
                      bounded_integer,
                      json{value:32},
                      [],
                      ok(_),
                      _),
          tool_test_support:invocation_count(Count),
          assertion(Count =:= 1)
        ),
        cleanup_registry(Registry)).

test(exclusive_maximum_rejects_exact_boundary) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( tool_test_support:reset_invocations,
          numeric_argument_schema(exclusive_upper,
                                  _{type:number, exclusiveMaximum:10},
                                  Schema),
          tool_register(Registry, Schema,
                        plunit_rlm_tool:bounded_echo,
                        ok(_)),
          tool_invoke(Registry,
                      [tool(exclusive_upper)],
                      exclusive_upper,
                      json{value:10},
                      [],
                      error(Error),
                      _),
          assertion(Error.detail ==
                    numeric_bound_violation(args-value,
                                            exclusiveMaximum,
                                            10,
                                            10)),
          tool_test_support:invocation_count(Count),
          assertion(Count =:= 0)
        ),
        cleanup_registry(Registry)).

test(malformed_numeric_bound_is_rejected_at_registration) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( numeric_argument_schema(malformed_bound,
                                  _{type:number, minimum:"zero"},
                                  Schema),
          tool_register(Registry, Schema,
                        plunit_rlm_tool:bounded_echo,
                        error(Error)),
          assertion(Error.kind == invalid_tool_operation),
          assertion(Error.detail == invalid_numeric_bound(minimum, "zero"))
        ),
        cleanup_registry(Registry)).

test(contradictory_numeric_bounds_are_rejected_at_registration) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( numeric_argument_schema(empty_interval,
                                  _{type:number,
                                    exclusiveMinimum:10,
                                    maximum:10},
                                  Schema),
          tool_register(Registry, Schema,
                        plunit_rlm_tool:bounded_echo,
                        error(Error)),
          assertion(Error.kind == invalid_tool_operation),
          assertion(Error.detail ==
                    contradictory_numeric_bounds(exclusiveMinimum,
                                                 10,
                                                 maximum,
                                                 10))
        ),
        cleanup_registry(Registry)).

test(result_schema_enforces_numeric_bounds) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( tool_test_support:reset_invocations,
          numeric_result_schema(bounded_result, Schema),
          tool_register(Registry, Schema,
                        plunit_rlm_tool:bounded_zero_result,
                        ok(_)),
          tool_invoke(Registry,
                      [tool(bounded_result)],
                      bounded_result,
                      json{value:1},
                      [],
                      error(Error),
                      Trace),
          tool_test_support:invocation_count(Count),
          assertion(Error.kind == schema_validation_failed),
          assertion(Error.detail ==
                    numeric_bound_violation(result-seen,
                                            exclusiveMinimum,
                                            0,
                                            0)),
          assertion(Trace.status == invalid_result),
          assertion(Count =:= 1)
        ),
        cleanup_registry(Registry)).

test(tool_timeout_is_structured) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( slow_schema(Schema),
          tool_register(Registry, Schema,
                        tool_test_support:slow_tool,
                        ok(_)),
          tool_invoke(Registry,
                      [tool(slow)],
                      slow,
                      json{},
                      [],
                      error(Error),
                      Trace),
          assertion(Error.kind == timeout),
          assertion(Trace.status == timeout)
        ),
        cleanup_registry(Registry)).

test(oversized_tool_output_is_rejected) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( large_schema(Schema),
          tool_register(Registry, Schema,
                        tool_test_support:large_tool,
                        ok(_)),
          tool_invoke(Registry,
                      [tool(large)],
                      large,
                      json{},
                      [],
                      error(Error),
                      Trace),
          assertion(Error.kind == oversized_output),
          assertion(Trace.status == oversized_output),
          assertion(Trace.output_bytes > 32)
        ),
        cleanup_registry(Registry)).

test(project_read_rejects_parent_traversal_during_preflight) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( register_project_read_tool(Registry, '.', [], ok(_)),
          tool_invoke(Registry,
                      [tool(project_read)],
                      project_read,
                      json{path:"../README.md"},
                      [],
                      error(Error),
                      Trace),
          assertion(Error.kind == confinement_denied),
          assertion(Trace.status == confinement_denied)
        ),
        cleanup_registry(Registry)).

test(validated_plan_executes_registered_tool_and_records_transition) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( register_project_read_tool(Registry, '.', [], ok(_)),
          Caps = [tool(project_read)],
          tool_registry_runtime_tools(Registry, Caps, RuntimeTools),
          Plan = plan([
                     tool(project_read,
                          literal(json{path:"test/fixtures/tool-readable.txt"}),
                          file),
                     final(field(var(file), status))
                 ]),
          plan_run(Plan,
                   Caps,
                   [tools(RuntimeTools)],
                   _{},
                   ok(Result)),
          assertion(Result.value == ok),
          get_dict(file, Result.vars, Envelope),
          assertion(Envelope.authorization == allowed),
          assertion(Envelope.status == ok),
          assertion(sub_string(Envelope.value.content, _, _, _,
                               "PROLOG_RLM_TOOL_OK")),
          Result.transitions = [ToolTransition, FinalTransition],
          assertion(ToolTransition.operation == tool(project_read)),
          assertion(FinalTransition.operation == final)
        ),
        cleanup_registry(Registry)).

test(plan_capability_denial_occurs_before_registered_handler_invocation) :-
    setup_call_cleanup(
        setup_registry(Registry),
        ( tool_test_support:reset_invocations,
          counting_schema(Schema),
          tool_register(Registry, Schema,
                        tool_test_support:counting_tool,
                        ok(_)),
          tool_registry_runtime_tools(Registry, [], RuntimeTools),
          Plan = plan([
                     tool(counting, literal(json{value:1}), count),
                     final(var(count))
                 ]),
          plan_run(Plan, [], [tools(RuntimeTools)], _{}, error(Error)),
          tool_test_support:invocation_count(Count),
          assertion(Error.kind == capability_denied),
          assertion(Count =:= 0)
        ),
        cleanup_registry(Registry)).

counting_schema(
    tool_schema{name:counting,
                description:"counting test tool",
                capability:tool(counting),
                effect:read,
                arguments:_{type:object,
                            required:[value],
                            additional_properties:false,
                            properties:_{value:_{type:integer}}},
                result:_{type:object,
                         required:[seen],
                         additional_properties:false,
                         properties:_{seen:_{type:integer}}},
                limits:_{time_limit:1.0, max_output_bytes:1024}}).

numeric_argument_schema(Name, ValueSchema,
    tool_schema{name:Name,
                description:"numeric bound fixture",
                capability:tool(Name),
                effect:read,
                arguments:_{type:object,
                            required:[value],
                            additional_properties:false,
                            properties:_{value:ValueSchema}},
                result:_{type:object,
                         required:[seen],
                         additional_properties:false,
                         properties:_{seen:_{type:number}}},
                limits:_{time_limit:1.0, max_output_bytes:1024}}).

numeric_result_schema(Name,
    tool_schema{name:Name,
                description:"numeric result bound fixture",
                capability:tool(Name),
                effect:read,
                arguments:_{type:object,
                            required:[value],
                            additional_properties:false,
                            properties:_{value:_{type:number}}},
                result:_{type:object,
                         required:[seen],
                         additional_properties:false,
                         properties:_{seen:_{type:number,
                                            exclusiveMinimum:0}}},
                limits:_{time_limit:1.0, max_output_bytes:1024}}).

slow_schema(
    tool_schema{name:slow,
                description:"timeout fixture",
                capability:tool(slow),
                effect:read,
                arguments:_{type:object,
                            required:[],
                            additional_properties:false,
                            properties:_{}},
                result:_{type:object,
                         required:[ok],
                         additional_properties:false,
                         properties:_{ok:_{type:boolean}}},
                limits:_{time_limit:0.005, max_output_bytes:1024}}).

large_schema(
    tool_schema{name:large,
                description:"oversized output fixture",
                capability:tool(large),
                effect:read,
                arguments:_{type:object,
                            required:[],
                            additional_properties:false,
                            properties:_{}},
                result:_{type:string},
                limits:_{time_limit:1.0, max_output_bytes:32}}).

:- end_tests(rlm_tool).
