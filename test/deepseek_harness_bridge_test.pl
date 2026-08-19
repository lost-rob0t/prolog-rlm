:- begin_tests(deepseek_harness_bridge).

:- use_module('../agentProlog/deepseek-harness/prolog/deepseek_prolog_settings').
:- use_module('../agentProlog/deepseek-harness/prolog/deepseek_prolog_bridge').

test(defaults_are_lossless_and_uncompressed) :-
    deepseek_settings_defaults(Settings),
    assertion(Settings.driver == "prolog-rlm"),
    assertion(Settings.history_mode == "lossless_rlm"),
    assertion(Settings.compaction == false),
    assertion(Settings.persist_sessions == true),
    assertion(Settings.provider == "openrouter").

test(compaction_cannot_be_enabled) :-
    deepseek_settings_defaults(Defaults),
    put_dict(compaction, Defaults, true, Invalid),
    deepseek_settings_normalize(Invalid, Outcome),
    assertion(Outcome = error(_)).

test(unknown_secret_setting_is_rejected) :-
    deepseek_settings_defaults(Defaults),
    put_dict(api_key, Defaults, "do-not-store-secrets", Invalid),
    deepseek_settings_normalize(Invalid, Outcome),
    assertion(Outcome = error(_)).

test(openrouter_reuses_core_provider) :-
    deepseek_settings_defaults(Settings),
    deepseek_settings_provider(Settings, Outcome),
    Outcome = ok(Selection),
    assertion(Selection.name == openrouter),
    assertion(Selection.model == 'openrouter/free'),
    Selection.provider = provider(openrouter, Options),
    assertion(memberchk(credential(env('OPENROUTER_API_KEY')), Options)),
    assertion(memberchk(model('openrouter/free'), Options)).

test(deepseek_uses_openai_compatible_core_provider) :-
    deepseek_settings_defaults(Defaults),
    put_dict(_{provider:"deepseek", model:"deepseek-v4-pro"},
             Defaults,
             Settings),
    deepseek_settings_provider(Settings, Outcome),
    Outcome = ok(Selection),
    assertion(Selection.name == deepseek),
    assertion(Selection.model == 'deepseek-v4-pro'),
    Selection.provider = provider(openai_compatible, Options),
    assertion(memberchk(endpoint('https://api.deepseek.com/chat/completions'),
                        Options)),
    assertion(memberchk(credential(env('DEEPSEEK_API_KEY')), Options)),
    assertion(memberchk(model('deepseek-v4-pro'), Options)).

test(settings_round_trip,
     [ setup(temp_path(SettingsPath)),
       cleanup(cleanup_path(SettingsPath))
     ]) :-
    deepseek_settings_defaults(Defaults),
    put_dict(_{provider:"deepseek", model:"deepseek-v4-flash"},
             Defaults,
             Settings),
    deepseek_settings_save(SettingsPath, Settings, SaveOutcome),
    assertion(SaveOutcome = ok(_)),
    deepseek_settings_load(SettingsPath, LoadOutcome),
    LoadOutcome = ok(Loaded),
    assertion(Loaded.provider == "deepseek"),
    assertion(Loaded.model == "deepseek-v4-flash"),
    assertion(Loaded.compaction == false),
    assertion(Loaded.history_mode == "lossless_rlm").

test(bridge_exposes_prolog_authority_contract,
     [ setup(memory_bridge(SettingsPath)),
       cleanup(close_memory_bridge(SettingsPath))
     ]) :-
    Request = _{request_id:"hello-1",
                command:"hello",
                payload:_{}},
    deepseek_bridge_handle(Request, Response),
    assertion(Response.ok == true),
    assertion(Response.request_id == "hello-1"),
    Result = Response.result,
    assertion(Result.canonical_agent_runtime == "prolog-rlm"),
    assertion(Result.history_mode == "lossless_rlm"),
    assertion(Result.compaction == false),
    assertion(memberchk("session/turn", Result.commands)).

test(bridge_creates_and_lists_sessions_without_model_call,
     [ setup(memory_bridge(SettingsPath)),
       cleanup(close_memory_bridge(SettingsPath))
     ]) :-
    Create = _{request_id:"create-1",
               command:"session/create",
               payload:_{id:"session-test",
                         metadata:_{purpose:"test"}}},
    deepseek_bridge_handle(Create, CreateResponse),
    assertion(CreateResponse.ok == true),
    assertion(CreateResponse.result.session_id == "session-test"),
    assertion(CreateResponse.result.compaction == false),
    List = _{request_id:"list-1",
             command:"session/list",
             payload:_{limit:8}},
    deepseek_bridge_handle(List, ListResponse),
    assertion(ListResponse.ok == true),
    assertion(ListResponse.result = [Session|_]),
    assertion(Session.session_id == "session-test").

test(bridge_settings_update_persists,
     [ setup(memory_bridge(SettingsPath)),
       cleanup(close_memory_bridge(SettingsPath))
     ]) :-
    Update = _{request_id:"settings-1",
               command:"settings/set",
               payload:_{settings:_{provider:"deepseek",
                                    model:"deepseek-v4-pro"}}},
    deepseek_bridge_handle(Update, Response),
    assertion(Response.ok == true),
    assertion(Response.result.provider == "deepseek"),
    assertion(Response.result.model == "deepseek-v4-pro"),
    deepseek_settings_load(SettingsPath, LoadOutcome),
    LoadOutcome = ok(Loaded),
    assertion(Loaded.provider == "deepseek"),
    assertion(Loaded.model == "deepseek-v4-pro"),
    assertion(Loaded.compaction == false).

test(bridge_rejects_compaction_update,
     [ setup(memory_bridge(SettingsPath)),
       cleanup(close_memory_bridge(SettingsPath))
     ]) :-
    Update = _{request_id:"settings-compact",
               command:"settings/set",
               payload:_{settings:_{compaction:true}}},
    deepseek_bridge_handle(Update, Response),
    assertion(Response.ok == false).

test(completion_options_keep_provider_in_prolog) :-
    deepseek_settings_defaults(Defaults),
    put_dict(_{provider:"deepseek", model:"deepseek-v4-pro"},
             Defaults,
             Settings),
    deepseek_bridge_completion_options(Settings, Options, Route),
    assertion(memberchk(provider_name(deepseek), Options)),
    assertion(member(provider(provider(openai_compatible, _)), Options)),
    assertion(Route.provider == "deepseek"),
    assertion(Route.model == "deepseek-v4-pro"),
    assertion(Route.history_mode == "lossless_rlm"),
    assertion(Route.compaction == false).

memory_bridge(SettingsPath) :-
    temp_path(SettingsPath),
    deepseek_settings_defaults(Defaults),
    put_dict(_{persist_sessions:false,
               conversation_store:"unused-memory-store"},
             Defaults,
             Settings),
    deepseek_settings_save(SettingsPath, Settings, SaveOutcome),
    (   SaveOutcome = ok(_)
    ->  true
    ;   throw(SaveOutcome)
    ),
    deepseek_bridge_open(SettingsPath, OpenOutcome),
    (   OpenOutcome = ok(_)
    ->  true
    ;   throw(OpenOutcome)
    ).

close_memory_bridge(SettingsPath) :-
    deepseek_bridge_close(_),
    cleanup_path(SettingsPath).

temp_path(Path) :-
    tmp_file_stream(text, Path, Stream),
    close(Stream),
    delete_file(Path).

cleanup_path(Path) :-
    (   exists_file(Path)
    ->  delete_file(Path)
    ;   true
    ).

:- end_tests(deepseek_harness_bridge).
