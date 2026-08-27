:- set_prolog_flag(on_error, status).
:- initialization(main, main).

:- use_module(library(filesex)).

:- prolog_load_context(directory, TestDir),
   directory_file_path(TestDir, '../../prolog', CoreDir),
   asserta(user:file_search_path(library, CoreDir)),
   directory_file_path(TestDir, '../prolog', AgentDir),
   asserta(user:file_search_path(agentprolog, AgentDir)).

:- use_module(library(rlm_async)).
:- use_module(library(prolog_agent_ui_v1)).
:- use_module(agentprolog(agentprolog_cli)).
:- use_module(agentprolog(agentprolog_config)).
:- use_module(agentprolog(agentprolog_ui)).

fake_ui_submit(_Argv, Future) :-
    rlm_future_deferred(async_metadata{operation:agentprolog_ui_test}, Future).

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

test(ui_negotiate_returns_correlated_snapshot) :-
    agentprolog_ui_initial_state(State0),
    Protocol = "prolog_agent_ui_v1",
    Frame = ui_frame{protocol:Protocol,
                     kind:"negotiate",
                     request_id:"req_negotiate",
                     payload:_{protocol_versions:[Protocol],
                               required_capabilities:[],
                               optional_capabilities:["mouse"]}},
    agentprolog_ui_handle(Frame, State0, State, Frames, user:fake_ui_submit),
    assertion(State == State0),
    assertion(Frames = [Result, Snapshot]),
    assertion(Result.kind == "result"),
    assertion(Result.request_id == "req_negotiate"),
    assertion(Result.status == "ok"),
    assertion(Snapshot.kind == "snapshot"),
    assertion(Snapshot.session_id == State0.session_id),
    assertion(Snapshot.at_seq =:= 0).

test(ui_submit_poll_completes_exactly_once) :-
    agentprolog_ui_initial_state(State0),
    ui_v1_command_frame(State0.session_id,
                        "req_submit",
                        "run.submit",
                        _{query:"hello", provider:"deepseek"},
                        Submit),
    agentprolog_ui_handle(Submit,
                          State0,
                          State1,
                          SubmitFrames,
                          user:fake_ui_submit),
    assertion(SubmitFrames = [SubmitResult, Started]),
    assertion(SubmitResult.request_id == "req_submit"),
    assertion(SubmitResult.status == "ok"),
    assertion(Started.event_type == "run_started"),
    assertion(Started.caused_by == "req_submit"),
    Future = State1.active.future,
    rlm_future_resolve(
        Future,
        ok(cli_session{command:rlm,
                       status:pass,
                       summary:"ok\n",
                       payload:_{text:"done"},
                       output:_{}})),
    ui_v1_command_frame(State1.session_id,
                        "req_poll_1",
                        "session.poll",
                        _{},
                        Poll1),
    agentprolog_ui_handle(Poll1,
                          State1,
                          State2,
                          PollFrames1,
                          user:fake_ui_submit),
    assertion(PollFrames1 = [PollResult1, Finished]),
    assertion(PollResult1.request_id == "req_poll_1"),
    assertion(PollResult1.payload.state == "completed"),
    assertion(Finished.event_type == "run_finished"),
    assertion(Finished.caused_by == "req_submit"),
    assertion(State2.active == none),
    ui_v1_command_frame(State2.session_id,
                        "req_poll_2",
                        "session.poll",
                        _{},
                        Poll2),
    agentprolog_ui_handle(Poll2,
                          State2,
                          State3,
                          PollFrames2,
                          user:fake_ui_submit),
    assertion(PollFrames2 = [Idle]),
    assertion(Idle.payload.state == "idle"),
    assertion(State3 == State2).

test(ui_cancel_is_correlated_and_terminal) :-
    agentprolog_ui_initial_state(State0),
    ui_v1_command_frame(State0.session_id,
                        "req_submit_cancel",
                        "run.submit",
                        _{query:"cancel me"},
                        Submit),
    agentprolog_ui_handle(Submit,
                          State0,
                          State1,
                          _,
                          user:fake_ui_submit),
    ui_v1_command_frame(State1.session_id,
                        "req_cancel",
                        "session.cancel",
                        _{},
                        Cancel),
    agentprolog_ui_handle(Cancel,
                          State1,
                          State2,
                          CancelFrames,
                          user:fake_ui_submit),
    assertion(CancelFrames = [CancelResult, Finished]),
    assertion(CancelResult.request_id == "req_cancel"),
    assertion(CancelResult.status == "ok"),
    assertion(CancelResult.payload.state == "cancelled"),
    assertion(Finished.event_type == "run_finished"),
    assertion(Finished.caused_by == "req_cancel"),
    assertion(State2.active == none).

argv_pair(Name, Value, Args) :-
    append(_, [Name, Value|_], Args).

:- end_tests(agentprolog_product).

main(_) :-
    (   run_tests([agentprolog_product])
    ->  halt(0)
    ;   halt(1)
    ).
