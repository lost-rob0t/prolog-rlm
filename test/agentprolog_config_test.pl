:- begin_tests(agentprolog_config).

:- use_module(library(filesex)).
:- use_module(library(process)).
:- use_module('../agentProlog/prolog/agentprolog_config').

with_temp_tree(Goal) :-
    tmp_file(agentprolog_config, Root),
    make_directory_path(Root),
    setup_call_cleanup(true,
                       call(Goal, Root),
                       delete_directory_and_contents(Root)).

write_text(Path, Text) :-
    file_directory_name(Path, Directory),
    make_directory_path(Directory),
    setup_call_cleanup(open(Path, write, Stream, [encoding(utf8)]),
                       format(Stream, '~s', [Text]),
                       close(Stream)).

read_text(Path, Text) :-
    setup_call_cleanup(open(Path, read, Stream, [encoding(utf8)]),
                       read_string(Stream, _, Text),
                       close(Stream)).

require_ok(ok(Value), Value).

with_env(Name, Value, Goal) :-
    env_snapshot(Name, Before),
    setup_call_cleanup(setenv(Name, Value),
                       Goal,
                       restore_env(Name, Before)).

env_snapshot(Name, some(Value)) :-
    getenv(Name, Value),
    !.
env_snapshot(_, none).

restore_env(Name, some(Value)) :- !,
    setenv(Name, Value).
restore_env(Name, none) :-
    unsetenv(Name).

unix_file_mode(Path, Mode) :-
    process_create(path(stat),
                   ['-c', '%a', Path],
                   [ stdout(pipe(Out)),
                     process(Pid)
                   ]),
    setup_call_cleanup(true,
                       read_string(Out, _, Raw),
                       close(Out)),
    process_wait(Pid, exit(0)),
    normalize_space(string(Mode), Raw).

test(xdg_user_paths_are_prolog_first) :-
    with_temp_tree(xdg_user_paths_are_prolog_first_).

xdg_user_paths_are_prolog_first_(Root) :-
    with_env('XDG_CONFIG_HOME', Root,
             ( agentprolog_config_default_path(PrologPath),
               agentprolog_config_json_path(JsonPath),
               directory_file_path(Root,
                                   'prolog-rlm/agentProlog/config.prolog',
                                   ExpectedProlog),
               directory_file_path(Root,
                                   'prolog-rlm/agentProlog/config.json',
                                   ExpectedJson),
               assertion(PrologPath == ExpectedProlog),
               assertion(JsonPath == ExpectedJson)
             )).

test(user_config_is_executable_prolog) :-
    with_temp_tree(user_config_is_executable_prolog_).

user_config_is_executable_prolog_(Root) :-
    directory_file_path(Root, 'config.prolog', Path),
    write_text(Path,
               ":- dynamic loaded_marker/1.\n:- initialization(assertz(loaded_marker(ok))).\nhelper_model(\"rule/model\").\nsetting(model, Model) :- helper_model(Model).\n"),
    agentprolog_config_resolve(_{user_path:Path}, Outcome),
    require_ok(Outcome, Resolution),
    assertion(Resolution.effective.settings.model == "rule/model"),
    assertion(Resolution.sources = [Source]),
    Module = Source.module,
    assertion(Module \== null),
    assertion(call(Module:loaded_marker(ok))),
    assertion(call(Module:helper_model("rule/model"))).

test(prolog_and_json_normalize_to_same_effective_config) :-
    with_temp_tree(prolog_and_json_normalize_to_same_effective_config_).

prolog_and_json_normalize_to_same_effective_config_(Root) :-
    directory_file_path(Root, 'config.prolog', PrologPath),
    directory_file_path(Root, 'config.json', JsonPath),
    write_text(PrologPath,
               "config(_{settings:_{provider:openrouter, model:\"test/model\", persist_sessions:false}}).\n"),
    write_text(JsonPath,
               "{\"provider\":\"openrouter\",\"model\":\"test/model\",\"persist_sessions\":false}\n"),
    agentprolog_config_resolve(_{user_path:PrologPath}, PrologOutcome),
    require_ok(PrologOutcome, PrologResolution),
    agentprolog_config_resolve(_{user_path:JsonPath}, JsonOutcome),
    require_ok(JsonOutcome, JsonResolution),
    assertion(PrologResolution.effective == JsonResolution.effective).

test(prolog_json_handler_loads_then_allows_rule_override) :-
    with_temp_tree(prolog_json_handler_loads_then_allows_rule_override_).

