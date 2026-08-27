:- set_prolog_flag(on_error, status).
:- initialization(main, main).

:- use_module(library(filesex)).

:- prolog_load_context(directory, TestDir),
   directory_file_path(TestDir, '../../prolog', CoreDir),
   asserta(user:file_search_path(library, CoreDir)),
   directory_file_path(TestDir, '../prolog', AgentDir),
   asserta(user:file_search_path(agentprolog, AgentDir)).

:- use_module(agentprolog(agentprolog_cli)).
:- use_module(agentprolog(agentprolog_config)).

:- begin_tests(agentprolog_product).

test(programmable_config_feature_is_preserved) :-
    agentprolog_config_defaults(Config),
    assertion(Config.schema_version =:= 1),
    assertion(Config.settings.history_mode == "lossless_rlm"),
    assertion(Config.settings.compaction == false).

test(executable_config_can_override_settings) :-
    tmp_file(agentprolog_config_test, Path),
    setup_call_cleanup(
        open(Path, write, Stream, [encoding(utf8)]),
        format(Stream,
               'preferred_model("test/model").~nsetting(model, Model) :- preferred_model(Model).~n',
               []),
        close(Stream)),
    setup_call_cleanup(
        true,
        ( agentprolog_config_load_file(Path, prolog, ok(Source)),
          assertion(Source.generation > 0),
          agentprolog_config_resolve(
              _{user_path:Path, user_format:prolog},
              ok(Resolution)),
          assertion(Resolution.effective.settings.model == "test/model")
        ),
        catch(delete_file(Path), _, true)).

test(secret_like_setting_is_rejected) :-
    agentprolog_config_normalize(
        _{settings:_{api_key:"do-not-persist"}},
        error(_)).

test(deepseek_profile_uses_current_api_contract) :-
    agentprolog_core_argv(
        [ask, hello, '--provider', deepseek, '--json'],
        Args),
    assertion(Args = [rlm|_]),
    assertion(argv_pair('--endpoint', "https://api.deepseek.com", Args)),
    assertion(argv_pair('--model', 'deepseek-v4-flash', Args)),
    assertion(argv_pair('--credential-env', "DEEPSEEK_API_KEY", Args)),
    assertion(memberchk('--json', Args)).

test(explicit_model_overrides_deepseek_default) :-
    agentprolog_core_argv(
        [ask, hello, '--provider', deepseek,
         '--model', 'deepseek-v4-pro'],
        Args),
    assertion(argv_pair('--model', 'deepseek-v4-pro', Args)),
    findall(Model, argv_pair('--model', Model, Args), Models),
    assertion(Models == ['deepseek-v4-pro']).

test(openrouter_profile_does_not_inject_custom_endpoint) :-
    agentprolog_core_argv(
        [direct, hello, '--provider', openrouter],
        Args),
    assertion(Args = [direct|_]),
    assertion(argv_pair('--model', 'openrouter/free', Args)),
    assertion(\+ memberchk('--endpoint', Args)),
    assertion(\+ memberchk('--credential-env', Args)).

test(runtime_command_is_raw_core_passthrough) :-
    agentprolog_core_argv([runtime, demo, graph, '--json'], Args),
    assertion(Args == [demo, graph, '--json']).

test(duplicate_provider_is_rejected,
     [throws(agentprolog_cli_fault(duplicate_provider_option))]) :-
    agentprolog_core_argv(
        [ask, hello,
         '--provider', deepseek,
         '--provider', openrouter],
        _).

argv_pair(Name, Value, Args) :-
    append(_, [Name, Value|_], Args).

:- end_tests(agentprolog_product).

main(_) :-
    (   run_tests([agentprolog_product])
    ->  halt(0)
    ;   halt(1)
    ).
