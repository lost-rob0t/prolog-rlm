:- begin_tests(rlm_prompt_command).

:- use_module('../prolog/rlm_agent').
:- use_module('../prolog/rlm_prompt_command').
:- use_module('../prolog/rlm_subagent').
:- use_module('../prolog/rlm_tool').
:- use_module('support/completion_test_support').

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

unknown_command(Compiled) :-
    Records = [prompt(short_unknown, "Need evidence."),
               prompt_trigger(short_unknown, unknown),
               prompt_action(short_unknown, delegate_subagent)],
    prompt_command_compile(Records, unknown, ok(Compiled)).

skill_role_records([
    prompt(short_unknown, "Need evidence."),
    prompt_trigger(short_unknown, unknown),
    prompt_action(short_unknown, delegate_subagent),
    prompt_role(short_unknown, reviewer),
    prompt_skill(short_unknown, 'rlm-facts')
]).

test(short_prompt_unknown_binds_canonical_subagent_command) :-
    unknown_command(Compiled),
    assertion(Compiled.prompt_id == short_unknown),
    assertion(Compiled.text == "Need evidence."),
    assertion(Compiled.trigger == unknown),
    assertion(Compiled.command == tool(rlm_subagent)),
    assertion(Compiled.provenance == kb(short_unknown)),
    assertion(atom(Compiled.fingerprint)).

test(compiled_delegate_executes_through_typed_tool_runtime) :-
    unknown_command(Compiled),
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

test(compiled_delegate_returns_child_result_to_parent,
     [setup(completion_test_support:reset_calls)]) :-
    unknown_command(Compiled),
    Caps = [tool(rlm_subagent), rlm, model(openrouter)],
    ChildCaps = [rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps), max_agents(3)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
          Options = [planner_handler(completion_test_support:direct_planner),
                     capabilities(ChildCaps),
                     child_capabilities(ChildCaps)],
          rlm_subagent_register(Registry, Runtime, Parent, ChildCaps,
                                text("bounded evidence"), Options, ok(_)),
          prompt_command_execute(Compiled, Registry, Caps, [],
                                 ok(Execution), Trace),
          Envelope = Execution.value,
          assertion(Trace.authorization == allowed),
          assertion(Envelope.status == completed),
          assertion(Envelope.value == "direct-ok"),
          Child = Envelope.correlation.child,
          Child = agent(_),
          pump_until_child_result(Runtime, Parent, Child, 20),
          agent_status(Runtime, Parent, ok(ParentStatus)),
          assertion(ParentStatus.last_result ==
                    child_result{child:Child, result:ok(Envelope)})
        ),
        ( tool_registry_destroy(Registry),
          agent_runtime_destroy(Runtime)
        )).

test(forged_command_target_fails_before_tool_invocation) :-
    unknown_command(Compiled),
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