prolog_json_handler_loads_then_allows_rule_override_(Root) :-
    directory_file_path(Root, 'base.json', JsonPath),
    directory_file_path(Root, 'config.prolog', PrologPath),
    write_text(JsonPath,
               "{\"settings\":{\"model\":\"json/model\"},\"frontend\":{\"theme\":\"dark\"}}\n"),
    write_text(PrologPath,
               "json(\"base.json\").\npreferred_model(\"prolog/model\").\nsetting(model, Model) :- preferred_model(Model).\n"),
    agentprolog_config_resolve(_{user_path:PrologPath}, Outcome),
    require_ok(Outcome, Resolution),
    assertion(Resolution.effective.settings.model == "prolog/model"),
    assertion(Resolution.effective.frontend.theme == "dark").

test(json_only_xdg_config_uses_same_runtime) :-
    with_temp_tree(json_only_xdg_config_uses_same_runtime_).

json_only_xdg_config_uses_same_runtime_(Root) :-
    with_env('XDG_CONFIG_HOME', Root,
             ( agentprolog_config_json_path(JsonPath),
               write_text(JsonPath,
                          "{\"model\":\"json-only/model\"}\n"),
               agentprolog_config_resolve(_{}, Outcome),
               require_ok(Outcome, Resolution),
               assertion(Resolution.effective.settings.model == "json-only/model"),
               assertion(Resolution.sources = [Source]),
               assertion(Source.format == json),
               assertion(Source.module == null)
             )).

test(untrusted_project_config_is_discovered_but_not_executed) :-
    with_temp_tree(untrusted_project_config_is_discovered_but_not_executed_).

untrusted_project_config_is_discovered_but_not_executed_(Root) :-
    agentprolog_project_config_paths(Root, ProjectPath, _),
    write_text(ProjectPath,
               ":- initialization(throw(project_config_was_executed)).\nsetting(model, \"evil/project\").\n"),
    ProjectIdentity = project_identity(untrusted_fixture, 1),
    Context = _{user_path:none,
                project:_{identity:ProjectIdentity,
                          root:Root,
                          trusted:false}},
    agentprolog_config_resolve(Context, Outcome),
    require_ok(Outcome, Resolution),
    assertion(Resolution.effective.settings.model == "openrouter/free"),
    assertion(Resolution.sources = [ProjectSource]),
    assertion(ProjectSource.status == blocked_untrusted),
    assertion(ProjectSource.project_identity == ProjectIdentity),
    assertion(ProjectSource.module == null).

test(trusted_project_config_executes_and_overlays_user) :-
    with_temp_tree(trusted_project_config_executes_and_overlays_user_).

trusted_project_config_executes_and_overlays_user_(Root) :-
    directory_file_path(Root, 'user.prolog', UserPath),
    write_text(UserPath, "setting(model, \"user/model\").\n"),
    agentprolog_project_config_paths(Root, ProjectPath, _),
    write_text(ProjectPath,
               "project_model(\"project/model\").\nsetting(model, Model) :- project_model(Model).\n"),
    ProjectIdentity = project_identity(trusted_fixture, 1),
    Context = _{user_path:UserPath,
                project:_{identity:ProjectIdentity,
                          root:Root,
                          trusted:true}},
    agentprolog_config_resolve(Context, Outcome),
    require_ok(Outcome, Resolution),
    assertion(Resolution.effective.settings.model == "project/model"),
    assertion(Resolution.sources = [UserSource, ProjectSource]),
    assertion(UserSource.scope == user),
    assertion(ProjectSource.scope == project),
    assertion(ProjectSource.status == loaded),
    assertion(ProjectSource.project_identity == ProjectIdentity),
    ProjectModule = ProjectSource.module,
    assertion(call(ProjectModule:project_model("project/model"))).

test(trusted_project_prolog_shadows_json_deterministically) :-
    with_temp_tree(trusted_project_prolog_shadows_json_deterministically_).

trusted_project_prolog_shadows_json_deterministically_(Root) :-
    agentprolog_project_config_paths(Root, PrologPath, JsonPath),
    write_text(PrologPath, "setting(model, \"prolog/project\").\n"),
    write_text(JsonPath, "{\"model\":\"json/project\"}\n"),
    Context = _{user_path:none,
                project:_{identity:project(test),
                          root:Root,
                          trusted:true}},
    agentprolog_config_resolve(Context, Outcome),
    require_ok(Outcome, Resolution),
    assertion(Resolution.effective.settings.model == "prolog/project"),
    assertion(Resolution.sources = [ProjectSource]),
    assertion(ProjectSource.format == prolog),
    assertion(ProjectSource.shadowed == [JsonPath]).

