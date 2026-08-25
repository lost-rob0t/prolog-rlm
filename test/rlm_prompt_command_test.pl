:- begin_tests(rlm_prompt_command).

:- use_module('../prolog/rlm_prompt_command').

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
