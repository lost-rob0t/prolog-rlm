:- module(agentprolog_cli,
          [ agentprolog_cli_ready/0,
            agentprolog_cli_execute/2,
            agentprolog_core_argv/2,
            agentprolog_usage/1
          ]).

/** <module> AgentProlog application CLI

This is product composition, not a second RLM runtime.  It translates the
AgentProlog command surface into the public prolog-rlm CLI contract and then
hands execution to rlm_cli.

The reusable library remains authoritative for providers, planning, recursion,
authority, effects, tracing, and result envelopes.  AgentProlog only owns
application defaults and ergonomics.
*/

:- use_module(library(rlm_cli)).
:- use_module(agentprolog_config).

agentprolog_cli_ready.

agentprolog_cli_execute(Argv0, ExitCode) :-
    catch(agentprolog_cli_execute_(Argv0, ExitCode),
          Exception,
          agentprolog_cli_exception(Exception, ExitCode)).

agentprolog_cli_execute_([], 0) :-
    !,
    agentprolog_usage(Usage),
    format('~s', [Usage]).
agentprolog_cli_execute_([help|_], 0) :-
    !,
    agentprolog_usage(Usage),
    format('~s', [Usage]).
agentprolog_cli_execute_(['--help'|_], 0) :-
    !,
    agentprolog_usage(Usage),
    format('~s', [Usage]).
agentprolog_cli_execute_(Argv, ExitCode) :-
    agentprolog_core_argv(Argv, CoreArgv),
    rlm_cli:cli_execute(CoreArgv, ExitCode).

agentprolog_core_argv([runtime|Rest], Rest) :-
    !.
agentprolog_core_argv([ask|Rest], [rlm|CoreArgs]) :-
    !,
    command_core_args(Rest, CoreArgs).
agentprolog_core_argv([direct|Rest], [direct|CoreArgs]) :-
    !,
    command_core_args(Rest, CoreArgs).
agentprolog_core_argv([Command|_], _) :-
    throw(agentprolog_cli_fault(unknown_command(Command))).
agentprolog_core_argv([], _) :-
    throw(agentprolog_cli_fault(missing_command)).

command_core_args(Args0, Args) :-
    extract_provider_option(Args0, ProviderSelector, Args1),
    provider_profile(ProviderSelector, Profile),
    apply_profile(Profile, Args1, Args).

extract_provider_option(Args, Provider, Clean) :-
    extract_provider_option_(Args, none, Provider0, [], Reversed),
    reverse(Reversed, Clean),
    (   Provider0 == none
    ->  Provider = configured
    ;   Provider = Provider0
    ).

extract_provider_option_([], Provider, Provider, Clean, Clean).
extract_provider_option_(['--provider', Value|Rest], Seen0, Provider, Acc0, Acc) :-
    !,
    normalize_provider(Value, Found),
    (   Seen0 == none
    ->  Seen = Found
    ;   throw(agentprolog_cli_fault(duplicate_provider_option))
    ),
    extract_provider_option_(Rest, Seen, Provider, Acc0, Acc).
extract_provider_option_(['--provider'], _, _, _, _) :-
    !,
    throw(agentprolog_cli_fault(missing_provider_value)).
extract_provider_option_([Arg|Rest], Seen, Provider, Acc0, Acc) :-
    extract_provider_option_(Rest, Seen, Provider, [Arg|Acc0], Acc).

normalize_provider(deepseek, deepseek) :- !.
normalize_provider("deepseek", deepseek) :- !.
normalize_provider(openrouter, openrouter) :- !.
normalize_provider("openrouter", openrouter) :- !.
normalize_provider(Value, _) :-
    throw(agentprolog_cli_fault(unsupported_provider(Value))).

provider_profile(deepseek,
                 profile{provider:deepseek,
                         endpoint:"https://api.deepseek.com",
                         model:'deepseek-v4-flash',
                         credential_env:"DEEPSEEK_API_KEY"}) :-
    !.
