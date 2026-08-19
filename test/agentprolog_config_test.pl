:- begin_tests(agentprolog_config).

:- use_module(library(filesex)).
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

restore_env(Name, some(Value)) :- !, setenv(Name, Value).
restore_env(Name, none) :- unsetenv(Name).

test(xdg_user_paths_are_prolog_first) :-
    with_temp_tree(xdg_user_paths_are_prolog_first_).

xdg_user_paths_are_prolog_first_(Root) :-
    with_env('XDG_CONFIG_HOME', Root,
             ( agentprolog_config_default_path(PrologPath),
               agentprolog_config_json_path(JsonPath),
               directory_file_path(Root, 'prolog-rlm/agentProlog/config.prolog', ExpectedProlog),
               directory_file_path(Root, 'prolog-rlm/agentProlog/config.json', ExpectedJson),
               assertion(PrologPath == ExpectedProlog),
               assertion(JsonPath == ExpectedJson)
             )).

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

test(prolog_json_handler_loads_then_allows_prolog_override) :-
    with_temp_tree(prolog_json_handler_loads_then_allows_prolog_override_).

prolog_json_handler_loads_then_allows_prolog_override_(Root) :-
    directory_file_path(Root, 'base.json', JsonPath),
    directory_file_path(Root, 'config.prolog', PrologPath),
    write_text(JsonPath,
               "{\"settings\":{\"model\":\"json/model\"},\"frontend\":{\"theme\":\"dark\"}}\n"),
    write_text(PrologPath,
               "json(\"base.json\").\nsetting(model, \"prolog/model\").\n"),
    agentprolog_config_resolve(_{user_path:PrologPath}, Outcome),
    require_ok(Outcome, Resolution),
    assertion(Resolution.effective.settings.model == "prolog/model"),
    assertion(Resolution.effective.frontend.theme == "dark").

test(project_config_overlays_user_config_with_explicit_identity) :-
    with_temp_tree(project_config_overlays_user_config_with_explicit_identity_).

project_config_overlays_user_config_with_explicit_identity_(Root) :-
    directory_file_path(Root, 'user.prolog', UserPath),
    write_text(UserPath, "setting(model, \"user/model\").\n"),
    agentprolog_project_config_paths(Root, ProjectPath, _),
    write_text(ProjectPath, "setting(model, \"project/model\").\n"),
    ProjectIdentity = project_identity(test_project, 1),
    Context = _{user_path:UserPath,
                project:_{identity:ProjectIdentity, root:Root}},
    agentprolog_config_resolve(Context, Outcome),
    require_ok(Outcome, Resolution),
    assertion(Resolution.effective.settings.model == "project/model"),
    assertion(Resolution.project.identity == ProjectIdentity),
    assertion(Resolution.sources = [UserSource, ProjectSource]),
    assertion(UserSource.scope == user),
    assertion(ProjectSource.scope == project),
    assertion(ProjectSource.project_identity == ProjectIdentity).

test(project_prolog_shadows_json_deterministically) :-
    with_temp_tree(project_prolog_shadows_json_deterministically_).

project_prolog_shadows_json_deterministically_(Root) :-
    agentprolog_project_config_paths(Root, PrologPath, JsonPath),
    write_text(PrologPath, "setting(model, \"prolog/project\").\n"),
    write_text(JsonPath, "{\"model\":\"json/project\"}\n"),
    Context = _{user_path:none,
                project:_{identity:project(test), root:Root}},
    agentprolog_config_resolve(Context, Outcome),
    require_ok(Outcome, Resolution),
    assertion(Resolution.effective.settings.model == "prolog/project"),
    assertion(Resolution.sources = [ProjectSource]),
    assertion(ProjectSource.format == prolog),
    assertion(ProjectSource.shadowed == [JsonPath]).

test(project_directive_is_data_and_rejected_not_executed) :-
    with_temp_tree(project_directive_is_data_and_rejected_not_executed_).

project_directive_is_data_and_rejected_not_executed_(Root) :-
    directory_file_path(Root, 'config.prolog', Path),
    write_text(Path, ":- initialization(assertz(agentprolog_config_test_pwned)).\n"),
    agentprolog_config_load_file(Path, prolog, Outcome),
    assertion(Outcome = error(Error)),
    assertion(Error.kind == unsupported_prolog_declaration),
    assertion(\+ current_predicate(agentprolog_config_test_pwned/0)).

test(secret_settings_are_rejected) :-
    with_temp_tree(secret_settings_are_rejected_).

secret_settings_are_rejected_(Root) :-
    directory_file_path(Root, 'config.prolog', Path),
    write_text(Path, "setting(openrouter_api_key, \"nope\").\n"),
    agentprolog_config_load_file(Path, prolog, Outcome),
    assertion(Outcome = error(Error)),
    assertion(Error.kind == secret_settings_forbidden).

test(json_include_cannot_escape_config_directory) :-
    with_temp_tree(json_include_cannot_escape_config_directory_).

json_include_cannot_escape_config_directory_(Root) :-
    directory_file_path(Root, 'cfg', ConfigDir),
    make_directory_path(ConfigDir),
    directory_file_path(Root, 'outside.json', Outside),
    write_text(Outside, "{\"model\":\"outside/model\"}\n"),
    directory_file_path(ConfigDir, 'config.prolog', Path),
    write_text(Path, "json(\"../outside.json\").\n"),
    agentprolog_config_load_file(Path, prolog, Outcome),
    assertion(Outcome = error(Error)),
    assertion(Error.kind == json_include_escapes_config_directory).

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

test(defaults_are_lossless_openrouter_without_deepseek_dependency) :-
    agentprolog_config_resolve(_{user_path:none}, Outcome),
    require_ok(Outcome, Resolution),
    assertion(Resolution.effective.settings.provider == "openrouter"),
    assertion(Resolution.effective.settings.model == "openrouter/free"),
    assertion(Resolution.effective.settings.history_mode == "lossless_rlm"),
    assertion(Resolution.effective.settings.compaction == false).

:- end_tests(agentprolog_config).