test(tampered_allowed_command_fails_fingerprint_before_tool_invocation) :-
    unknown_command(Compiled),
    put_dict(text, Compiled, "Changed query", Tampered),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( prompt_command_execute(Tampered, Registry,
                                 [tool(rlm_subagent)], [],
                                 error(Error), Trace),
          assertion(Error.kind == invalid_fingerprint),
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

test(delegation_policy_compiles_role_and_skill_into_fingerprint) :-
    skill_role_records(Records),
    prompt_command_compile(Records, unknown, ok(Compiled)),
    Policy = Compiled.delegation_policy,
    assertion(Policy.role == reviewer),
    assertion(Policy.skills == ['rlm-facts']),
    assertion(Policy.provenance == kb(short_unknown)),
    assertion(atom(Compiled.fingerprint)).

test(duplicate_delegation_role_fails_closed) :-
    Records = [prompt(short_unknown, "Need evidence."),
               prompt_trigger(short_unknown, unknown),
               prompt_action(short_unknown, delegate_subagent),
               prompt_role(short_unknown, reviewer),
               prompt_role(short_unknown, researcher)],
    prompt_command_compile(Records, unknown, error(Error)),
    assertion(Error.kind == ambiguous_delegation_role).

test(compiled_policy_rejects_conflicting_host_delegation_options) :-
    skill_role_records(Records),
    prompt_command_compile(Records, unknown, ok(Compiled)),
    prompt_command_subagent_options(
        Compiled,
        [subagent_role(researcher)],
        error(Error)),
    assertion(Error.kind == delegation_policy_conflict).

test(tampered_compiled_policy_is_rejected_before_registration) :-
    skill_role_records(Records),
    prompt_command_compile(Records, unknown, ok(Compiled)),
    put_dict(delegation_policy,
             Compiled,
             delegation_policy{role:researcher,
                               skills:['rlm-facts'],
                               provenance:kb(short_unknown)},
             Tampered),
    prompt_command_subagent_options(Tampered, [], error(Error)),
    assertion(Error.kind == invalid_fingerprint).

test(compiled_policy_drives_canonical_subagent_and_child_prompt,
     [setup(completion_test_support:reset_calls)]) :-
    Caps = [tool(rlm_subagent), rlm, model(openrouter)],
    ChildCaps = [rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps), max_agents(3)], Runtime),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
          skill_role_records(Records),
          prompt_command_compile(Records, unknown, ok(Compiled)),
          BaseOptions = [planner_handler(completion_test_support:capture_planner),
                         capabilities(ChildCaps),
                         child_capabilities(ChildCaps),
                         disabled_skills(['rlm-operate',
                                          'rlm-recurse',
                                          'rlm-constraints'])],
          rlm_subagent_register_command(Registry,
                                        Runtime,
                                        Parent,
                                        ChildCaps,
                                        text("bounded evidence"),
                                        BaseOptions,
                                        Compiled,
                                        ok(_)),
          prompt_command_execute(Compiled, Registry, Caps, [],
                                 ok(Execution), _),
          Envelope = Execution.value,
          assertion(Envelope.status == completed),
          assertion(Envelope.delegation.role == reviewer),
          assertion(Envelope.delegation.skills == ['rlm-facts']),
          Source = Envelope.delegation.source,
          assertion(Source.kind == prompt_command),
          assertion(Source.prompt_id == short_unknown),
          assertion(Source.fingerprint == Compiled.fingerprint),
          completion_test_support:last_planner_request(Request),
          Request.messages = [System, User],
          assertion(System.role == system),
          assertion(User.role == user),
          assertion(sub_string(System.content, _, _, _, "RLM_FACTS_BODY")),
          assertion(\+ sub_string(System.content, _, _, _,
                                  "RLM_OPERATE_BODY")),
          assertion(\+ sub_string(System.content, _, _, _,
                                  "RLM_RECURSE_BODY")),
          assertion(\+ sub_string(System.content, _, _, _,
                                  "RLM_CONSTRAINTS_BODY")),
          Child = Envelope.correlation.child,
          agent_status(Runtime, Child, ok(ChildStatus)),
          assertion(ChildStatus.capabilities == ChildCaps)
        ),
        ( tool_registry_destroy(Registry),
          agent_runtime_destroy(Runtime)
        )).

pump_until_child_result(_, _, _, Attempts) :-
    Attempts =< 0,
    !,
    assertion(fail).
pump_until_child_result(Runtime, Parent, Child, Attempts) :-
    agent_pump(Runtime, Parent, [timeout(0.1)], Outcome),
    (   Outcome = ok(Pump),
        Pump.status == processed,
        get_dict(reply, Pump, Reply),
        is_dict(Reply, agent_reply),
        get_dict(kind, Reply, child_result),
        get_dict(child, Reply, Child)
    ->  true
    ;   Next is Attempts-1,
        pump_until_child_result(Runtime, Parent, Child, Next)
    ).

:- end_tests(rlm_prompt_command).