provider_profile(openrouter,
                 profile{provider:openrouter,
                         endpoint:none,
                         model:'openrouter/free',
                         credential_env:none}) :-
    !.
provider_profile(configured, Profile) :-
    configured_profile(Profile).

configured_profile(Profile) :-
    agentprolog_config_resolve(_{}, Outcome),
    (   Outcome = ok(Resolution)
    ->  Settings = Resolution.effective.settings,
        configured_provider(Settings, Provider),
        configured_profile_for(Provider, Settings, Profile)
    ;   provider_profile(openrouter, Profile)
    ).

configured_provider(Settings, Provider) :-
    (   get_dict(provider, Settings, Value)
    ->  catch(normalize_provider(Value, Provider), _, Provider = openrouter)
    ;   Provider = openrouter
    ).

configured_profile_for(deepseek, Settings, Profile) :-
    !,
    provider_profile(deepseek, Default),
    configured_model(Settings, Default.model, Model),
    put_dict(model, Default, Model, Profile).
configured_profile_for(openrouter, Settings, Profile) :-
    provider_profile(openrouter, Default),
    configured_model(Settings, Default.model, Model),
    put_dict(model, Default, Model, Profile).

configured_model(Settings, Default, Model) :-
    (   get_dict(model, Settings, Value),
        model_atom(Value, Candidate)
    ->  Model = Candidate
    ;   Model = Default
    ).

model_atom(Value, Value) :-
    atom(Value),
    Value \== '',
    !.
model_atom(Value, Atom) :-
    string(Value),
    Value \== "",
    !,
    atom_string(Atom, Value).

apply_profile(Profile, Args0, Args) :-
    maybe_prepend_model(Profile.model, Args0, Args1),
    maybe_prepend_endpoint(Profile.endpoint, Args1, Args2),
    maybe_prepend_credential(Profile.credential_env, Args2, Args).

maybe_prepend_model(_, Args, Args) :-
    has_option('--model', Args),
    !.
maybe_prepend_model(Model, Args, ['--model', Model|Args]).

maybe_prepend_endpoint(none, Args, Args) :- !.
maybe_prepend_endpoint(_, Args, Args) :-
    has_option('--endpoint', Args),
    !.
maybe_prepend_endpoint(Endpoint, Args, ['--endpoint', Endpoint|Args]).

maybe_prepend_credential(none, Args, Args) :- !.
maybe_prepend_credential(_, Args, Args) :-
    ( has_option('--credential-env', Args)
    ; memberchk('--no-credential', Args)
    ),
    !.
maybe_prepend_credential(Name, Args, ['--credential-env', Name|Args]).

has_option(Name, Args) :-
    memberchk(Name, Args).

agentprolog_usage(Usage) :-
    Lines = [
        "AgentProlog",
        "",
        "Usage:",
        "  agentprolog ask QUERY [--provider deepseek|openrouter] [RLM options]",
        "  agentprolog direct PROMPT [--provider deepseek|openrouter] [provider options]",
        "  agentprolog runtime <prolog-rlm command> ...",
        "  agentprolog help",
        "",
        "Profiles:",
        "  deepseek    https://api.deepseek.com, deepseek-v4-flash, DEEPSEEK_API_KEY",
        "  openrouter  OpenRouter using openrouter/free unless --model overrides it",
        "",
        "Without --provider, AgentProlog resolves its programmable config.prolog",
        "and falls back to the OpenRouter profile when no config is present.",
        "",
        "All provider/runtime flags after translation are handled by prolog-rlm.",
        ""
    ],
    atomics_to_string(Lines, "\n", Usage).

agentprolog_cli_exception(agentprolog_cli_fault(Detail), 2) :-
    !,
    format(user_error, 'agentprolog error: ~q~n', [Detail]),
    agentprolog_usage(Usage),
    format(user_error, '~s', [Usage]).
agentprolog_cli_exception(Exception, 2) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    format(user_error, 'agentprolog exception: ~s~n', [Safe]).
