:- begin_tests(agentprolog_config_relative).

:- use_module(library(filesex)).
:- use_module('../agentProlog/prolog/agentprolog_config').

with_temp_config_tree(Goal) :-
    tmp_file(agentprolog_config_relative, Root),
    make_directory_path(Root),
    setup_call_cleanup(true,
                       call(Goal, Root),
                       delete_directory_and_contents(Root)).

write_config_text(Path, Text) :-
    file_directory_name(Path, Directory),
    make_directory_path(Directory),
    setup_call_cleanup(open(Path, write, Stream, [encoding(utf8)]),
                       format(Stream, '~s', [Text]),
                       close(Stream)).

require_config_ok(ok(Value), Value).

test(relative_use_module_resolves_from_real_config_directory) :-
    with_temp_config_tree(relative_use_module_resolves_from_real_config_directory_).

relative_use_module_resolves_from_real_config_directory_(Root) :-
    directory_file_path(Root, 'config_helper.pl', HelperPath),
    directory_file_path(Root, 'config.prolog', ConfigPath),
    write_config_text(
        HelperPath,
        ":- module(config_helper, [preferred_model/1]).\npreferred_model(\"relative/model\").\n"),
    write_config_text(
        ConfigPath,
        ":- use_module('./config_helper.pl').\nsetting(model, Model) :- preferred_model(Model).\n"),
    agentprolog_config_load_file(ConfigPath, prolog, Outcome),
    require_config_ok(Outcome, Source),
    assertion(Source.patch.settings.model == "relative/model"),
    Module = Source.module,
    assertion(call(Module:preferred_model("relative/model"))).

test(relative_import_survives_explicit_reload_generation) :-
    with_temp_config_tree(relative_import_survives_explicit_reload_generation_).

relative_import_survives_explicit_reload_generation_(Root) :-
    directory_file_path(Root, 'config_helper.pl', HelperPath),
    directory_file_path(Root, 'config.prolog', ConfigPath),
    write_config_text(
        HelperPath,
        ":- module(config_helper_reload, [preferred_model/1]).\npreferred_model(\"first/model\").\n"),
    write_config_text(
        ConfigPath,
        ":- use_module('./config_helper.pl').\nsetting(model, Model) :- preferred_model(Model).\n"),
    agentprolog_config_load_file(ConfigPath, prolog, FirstOutcome),
    require_config_ok(FirstOutcome, First),
    assertion(First.patch.settings.model == "first/model"),
    write_config_text(
        HelperPath,
        ":- module(config_helper_reload, [preferred_model/1]).\npreferred_model(\"second/model\").\n"),
    load_files(HelperPath, [if(changed), silent(true)]),
    agentprolog_config_reload_file(ConfigPath, prolog, SecondOutcome),
    require_config_ok(SecondOutcome, Second),
    assertion(Second.generation > First.generation),
    assertion(Second.module \== First.module),
    assertion(Second.patch.settings.model == "second/model").

:- end_tests(agentprolog_config_relative).
