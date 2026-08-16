:- begin_tests(rlm_tool).

:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_plan').
:- use_module('support/tool_test_support').

setup_registry(Registry) :-
    tool_registry_create(Registry).

cleanup_registry(Registry) :-
    tool_registry_destroy(Registry).

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