test(secret_settings_are_rejected_from_canonical_projection) :-
    with_temp_tree(secret_settings_are_rejected_from_canonical_projection_).

secret_settings_are_rejected_from_canonical_projection_(Root) :-
    directory_file_path(Root, 'config.prolog', Path),
    write_text(Path, "setting(openrouter_api_key, \"nope\").\n"),
    agentprolog_config_load_file(Path, prolog, Outcome),
    assertion(Outcome = error(Error)),
    assertion(Error.kind == secret_settings_forbidden).

test(reconsult_replaces_old_config_code_without_duplicate_state) :-
    with_temp_tree(reconsult_replaces_old_config_code_without_duplicate_state_).

reconsult_replaces_old_config_code_without_duplicate_state_(Root) :-
    directory_file_path(Root, 'config.prolog', Path),
    write_text(Path,
               "old_helper.\nsetting(model, \"first/model\").\n"),
    agentprolog_config_load_file(Path, prolog, FirstOutcome),
    require_ok(FirstOutcome, First),
    FirstModule = First.module,
    assertion(call(FirstModule:old_helper)),
    write_text(Path,
               "new_helper.\nsetting(model, \"second/model\").\n"),
    agentprolog_config_load_file(Path, prolog, SecondOutcome),
    require_ok(SecondOutcome, Second),
    assertion(Second.module == FirstModule),
    assertion(Second.generation > First.generation),
    assertion(Second.patch.settings.model == "second/model"),
    assertion(\+ current_predicate(FirstModule:old_helper/0)),
    assertion(call(FirstModule:new_helper)).

test(save_roundtrips_both_formats) :-
    with_temp_tree(save_roundtrips_both_formats_).

save_roundtrips_both_formats_(Root) :-
    agentprolog_config_defaults(Defaults),
    put_dict(model, Defaults.settings, "roundtrip/model", Settings),
    put_dict(settings, Defaults, Settings, Config),
    directory_file_path(Root, 'saved.prolog', PrologPath),
    directory_file_path(Root, 'saved.json', JsonPath),
    agentprolog_config_save_file(PrologPath, prolog, Config, PrologSave),
    require_ok(PrologSave, _),
    agentprolog_config_save_file(JsonPath, json, Config, JsonSave),
    require_ok(JsonSave, _),
    agentprolog_config_load_file(PrologPath, prolog, PrologLoad),
    require_ok(PrologLoad, PrologSource),
    agentprolog_config_load_file(JsonPath, json, JsonLoad),
    require_ok(JsonLoad, JsonSource),
    assertion(PrologSource.patch == JsonSource.patch),
    assertion(PrologSource.patch.settings.model == "roundtrip/model").

test(save_forces_0600,
     [condition(current_prolog_flag(unix, true))]) :-
    with_temp_tree(save_forces_0600_).

save_forces_0600_(Root) :-
    directory_file_path(Root, 'config.prolog', Path),
    write_text(Path, "config(_{}).\n"),
    chmod(Path, 0o644),
    agentprolog_config_defaults(Config),
    agentprolog_config_save_file(Path, prolog, Config, Outcome),
    require_ok(Outcome, Saved),
    assertion(Saved.mode =:= 0o600),
    unix_file_mode(Path, Mode),
    assertion(Mode == "600").

test(invalid_save_keeps_existing_file_unchanged) :-
    with_temp_tree(invalid_save_keeps_existing_file_unchanged_).

invalid_save_keeps_existing_file_unchanged_(Root) :-
    directory_file_path(Root, 'config.prolog', Path),
    Original = "keep_me.\n",
    write_text(Path, Original),
    agentprolog_config_save_file(Path,
                                 prolog,
                                 _{settings:_{compaction:true}},
                                 Outcome),
    assertion(Outcome = error(_)),
    read_text(Path, After),
    assertion(After == Original).

test(defaults_are_lossless_openrouter_without_deepseek_dependency) :-
    agentprolog_config_resolve(_{user_path:none}, Outcome),
    require_ok(Outcome, Resolution),
    assertion(Resolution.effective.settings.provider == "openrouter"),
    assertion(Resolution.effective.settings.model == "openrouter/free"),
    assertion(Resolution.effective.settings.history_mode == "lossless_rlm"),
    assertion(Resolution.effective.settings.compaction == false).

:- end_tests(agentprolog_config).
