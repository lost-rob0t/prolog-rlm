:- begin_tests(rlm_prompt_command).

:- use_module('../prolog/rlm_prompt_command').
:- use_module('../prolog/rlm_tool').

command_fixture_schema(
    tool_schema{name:rlm_subagent,
                description:"prompt command runtime fixture",
                capability:tool(rlm_subagent),
                effect:read,
                arguments:_{type:object,
                            required:[query],
                            additional_properties:false,
                            properties:_{query:_{type:string}}},
                result:_{type:object},
                limits:_{time_limit:1.0,max_output_bytes:1024}}).

command_fixture(Args, _{query:Args.query}).

test(short_prompt_unknown_binds_canonical_subagent_command) :-
    Records = [prompt(short_unknown, "Need evidence."),
               prompt_trigger(short_unknown, unknown),
               prompt_action(short_unknown, delegate_subagent)],
    prompt_command_compile(Records, unknown, ok(Compiled)),
    assertion(Compiled.prompt_id == short_unknown),
    assertion(Compiled.text == "Need evidence."),
    assertion(Compiled.trigger == unknown),
    assertion(Compiled.command == tool(rlm_subagent)),
    assertion(Compiled.provenance == kb(short_unknown)),
    assertion(atom(Compiled.fingerprint)).

test(compiled_delegate_executes_through_typed_tool_runtime) :-
    Records = [prompt(short_unknown, "Need evidence."),
               prompt_trigger(short_unknown, unknown),
               prompt_action(short_unknown, delegate_subagent)],
    prompt_command_compile(Records, unknown, ok(Compiled)),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( command_fixture_schema(Schema),
          tool_register(Registry, Schema,
                        plunit_rlm_prompt_command:command_fixture, ok(_)),
          prompt_command_execute(Compiled, Registry,
                                 [tool(rlm_subagent)], [],
                                 ok(Execution), Trace),
          assertion(Trace.authorization == allowed),
          assertion(Execution.value.query == "Need evidence.")
        ),
        tool_registry_destroy(Registry)).

test(forged_command_target_fails_before_tool_invocation) :-
    Records = [prompt(short_unknown, "Need evidence."),
               prompt_trigger(short_unknown, unknown),
               prompt_action(short_unknown, delegate_subagent)],
    prompt_command_compile(Records, unknown, ok(Compiled)),
    put_dict(command, Compiled, tool(secret_fixture), Forged),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( prompt_command_execute(Forged, Registry,
                                 [tool(secret_fixture)], [],
                                 error(Error), Trace),
          assertion(Error.kind == unsupported_command),
          assertion(Trace.status == command_rejected)
        ),
        tool_registry_destroy(Registry)).

test(reusable_prompt_reference_is_deterministic) :-
    Records = [prompt(short_unknown, "Need evidence."),
               prompt_trigger(short_unknown, unknown),
               prompt_action(short_unknown, delegate_subagent)],
    prompt_command_compile_ref(Records, short_unknown, ok(A)),
    prompt_command_compile_ref(Records, short_unknown, ok(B)),
    assertion(A == B).

test(ambiguous_binding_fails_explicitly) :-
    Records = [prompt(a, "A"), prompt_trigger(a, unknown), prompt_action(a, delegate_subagent),
               prompt(b, "B"), prompt_trigger(b, unknown), prompt_action(b, delegate_subagent)],
    prompt_command_compile(Records, unknown, error(Error)),
    assertion(Error.kind == ambiguous_binding).

test(missing_binding_fails_explicitly) :-
    prompt_command_compile([prompt(a, "A")], unknown, error(Error)),
    assertion(Error.kind == missing_binding).

test(arbitrary_callable_action_is_rejected) :-
    Records = [prompt(bad, "Bad"), prompt_trigger(bad, unknown),
               prompt_action(bad, call(shell('rm -rf /')))],
    prompt_command_compile_ref(Records, bad, error(Error)),
    assertion(Error.kind == invalid_action).

test(action_vocabulary_is_closed) :-
    prompt_command_action(delegate_subagent, tool(rlm_subagent)),
    \+ prompt_command_action(call(foo), _).

:- end_tests(rlm_prompt_command).
