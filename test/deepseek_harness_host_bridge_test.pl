:- begin_tests(deepseek_harness_host_bridge).

:- use_module('../agentProlog/deepseek-harness/prolog/deepseek_prolog_host_bridge').
:- use_module('../agentProlog/deepseek-harness/prolog/deepseek_prolog_route_store').
:- use_module('../agentProlog/deepseek-harness/prolog/deepseek_prolog_settings').
:- use_module('../prolog/rlm_conversation').

test(host_messages_restore_historical_completion_route,
     [ setup(open_host_bridge(SettingsPath)),
       cleanup(close_host_bridge(SettingsPath))
     ]) :-
    Create = _{request_id:"create",
               command:"session/create",
               payload:_{id:"resume-route-session", metadata:_{}}},
    deepseek_host_bridge_handle(Create, CreateResponse),
    assertion(CreateResponse.ok == true),
    deepseek_prolog_bridge:bridge_runtime(_, _, Store),
    conversation_open(Store, 'resume-route-session', OpenOutcome),
    OpenOutcome = ok(Conversation),
    conversation_append(Conversation,
                        message(user, "before restart"),
                        UserOutcome),
    UserOutcome = ok(User),
    assertion(User.sequence == 1),
    conversation_append(Conversation,
                        message(assistant, "historical reply"),
                        AssistantOutcome),
    AssistantOutcome = ok(Assistant),
    assertion(Assistant.sequence == 2),
    deepseek_route_store_put("resume-route-session",
                             2,
                             "openrouter",
                             "deepseek/deepseek-chat",
                             PutOutcome),
    assertion(PutOutcome = ok(_)),
    Messages = _{request_id:"messages",
                 command:"session/messages",
                 payload:_{session_id:"resume-route-session",
                           limit:"all"}},
    deepseek_host_bridge_handle(Messages, Response),
    assertion(Response.ok == true),
    Response.result = [UserView, AssistantView],
    assertion(UserView.role == "user"),
    assertion(\+ get_dict(route, UserView, _)),
    assertion(AssistantView.role == "assistant"),
    assertion(AssistantView.route.provider == "openrouter"),
    assertion(AssistantView.route.model == "deepseek/deepseek-chat").

test(missing_assistant_route_is_never_relabelled_with_current_settings,
     [ setup(open_host_bridge(SettingsPath)),
       cleanup(close_host_bridge(SettingsPath))
     ]) :-
    Create = _{request_id:"create-missing",
               command:"session/create",
               payload:_{id:"missing-route-session", metadata:_{}}},
    deepseek_host_bridge_handle(Create, _),
    deepseek_prolog_bridge:bridge_runtime(_, _, Store),
    conversation_open(Store, 'missing-route-session', OpenOutcome),
    OpenOutcome = ok(Conversation),
    conversation_append(Conversation,
                        message(assistant, "old reply"),
                        AssistantOutcome),
    AssistantOutcome = ok(_),
    Messages = _{request_id:"messages-missing",
                 command:"session/messages",
                 payload:_{session_id:"missing-route-session",
                           limit:"all"}},
    deepseek_host_bridge_handle(Messages, Response),
    assertion(Response.ok == true),
    Response.result = [AssistantView],
    assertion(AssistantView.route == null).

test(completed_turn_projection_persists_exact_route,
     [ setup(open_host_bridge(SettingsPath)),
       cleanup(close_host_bridge(SettingsPath))
     ]) :-
    FakeTurn = _{assistant:_{sequence:8},
                 route:_{provider:"deepseek",
                         model:"deepseek-v4-pro"}},
    deepseek_prolog_host_bridge:persist_turn_route("route-only-session",
                                                   FakeTurn),
    deepseek_route_store_get("route-only-session", 8, Outcome),
    Outcome = ok(Route),
    assertion(Route.provider == deepseek),
    assertion(Route.model == 'deepseek-v4-pro').

open_host_bridge(SettingsPath) :-
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
    deepseek_host_bridge_open(SettingsPath, OpenOutcome),
    (   OpenOutcome = ok(_)
    ->  true
    ;   throw(OpenOutcome)
    ).

close_host_bridge(SettingsPath) :-
    deepseek_host_bridge_close(_),
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

:- end_tests(deepseek_harness_host_bridge).
