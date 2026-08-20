:- begin_tests(deepseek_harness_bridge).

:- use_module('../agentProlog/deepseek-harness/prolog/deepseek_prolog_settings').
:- use_module('../agentProlog/deepseek-harness/prolog/deepseek_prolog_bridge').
:- use_module('../prolog/rlm_async').

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
    assertion(Result.turn_execution == "rlm_async"),
    assertion(memberchk("session/turn", Result.commands)),
    assertion(memberchk("session/turn/start", Result.commands)),
    assertion(memberchk("run/status", Result.commands)),
    assertion(memberchk("run/result", Result.commands)),
    assertion(memberchk("run/cancel", Result.commands)).

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

test(bridge_sessions_survive_close_and_reopen,
     [ setup(persistent_bridge(SettingsPath, StorePath)),
       cleanup(close_persistent_bridge(SettingsPath, StorePath))
     ]) :-
    Create = _{request_id:"persist-create",
               command:"session/create",
               payload:_{id:"persistent-session",
                         metadata:_{purpose:"restart-proof"}}},
    deepseek_bridge_handle(Create, CreateResponse),
    assertion(CreateResponse.ok == true),
    deepseek_bridge_close(CloseOutcome),
    assertion(CloseOutcome == ok(closed)),
    deepseek_bridge_open(SettingsPath, ReopenOutcome),
    assertion(ReopenOutcome = ok(_)),
    Open = _{request_id:"persist-open",
             command:"session/open",
             payload:_{session_id:"persistent-session"}},
    deepseek_bridge_handle(Open, OpenResponse),
    assertion(OpenResponse.ok == true),
    assertion(OpenResponse.result.session_id == "persistent-session"),
    assertion(OpenResponse.result.history_mode == "lossless_rlm"),
    assertion(OpenResponse.result.compaction == false).

test(async_run_status_cancel_and_result_use_core_future_runtime,
     [ setup(memory_bridge(SettingsPath)),
       cleanup(close_memory_bridge(SettingsPath))
     ]) :-
    rlm_async_submit(slow_bridge_test_task, Future),
    assertz(deepseek_prolog_bridge:bridge_run(test_async_run,
                                              'session-test',
                                              Future,
                                              _{provider:"test",
                                                model:"test",
                                                history_mode:"lossless_rlm",
                                                compaction:false},
                                              1.0)),
    StatusRequest = _{request_id:"run-status",
                      command:"run/status",
                      payload:_{run_id:"test_async_run"}},
    deepseek_bridge_handle(StatusRequest, StatusResponse),
    assertion(StatusResponse.ok == true),
    assertion(memberchk(StatusResponse.result.state, ["pending", "running"])),
    CancelRequest = _{request_id:"run-cancel",
                      command:"run/cancel",
                      payload:_{run_id:"test_async_run"}},
    deepseek_bridge_handle(CancelRequest, CancelResponse),
    assertion(CancelResponse.ok == true),
    assertion(CancelResponse.result.state == "cancelled"),
    ResultRequest = _{request_id:"run-result",
                      command:"run/result",
                      payload:_{run_id:"test_async_run"}},
    deepseek_bridge_handle(ResultRequest, ResultResponse),
    assertion(ResultResponse.ok == true),
    assertion(ResultResponse.result.state == "cancelled"),
    assertion(\+ deepseek_prolog_bridge:bridge_run(test_async_run,
                                                    _, _, _, _)).

test(async_run_blocks_overlapping_session_turns_without_model_call,
     [ setup(memory_bridge_with_session(SettingsPath, 'busy-session')),
       cleanup(close_memory_bridge(SettingsPath))
     ]) :-
    rlm_async_submit(slow_bridge_test_task, Future),
    assertz(deepseek_prolog_bridge:bridge_run(test_busy_run,
                                              'busy-session',
                                              Future,
                                              _{provider:"test",
                                                model:"test",
                                                history_mode:"lossless_rlm",
                                                compaction:false},
                                              1.0)),
    Start = _{request_id:"busy-start",
              command:"session/turn/start",
              payload:_{session_id:"busy-session",
                        content:"must not reach a provider"}},
    deepseek_bridge_handle(Start, StartResponse),
    assertion(StartResponse.ok == false),
    rlm_future_cancel(Future, _),
    rlm_future_destroy(Future),
    retractall(deepseek_prolog_bridge:bridge_run(test_busy_run,
                                                 _, _, _, _)).

test(async_run_blocks_overlapping_blocking_turn_without_model_call,
     [ setup(memory_bridge_with_session(SettingsPath, 'busy-sync-session')),
       cleanup(close_memory_bridge(SettingsPath))
     ]) :-
    rlm_async_submit(slow_bridge_test_task, Future),
    assertz(deepseek_prolog_bridge:bridge_run(test_busy_sync_run,
                                              'busy-sync-session',
                                              Future,
                                              _{provider:"test",
                                                model:"test",
                                                history_mode:"lossless_rlm",
                                                compaction:false},
                                              1.0)),
    Turn = _{request_id:"busy-sync-turn",
             command:"session/turn",
             payload:_{session_id:"busy-sync-session",
                       content:"must not reach a provider"}},
    deepseek_bridge_handle(Turn, TurnResponse),
    assertion(TurnResponse.ok == false),
    rlm_future_cancel(Future, _),
    rlm_future_destroy(Future),
    retractall(deepseek_prolog_bridge:bridge_run(test_busy_sync_run,
                                                 _, _, _, _)).

test(bridge_close_cancels_and_destroys_owned_runs,
     [ setup(memory_bridge(SettingsPath)),
       cleanup(close_memory_bridge(SettingsPath))
     ]) :-
    rlm_async_submit(slow_bridge_test_task, Future),
    assertz(deepseek_prolog_bridge:bridge_run(test_close_run,
                                              'session-test',
                                              Future,
                                              _{},
                                              1.0)),
    deepseek_bridge_close(CloseOutcome),
    assertion(CloseOutcome == ok(closed)),
    assertion(\+ deepseek_prolog_bridge:bridge_run(test_close_run,
                                                    _, _, _, _)),
    catch(rlm_future_status(Future, _), Error, true),
    assertion(nonvar(Error)).

test(wire_safe_never_leaks_unbound_json_values) :-
    deepseek_prolog_bridge:wire_safe(_, Safe),
    assertion(Safe == "<unbound>").

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

slow_bridge_test_task(ok(test_done)) :-
    sleep(5.0).

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

memory_bridge_with_session(SettingsPath, SessionId) :-
    memory_bridge(SettingsPath),
    atom_string(SessionId, SessionIdString),
    Create = _{request_id:"setup-session",
               command:"session/create",
               payload:_{id:SessionIdString,
                         metadata:_{purpose:"test"}}},
    deepseek_bridge_handle(Create, Response),
    (   Response.ok == true
    ->  true
    ;   throw(Response)
    ).

close_memory_bridge(SettingsPath) :-
    deepseek_bridge_close(_),
    cleanup_path(SettingsPath).

persistent_bridge(SettingsPath, StorePath) :-
    temp_path(SettingsPath),
    temp_path(StorePath),
    atom_string(StorePath, StorePathString),
    deepseek_settings_defaults(Defaults),
    put_dict(_{persist_sessions:true,
               conversation_store:StorePathString},
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

close_persistent_bridge(SettingsPath, StorePath) :-
    deepseek_bridge_close(_),
    cleanup_path(SettingsPath),
    cleanup_path(StorePath).

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
