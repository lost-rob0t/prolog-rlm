:- module(deepseek_prolog_settings,
          [ deepseek_settings_ready/0,
            deepseek_settings_defaults/1,
            deepseek_settings_default_path/1,
            deepseek_settings_load/2,
            deepseek_settings_save/3,
            deepseek_settings_normalize/2,
            deepseek_settings_provider/2
          ]).

/** <module> Persistent settings for the DeepSeek Harness PrologAgent path

Settings are deliberately downstream application state.  They select a model
route and the durable conversation store, but never contain provider secrets.
Canonical sessions use the lossless Prolog-RLM conversation runtime and forbid
summary/replace compaction.
*/

:- use_module(library(filesex)).
:- use_module(library(http/json)).
:- use_module(library(uuid)).
:- use_module('../../../prolog/rlm_chain').

deepseek_settings_ready.

deepseek_settings_default_path(Path) :-
    config_root(Root),
    directory_file_path(Root, 'prolog-rlm', AppDir),
    directory_file_path(AppDir, 'deepseek-harness.json', Path).

deepseek_settings_defaults(Settings) :-
    state_root(StateRoot),
    directory_file_path(StateRoot, 'prolog-rlm', StateDir),
    directory_file_path(StateDir, 'deepseek-harness-conversations.db', Store0),
    atom_string(Store0, Store),
    Settings = _{schema_version:1,
                 driver:"prolog-rlm",
                 history_mode:"lossless_rlm",
                 compaction:false,
                 persist_sessions:true,
                 provider:"openrouter",
                 model:"openrouter/free",
                 conversation_store:Store}.

deepseek_settings_load(Path0, Outcome) :-
    settings_outcome(load,
                     deepseek_settings_load_(Path0),
                     Outcome).

deepseek_settings_load_(Path0, Settings) :-
    text_atom(Path0, Path),
    (   exists_file(Path)
    ->  setup_call_cleanup(
            open(Path, read, Stream, [encoding(utf8)]),
            json_read_dict(Stream, Raw),
            close(Stream)),
        normalize_settings(Raw, Settings)
    ;   deepseek_settings_defaults(Settings)
    ).

deepseek_settings_save(Path0, Settings0, Outcome) :-
    settings_outcome(save,
                     deepseek_settings_save_(Path0, Settings0),
                     Outcome).

deepseek_settings_save_(Path0, Settings0, Settings) :-
    text_atom(Path0, Path),
    normalize_settings(Settings0, Settings),
    file_directory_name(Path, Directory),
    make_directory_path(Directory),
    uuid(UUID, [version(4)]),
    format(atom(Temporary), '~w.~w.tmp', [Path, UUID]),
    setup_call_cleanup(
        open(Temporary, write, Stream, [encoding(utf8)]),
        ( json_write_dict(Stream, Settings, [width(0)]),
          nl(Stream)
        ),
        close(Stream)),
    catch(rename_file(Temporary, Path),
          Exception,
          ( catch(delete_file(Temporary), _, true),
            throw(Exception)
          )).

deepseek_settings_normalize(Settings0, Outcome) :-
    settings_outcome(normalize,
                     normalize_settings(Settings0),
                     Outcome).

normalize_settings(Settings0, Settings) :-
    must_be_dict(Settings0),
    reject_unknown_keys(Settings0),
    deepseek_settings_defaults(Defaults),
    put_dict(Settings0, Defaults, Settings1),
    validate_settings(Settings1),
    Settings = Settings1.

deepseek_settings_provider(Settings0, Outcome) :-
    settings_outcome(provider,
                     deepseek_settings_provider_(Settings0),
                     Outcome).

deepseek_settings_provider_(Settings0, Selection) :-
    normalize_settings(Settings0, Settings),
    atom_string(ProviderName, Settings.provider),
    atom_string(Model, Settings.model),
    provider_term(ProviderName, Model, Provider),
    Selection = provider_selection{name:ProviderName,
                                   model:Model,
                                   provider:Provider}.

provider_term(openrouter, Model, Provider) :-
    !,
    rlm_chain:openrouter_provider(Model, Provider).
