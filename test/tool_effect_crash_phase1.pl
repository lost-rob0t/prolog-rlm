:- initialization(main, main).

:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_effect').
:- use_module('../prolog/rlm_effect_executor').
:- use_module('../prolog/rlm_effect_authority').
:- use_module('../prolog/rlm_authority').
:- use_module('support/tool_effect_crash_support').

main(Args) :-
    (   Args = [Ledger, MutationFile]
    ->  crash_phase_one(Ledger, MutationFile)
    ;   format(user_error,
               'usage: tool_effect_crash_phase1.pl LEDGER MUTATION_FILE~n', []),
        halt(2)
    ).

crash_phase_one(Ledger, MutationFile) :-
    set_prolog_flag(tty_control, false),
    tool_effect_crash_support:set_crash_mutation_file(MutationFile),
    rlm_effect_store_open(Ledger),
    crash_write_schema(Schema),
    tool_registry_create(Registry),
    tool_register(Registry, Schema,
                  tool_effect_crash_support:crash_write_tool, ok(_)),
    Context = session(tool_crash),
    rlm_set_authority(Context, dangerous, ok(_)),
    tool_invoke(Registry, [tool(crash_write)], crash_write,
                json{value:1}, [authority_context(Context)], _Outcome, _Trace).