provider_term(deepseek, Model, Provider) :-
    !,
    rlm_chain:openai_compatible_provider(
        'https://api.deepseek.com/chat/completions',
        env('DEEPSEEK_API_KEY'),
        Model,
        Provider).
provider_term(Provider, _, _) :-
    throw(settings_fault(unsupported_provider(Provider))).

validate_settings(Settings) :-
    require_exact(Settings.schema_version, 1, schema_version),
    require_exact(Settings.driver, "prolog-rlm", driver),
    require_exact(Settings.history_mode, "lossless_rlm", history_mode),
    require_exact(Settings.compaction, false, compaction),
    require_boolean(Settings.persist_sessions, persist_sessions),
    require_provider(Settings.provider),
    require_nonempty_string(Settings.model, model),
    require_nonempty_string(Settings.conversation_store, conversation_store).

require_provider("openrouter") :- !.
require_provider("deepseek") :- !.
require_provider(Value) :-
    throw(settings_fault(unsupported_provider(Value))).

known_setting_key(schema_version).
known_setting_key(driver).
known_setting_key(history_mode).
known_setting_key(compaction).
known_setting_key(persist_sessions).
known_setting_key(provider).
known_setting_key(model).
known_setting_key(conversation_store).

reject_unknown_keys(Settings) :-
    dict_keys(Settings, Keys),
    include(unknown_setting_key, Keys, Unknown),
    (   Unknown == []
    ->  true
    ;   throw(settings_fault(unknown_settings(Unknown)))
    ).

unknown_setting_key(Key) :-
    \+ known_setting_key(Key).

require_exact(Value, Expected, _) :-
    Value == Expected,
    !.
require_exact(Value, _, Name) :-
    throw(settings_fault(invalid_setting(Name, Value))).

require_boolean(true, _) :- !.
require_boolean(false, _) :- !.
require_boolean(Value, Name) :-
    throw(settings_fault(invalid_setting(Name, Value))).

require_nonempty_string(Value, _) :-
    string(Value),
    string_length(Value, Length),
    Length > 0,
    !.
require_nonempty_string(Value, Name) :-
    throw(settings_fault(invalid_setting(Name, Value))).

config_root(Root) :-
    (   getenv('XDG_CONFIG_HOME', Candidate),
        Candidate \== ''
    ->  Root = Candidate
    ;   home_directory(Home),
        directory_file_path(Home, '.config', Root)
    ).

state_root(Root) :-
    (   getenv('XDG_STATE_HOME', Candidate),
        Candidate \== ''
    ->  Root = Candidate
    ;   home_directory(Home),
        directory_file_path(Home, '.local/state', Root)
    ).

home_directory(Home) :-
    (   getenv('HOME', Home0),
        Home0 \== ''
    ->  Home = Home0
    ;   throw(settings_fault(home_directory_unavailable))
    ).

must_be_dict(Value) :-
    is_dict(Value),
    !.
must_be_dict(Value) :-
    throw(settings_fault(expected_dict(Value))).

text_atom(Value, Value) :-
    atom(Value),
    !.
text_atom(Value, Atom) :-
    string(Value),
    !,
    atom_string(Atom, Value).
text_atom(Value, _) :-
    throw(settings_fault(expected_path(Value))).

settings_outcome(Phase, Goal, Outcome) :-
    catch(( call(Goal, Value),
            Outcome = ok(Value)
          ),
          Exception,
          settings_exception(Phase, Exception, Outcome)).

settings_exception(Phase, settings_fault(Detail), error(Error)) :-
    !,
    Error = settings_error{phase:Phase,
                           kind:settings_error,
                           detail:Detail,
                           message:"DeepSeek Harness settings operation failed"}.
settings_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = settings_error{phase:Phase,
                           kind:exception,
                           exception:Safe,
                           message:"DeepSeek Harness settings operation raised an exception"}.

safe_exception(Exception, Safe) :-
    with_output_to(string(Safe),
                   write_term(Exception,
                              [ quoted(true),
                                portray(false),
                                max_depth(12)
                              ])).
