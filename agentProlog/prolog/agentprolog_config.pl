:- module(agentprolog_config,
          [ agentprolog_config_ready/0,
            agentprolog_config_defaults/1,
            agentprolog_config_default_path/1,
            agentprolog_config_json_path/1,
            agentprolog_project_config_paths/3,
            agentprolog_config_load_file/3,
            agentprolog_config_reload_file/3,
            agentprolog_config_normalize/2,
            agentprolog_config_resolve/2,
            agentprolog_config_save_file/4
          ]).

/** <module> Programmable AgentProlog configuration

AgentProlog has two configuration front doors:

  * trusted executable Prolog in `config.prolog`;
  * JSON consumed by the same Prolog configuration runtime.

The XDG user `config.prolog` is deliberately host code, closer to an Emacs init
file than a static preferences document. It may contain directives, imports,
helper predicates, rules, initialization hooks and future hook/tool/detector
registrations.

Executable config is not re-run every time a frontend asks for effective
settings. An explicit load/reload creates a fresh isolated config generation;
`agentprolog_config_resolve/2` reuses the active generation until it is
explicitly reloaded or invalidated by a trusted write. A failed candidate load
never replaces the last active projected source.

Each executable generation is compiled from the real config file stream under a
generation-specific synthetic source identifier located in the same directory.
This avoids SWI's single-module ownership of traditional source files while
preserving the expected directory context for relative includes/imports. The
real path remains the canonical AgentProlog source identity.

Repository-local `.agentprolog/config.prolog` is different from the user's XDG
file: discovery alone is not execution authority. The resolver loads project
config only when the trusted host marks that explicit structured project
identity as trusted.

Trusted executable configuration has the privileges of the AgentProlog process.
That is intentional. AgentProlog-managed tools/effects registered from config
still use their canonical invocation boundaries, but arbitrary trusted config
itself is host extension code and is not capability-sandboxed.

`agentprolog_config_save_file/4` is a trusted whole-file writer, not a model
operation. Frontends must mediate config edits through the normal AgentProlog
mutation authority/effect path before calling a trusted writer. Files written by
this module are replaced through a temporary file and forced to POSIX mode
0600.
*/

:- use_module(library(apply)).
:- use_module(library(filesex)).
:- use_module(library(http/json)).
:- use_module(library(lists)).
:- use_module(library(readutil), [read_file_to_string/3]).
:- use_module(library(uuid)).

:- dynamic config_generation_counter/1.
:- dynamic active_config_source/5.
:- thread_local config_load_watch/1.
:- thread_local config_load_diagnostics/3.

:- multifile user:message_hook/3.

user:message_hook(load_file_errors(Source, Errors, Warnings), _, _) :-
    agentprolog_config:record_config_load_diagnostics(Source,
                                                      Errors,
                                                      Warnings),
    fail.

config_generation_counter(0).

agentprolog_config_ready.

/* Paths and defaults -------------------------------------------------- */

agentprolog_config_default_path(Path) :-
    config_root(Root),
    directory_file_path(Root, 'prolog-rlm', RlmDir),
    directory_file_path(RlmDir, 'agentProlog', AgentDir),
    directory_file_path(AgentDir, 'config.prolog', Path).

agentprolog_config_json_path(Path) :-
    config_root(Root),
    directory_file_path(Root, 'prolog-rlm', RlmDir),
    directory_file_path(RlmDir, 'agentProlog', AgentDir),
    directory_file_path(AgentDir, 'config.json', Path).

agentprolog_project_config_paths(ProjectRoot0, PrologPath, JsonPath) :-
    path_atom(ProjectRoot0, ProjectRoot),
    directory_file_path(ProjectRoot, '.agentprolog', ConfigDir),
    directory_file_path(ConfigDir, 'config.prolog', PrologPath),
    directory_file_path(ConfigDir, 'config.json', JsonPath).

agentprolog_config_defaults(Config) :-
    state_root(StateRoot),
    directory_file_path(StateRoot, 'prolog-rlm', RlmStateDir),
    directory_file_path(RlmStateDir, 'agentProlog-conversations.db', StoreAtom),
    atom_string(StoreAtom, Store),
    Config = agentprolog_config{
                 schema_version:1,
                 settings:config_section{provider:"openrouter",
                            model:"openrouter/free",
                            history_mode:"lossless_rlm",
                            compaction:false,
                            persist_sessions:true,
                            conversation_store:Store},
                 extensions:config_section{},
                 tools:config_section{},
                 detectors:config_section{},
                 prompt:config_section{},
                 frontend:config_section{}
             }.

/* Public lifecycle ---------------------------------------------------- */

agentprolog_config_load_file(Path0, Format0, Outcome) :-
    config_outcome(load,
                   agentprolog_config_load_file_(Path0, Format0),
                   Outcome).

agentprolog_config_reload_file(Path0, Format0, Outcome) :-
    config_outcome(reload,
                   agentprolog_config_load_file_(Path0, Format0),
                   Outcome).

agentprolog_config_load_file_(Path0, Format0, Source) :-
    canonical_config_path(Path0, Path),
    resolve_format(Path, Format0, Format),
    next_config_generation(Generation),
    load_candidate(Format, Path, Generation, Module, Patch),
    remember_active_source(Path, Format, Module, Generation, Patch),
    Source = config_source{format:Format,
                           path:Path,
                           module:Module,
                           generation:Generation,
                           patch:Patch}.

agentprolog_config_normalize(Config0, Outcome) :-
    config_outcome(normalize,
                   normalize_effective(Config0),
                   Outcome).

normalize_effective(Config0, Config) :-
    normalize_patch(Config0, Patch),
    agentprolog_config_defaults(Defaults),
    overlay_config(Defaults, Patch, Merged),
    validate_effective(Merged),
    Config = Merged.

agentprolog_config_resolve(Context0, Outcome) :-
    config_outcome(resolve,
                   agentprolog_config_resolve_(Context0),
                   Outcome).

agentprolog_config_resolve_(Context0, Resolution) :-
    normalize_context(Context0, Context),
    agentprolog_config_defaults(Defaults),
    resolve_user_source(Context, UserSource),
    apply_optional_source(Defaults, UserSource, AfterUser),
    resolve_project_source(Context, ProjectSource),
    apply_optional_source(AfterUser, ProjectSource, Effective),
    validate_effective(Effective),
    source_list(UserSource, ProjectSource, Sources),
    Resolution = config_resolution{effective:Effective,
                                   sources:Sources,
                                   project:Context.project,
                                   history_mode:"lossless_rlm",
                                   compaction:false}.

agentprolog_config_save_file(Path0, Format0, Config0, Outcome) :-
    config_outcome(save,
                   agentprolog_config_save_file_(Path0, Format0, Config0),
                   Outcome).

agentprolog_config_save_file_(Path0, Format0, Config0, Saved) :-
    path_atom(Path0, Path),
    resolve_format(Path, Format0, Format),
    normalize_effective(Config0, Config),
    file_directory_name(Path, Directory),
    make_directory_path(Directory),
    uuid(UUID, [version(4)]),
    format(atom(Temporary), '~w.~w.tmp', [Path, UUID]),
    catch(write_atomic_config(Temporary, Path, Format, Config),
          Exception,
          ( catch(delete_file(Temporary), _, true),
            throw(Exception)
          )),
    invalidate_written_path(Path),
    Saved = config_saved{format:Format,
                         path:Path,
                         mode:0o600,
                         config:Config}.

write_atomic_config(Temporary, Path, Format, Config) :-
    setup_call_cleanup(
        open(Temporary, write, Stream, [encoding(utf8)]),
        ( chmod(Temporary, 0o600),
          write_config_stream(Format, Stream, Config),
          flush_output(Stream)
        ),
        close(Stream)),
    rename_file(Temporary, Path),
    chmod(Path, 0o600).

invalidate_written_path(Path0) :-
    (   absolute_file_name(Path0,
                           Path,
                           [ file_type(regular),
                             access(read),
                             file_errors(fail)
                           ])
    ->  with_mutex(agentprolog_config_registry,
                   retractall(active_config_source(Path, _, _, _, _)))
    ;   true
    ).

/* Active-generation cache -------------------------------------------- */

remember_active_source(Path, Format, Module, Generation, Patch) :-
    with_mutex(agentprolog_config_registry,
               ( retractall(active_config_source(Path, _, _, _, _)),
                 assertz(active_config_source(Path,
                                              Format,
                                              Module,
                                              Generation,
                                              Patch))
               )).

cached_or_load_file(Path0, Format0, Source) :-
    canonical_config_path(Path0, Path),
    resolve_format(Path, Format0, Format),
    (   with_mutex(agentprolog_config_registry,
                   active_config_source(Path,
                                        Format,
                                        Module,
                                        Generation,
                                        Patch))
    ->  Source = config_source{format:Format,
                               path:Path,
                               module:Module,
                               generation:Generation,
                               patch:Patch}
    ;   agentprolog_config_load_file_(Path, Format, Source)
    ).

next_config_generation(Generation) :-
    with_mutex(agentprolog_config_registry,
               ( ( retract(config_generation_counter(Current))
                 -> true
                 ;  Current = 0
                 ),
                 Generation is Current + 1,
                 assertz(config_generation_counter(Generation))
               )).

/* Candidate loading --------------------------------------------------- */

load_candidate(json, Path, _, null, Patch) :-
    load_json_patch(Path, Patch).
load_candidate(prolog, Path, Generation, Module, Patch) :-
    fresh_config_module(Generation, Module),
    synthetic_source_id(Path, Generation, SourceId),
    read_file_to_string(Path, SourceText, [encoding(utf8)]),
    setup_call_cleanup(
        open_string(SourceText, Stream),
        setup_call_cleanup(
            assertz(config_load_watch(SourceId)),
            ( catch(load_files(Module:SourceId,
                               [ stream(Stream),
                                 check_script(false),
                                 derived_from(Path),
                                 silent(true)
                               ]),
                    Exception,
                    throw(config_fault(prolog_load_failed(Path,
                                                          Exception)))),
              reject_config_load_errors(Path, SourceId)
            ),
            ( retractall(config_load_watch(SourceId)),
              retractall(config_load_diagnostics(SourceId, _, _))
            )),
        close(Stream)),
    collect_prolog_patch(Module, Path, Patch).

record_config_load_diagnostics(Source, Errors, Warnings) :-
    config_load_watch(Source),
    assertz(config_load_diagnostics(Source, Errors, Warnings)).

reject_config_load_errors(Path, Source) :-
    findall(Errors,
            config_load_diagnostics(Source, Errors, _),
            ErrorCounts),
    sum_list(ErrorCounts, ErrorCount),
    (   ErrorCount =:= 0
    ->  true
    ;   throw(config_fault(prolog_load_failed(Path,
                                              syntax_errors(ErrorCount))))
    ).

fresh_config_module(Generation, Module) :-
    uuid(UUID, [version(4)]),
    format(atom(Module),
           'agentprolog_config_~d_~w',
           [Generation, UUID]).

synthetic_source_id(Path, Generation, SourceId) :-
    file_directory_name(Path, Directory),
    file_base_name(Path, Base),
    uuid(UUID, [version(4)]),
    format(atom(SourceName),
           '.~w.agentprolog-generation-~d-~w',
           [Base, Generation, UUID]),
    directory_file_path(Directory, SourceName, SourceId).

load_json_patch(Path, Patch) :-
    setup_call_cleanup(open(Path, read, Stream, [encoding(utf8)]),
                       json_read_dict(Stream, Raw),
                       close(Stream)),
    normalize_patch(Raw, Patch).

collect_prolog_patch(Module, Path, Patch) :-
    empty_patch(Empty),
    config_values1(Module, json, JsonIncludes),
    config_values1(Module, include_json, MoreIncludes),
    append(JsonIncludes, MoreIncludes, Includes),
    foldl(include_json_overlay(Path), Includes, Empty, AfterJson),
    config_values1(Module, config, Configs),
    foldl(config_value_overlay, Configs, AfterJson, AfterConfig),
    config_values2(Module, section, Sections),
    foldl(section_value_overlay, Sections, AfterConfig, AfterSections),
    config_values2(Module, setting, Settings),
    foldl(setting_value_overlay, Settings, AfterSections, Patch0),
    normalize_patch(Patch0, Patch).

config_values1(Module, Name, Values) :-
    functor(Head, Name, 1),
    (   predicate_property(Module:Head, visible)
    ->  findall(Value,
                ( Goal =.. [Name, Value],
                  call(Module:Goal)
                ),
                Values)
    ;   Values = []
    ).

config_values2(Module, Name, Values) :-
    functor(Head, Name, 2),
    (   predicate_property(Module:Head, visible)
    ->  findall(Key-Value,
                ( Goal =.. [Name, Key, Value],
                  call(Module:Goal)
                ),
                Values)
    ;   Values = []
    ).

include_json_overlay(ConfigPath, Include0, Acc0, Acc) :-
    include_json_patch(ConfigPath, Include0, Patch),
    overlay_config(Acc0, Patch, Acc).

config_value_overlay(Value, Acc0, Acc) :-
    normalize_patch(Value, Patch),
    overlay_config(Acc0, Patch, Acc).

section_value_overlay(Name0-Value0, Acc0, Acc) :-
    normalize_section(Name0, Name),
    normalize_dict_data(Value0, Value),
    section_dict(Acc0, Name, Existing),
    put_dict(Value, Existing, Merged),
    put_dict(Name, Acc0, Merged, Acc).

setting_value_overlay(Key0-Value0, Acc0, Acc) :-
    normalize_key(Key0, Key),
    reject_secret_key(Key),
    normalize_data(Value0, Value),
    section_dict(Acc0, settings, Settings0),
    put_dict(Key, Settings0, Value, Settings),
    put_dict(settings, Acc0, Settings, Acc).

include_json_patch(ConfigPath, Include0, Patch) :-
    normalize_path_text(Include0, IncludeText),
    file_directory_name(ConfigPath, ConfigDir),
    atom_string(IncludeAtom, IncludeText),
    (   is_absolute_file_name(IncludeAtom)
    ->  Candidate = IncludeAtom
    ;   directory_file_path(ConfigDir, IncludeAtom, Candidate)
    ),
    canonical_config_path(Candidate, IncludePath),
    load_json_patch(IncludePath, Patch).

/* Resolution and project trust --------------------------------------- */

normalize_context(Context0, Context) :-
    (   var(Context0)
    ->  Raw = config_context_input{}
    ;   Raw = Context0
    ),
    require_dict(config_context, Raw),
    allowed_context_keys(Raw),
    normalize_user_context(Raw, User),
    normalize_project_context(Raw, Project),
    Context = config_context{user:User, project:Project}.

allowed_context_keys(Context) :-
    dict_keys(Context, Keys),
    subtract(Keys, [user_path, user_format, project], Unknown),
    (   Unknown == []
    ->  true
    ;   throw(config_fault(unknown_context_keys(Unknown)))
    ).

normalize_user_context(Context, User) :-
    (   get_dict(user_path, Context, none)
    ->  User = user_config{mode:none}
    ;   get_dict(user_path, Context, UserPath0)
    ->  path_atom(UserPath0, UserPath),
        dict_default(Context, user_format, auto, UserFormat0),
        normalize_format_selector(UserFormat0, UserFormat),
        User = user_config{mode:explicit,
                           path:UserPath,
                           format:UserFormat}
    ;   User = user_config{mode:discover}
    ).

normalize_project_context(Context, Project) :-
    (   get_dict(project, Context, Project0)
    ->  require_dict(project, Project0),
        allowed_project_keys(Project0),
        require_dict_key(Project0, identity, Identity),
        require_ground_value(project_identity, Identity),
        require_dict_key(Project0, root, Root0),
        path_atom(Root0, Root),
        (   is_absolute_file_name(Root)
        ->  true
        ;   throw(config_fault(project_root_not_absolute(Root)))
        ),
        dict_default(Project0, trusted, false, Trusted),
        require_boolean(Trusted, project_trusted),
        Project = project_config{identity:Identity,
                                 root:Root,
                                 trusted:Trusted}
    ;   Project = none
    ).

allowed_project_keys(Project) :-
    dict_keys(Project, Keys),
    subtract(Keys, [identity, root, trusted], Unknown),
    (   Unknown == []
    ->  true
    ;   throw(config_fault(unknown_project_keys(Unknown)))
    ).

resolve_user_source(Context, Source) :-
    User = Context.user,
    (   User.mode == none
    ->  Source = none
    ;   User.mode == explicit
    ->  load_source(user,
                    none,
                    User.path,
                    User.format,
                    [],
                    Source)
    ;   discover_user_source(Source)
    ).

discover_user_source(Source) :-
    agentprolog_config_default_path(PrologPath),
    agentprolog_config_json_path(JsonPath),
    choose_discovered_source(user,
                             none,
                             PrologPath,
                             JsonPath,
                             Source).

resolve_project_source(Context, Source) :-
    (   Context.project == none
    ->  Source = none
    ;   Project = Context.project,
        agentprolog_project_config_paths(Project.root,
                                         PrologPath,
                                         JsonPath),
        (   Project.trusted == true
        ->  choose_discovered_source(project,
                                     Project.identity,
                                     PrologPath,
                                     JsonPath,
                                     Source)
        ;   discover_blocked_project_source(Project.identity,
                                            PrologPath,
                                            JsonPath,
                                            Source)
        )
    ).

discover_blocked_project_source(Identity, PrologPath, JsonPath, Source) :-
    (   exists_file(PrologPath)
    ->  ( exists_file(JsonPath) -> Shadowed = [JsonPath] ; Shadowed = [] ),
        Source = config_source{scope:project,
                               project_identity:Identity,
                               status:blocked_untrusted,
                               format:prolog,
                               path:PrologPath,
                               module:null,
                               generation:null,
                               shadowed:Shadowed}
    ;   exists_file(JsonPath)
    ->  Source = config_source{scope:project,
                               project_identity:Identity,
                               status:blocked_untrusted,
                               format:json,
                               path:JsonPath,
                               module:null,
                               generation:null,
                               shadowed:[]}
    ;   Source = none
    ).

choose_discovered_source(Scope,
                         Identity,
                         PrologPath,
                         JsonPath,
                         Source) :-
    (   exists_file(PrologPath)
    ->  ( exists_file(JsonPath) -> Shadowed = [JsonPath] ; Shadowed = [] ),
        load_source(Scope,
                    Identity,
                    PrologPath,
                    prolog,
                    Shadowed,
                    Source)
    ;   exists_file(JsonPath)
    ->  load_source(Scope,
                    Identity,
                    JsonPath,
                    json,
                    [],
                    Source)
    ;   Source = none
    ).

load_source(Scope,
            Identity,
            Path,
            Format0,
            Shadowed,
            Source) :-
    cached_or_load_file(Path, Format0, Loaded),
    Source = config_source{scope:Scope,
                           project_identity:Identity,
                           status:loaded,
                           format:Loaded.format,
                           path:Loaded.path,
                           module:Loaded.module,
                           generation:Loaded.generation,
                           shadowed:Shadowed,
                           patch:Loaded.patch}.

apply_optional_source(Config, none, Config) :- !.
apply_optional_source(Config, Source, Config) :-
    Source.status \== loaded,
    !.
apply_optional_source(Config0, Source, Config) :-
    overlay_config(Config0, Source.patch, Config).

source_list(User, Project, Sources) :-
    exclude(==(none), [User, Project], Sources).

/* Canonical ordinary-settings model ---------------------------------- */

empty_patch(agentprolog_config{schema_version:1,
                               settings:config_section{},
                               extensions:config_section{},
                               tools:config_section{},
                               detectors:config_section{},
                               prompt:config_section{},
                               frontend:config_section{}}).

normalize_patch(Value0, Patch) :-
    require_dict(config, Value0),
    (   canonical_shape(Value0)
    ->  normalize_canonical_patch(Value0, Patch)
    ;   normalize_dict_data(Value0, Settings),
        reject_secret_settings(Settings),
        empty_patch(Empty),
        put_dict(settings, Empty, Settings, Patch)
    ).

canonical_shape(Dict) :-
    dict_keys(Dict, Keys),
    member(Key, Keys),
    memberchk(Key,
              [schema_version, settings, extensions, tools, detectors,
               prompt, frontend]),
    !.

normalize_canonical_patch(Value0, Patch) :-
    allowed_config_keys(Value0),
    dict_default(Value0, schema_version, 1, Version),
    require_exact(Version, 1, schema_version),
    normalize_section_dict(Value0, settings, Settings),
    reject_secret_settings(Settings),
    normalize_section_dict(Value0, extensions, Extensions),
    normalize_section_dict(Value0, tools, Tools),
    normalize_section_dict(Value0, detectors, Detectors),
    normalize_section_dict(Value0, prompt, Prompt),
    normalize_section_dict(Value0, frontend, Frontend),
    Patch = agentprolog_config{schema_version:1,
                               settings:Settings,
                               extensions:Extensions,
                               tools:Tools,
                               detectors:Detectors,
                               prompt:Prompt,
                               frontend:Frontend}.

allowed_config_keys(Config) :-
    dict_keys(Config, Keys),
    subtract(Keys,
             [schema_version, settings, extensions, tools, detectors,
              prompt, frontend],
             Unknown),
    (   Unknown == []
    ->  true
    ;   throw(config_fault(unknown_config_keys(Unknown)))
    ).

normalize_section_dict(Config, Name, Value) :-
    dict_default(Config, Name, config_section{}, Raw),
    normalize_dict_data(Raw, Value).

section_dict(Config, Name, Value) :-
    (   get_dict(Name, Config, Existing)
    ->  Value = Existing
    ;   Value = config_section{}
    ).

normalize_section(Name0, Name) :-
    normalize_key(Name0, Name),
    memberchk(Name,
              [settings, extensions, tools, detectors, prompt, frontend]),
    !.
normalize_section(Name, _) :-
    throw(config_fault(unknown_section(Name))).

overlay_config(Base, Patch, Result) :-
    require_exact(Patch.schema_version, 1, schema_version),
    overlay_section(Base, Patch, settings, R1),
    overlay_section(R1, Patch, extensions, R2),
    overlay_section(R2, Patch, tools, R3),
    overlay_section(R3, Patch, detectors, R4),
    overlay_section(R4, Patch, prompt, R5),
    overlay_section(R5, Patch, frontend, R0),
    put_dict(schema_version, R0, 1, Result).

overlay_section(Base, Patch, Name, Result) :-
    section_dict(Base, Name, BaseSection),
    section_dict(Patch, Name, PatchSection),
    put_dict(PatchSection, BaseSection, Merged),
    put_dict(Name, Base, Merged, Result).

validate_effective(Config) :-
    require_exact(Config.schema_version, 1, schema_version),
    Settings = Config.settings,
    require_nonempty_string_setting(Settings, provider),
    require_nonempty_string_setting(Settings, model),
    require_exact_setting(Settings, history_mode, "lossless_rlm"),
    require_exact_setting(Settings, compaction, false),
    require_boolean_setting(Settings, persist_sessions),
    require_nonempty_string_setting(Settings, conversation_store),
    reject_secret_settings(Settings).

require_nonempty_string_setting(Settings, Key) :-
    require_dict_key(Settings, Key, Value),
    (   string(Value),
        string_length(Value, Length),
        Length > 0
    ->  true
    ;   throw(config_fault(invalid_setting(Key, Value)))
    ).

require_exact_setting(Settings, Key, Expected) :-
    require_dict_key(Settings, Key, Value),
    require_exact(Value, Expected, Key).

require_boolean_setting(Settings, Key) :-
    require_dict_key(Settings, Key, Value),
    require_boolean(Value, Key).

require_boolean(true, _) :- !.
require_boolean(false, _) :- !.
require_boolean(Value, Name) :-
    throw(config_fault(invalid_boolean(Name, Value))).

reject_secret_settings(Settings) :-
    dict_keys(Settings, Keys),
    include(secret_key, Keys, Secrets),
    (   Secrets == []
    ->  true
    ;   throw(config_fault(secret_settings_forbidden(Secrets)))
    ).

reject_secret_key(Key) :-
    (   secret_key(Key)
    ->  throw(config_fault(secret_settings_forbidden([Key])))
    ;   true
    ).

secret_key(api_key).
secret_key(openrouter_api_key).
secret_key(deepseek_api_key).
secret_key(token).
secret_key(access_token).
secret_key(password).
secret_key(secret).
secret_key(credentials).
secret_key(credential).

/* Closed JSON-compatible projected values ---------------------------- */

normalize_dict_data(Value0, Value) :-
    require_dict(config_section, Value0),
    dict_pairs(Value0, _, Pairs0),
    maplist(normalize_pair, Pairs0, Pairs),
    dict_pairs(Value, config_section, Pairs).

normalize_pair(Key0-Value0, Key-Value) :-
    normalize_key(Key0, Key),
    normalize_data(Value0, Value).

normalize_data(Value, Value) :-
    number(Value),
    !,
    (   Value =:= Value,
        Value \== 1.0Inf,
        Value \== -1.0Inf
    ->  true
    ;   throw(config_fault(non_finite_number(Value)))
    ).
normalize_data(true, true) :- !.
normalize_data(false, false) :- !.
normalize_data(null, null) :- !.
normalize_data(Value, Value) :-
    string(Value),
    !.
normalize_data(Value, String) :-
    atom(Value),
    !,
    atom_string(Value, String).
normalize_data(Value0, Value) :-
    is_dict(Value0),
    !,
    normalize_dict_data(Value0, Value).
normalize_data(Value0, Value) :-
    is_list(Value0),
    !,
    maplist(normalize_data, Value0, Value).
normalize_data(Value, _) :-
    throw(config_fault(non_json_config_value(Value))).

normalize_key(Key, Key) :-
    atom(Key),
    !.
normalize_key(Key0, Key) :-
    string(Key0),
    !,
    atom_string(Key, Key0).
normalize_key(Key, _) :-
    throw(config_fault(invalid_config_key(Key))).

/* Writing ------------------------------------------------------------- */

write_config_stream(json, Stream, Config) :-
    json_write_dict(Stream, Config, [width(0)]),
    nl(Stream).
write_config_stream(prolog, Stream, Config) :-
    format(Stream,
           '%% AgentProlog trusted executable configuration.~n%% This generated config/1 fact may be freely extended with Prolog code.~n',
           []),
    write_term(Stream,
               config(Config),
               [ quoted(true),
                 portray(false),
                 numbervars(true),
                 fullstop(true),
                 nl(true)
               ]).

/* Format/path helpers ------------------------------------------------- */

normalize_format_selector(prolog, prolog) :- !.
normalize_format_selector(json, json) :- !.
normalize_format_selector(auto, auto) :- !.
normalize_format_selector("prolog", prolog) :- !.
normalize_format_selector("json", json) :- !.
normalize_format_selector("auto", auto) :- !.
normalize_format_selector(Value, _) :-
    throw(config_fault(unsupported_config_format(Value))).

resolve_format(_, Format0, Format) :-
    normalize_format_selector(Format0, Normalized),
    Normalized \== auto,
    !,
    Format = Normalized.
resolve_format(Path, _, Format) :-
    file_name_extension(_, Extension0, Path),
    downcase_atom(Extension0, Extension),
    extension_format(Extension, Format).

extension_format(prolog, prolog) :- !.
extension_format(pl, prolog) :- !.
extension_format(json, json) :- !.
extension_format(Extension, _) :-
    throw(config_fault(unsupported_config_extension(Extension))).

canonical_config_path(Path0, Canonical) :-
    path_atom(Path0, Path),
    require_existing_file(Path),
    (   absolute_file_name(Path,
                           Canonical,
                           [ file_type(regular),
                             access(read),
                             file_errors(fail)
                           ])
    ->  true
    ;   throw(config_fault(config_file_unavailable(Path)))
    ).

require_existing_file(Path) :-
    (   exists_file(Path)
    ->  true
    ;   throw(config_fault(config_file_not_found(Path)))
    ).

normalize_path_text(Value, Text) :-
    (   string(Value)
    ->  Text = Value
    ;   atom(Value)
    ->  atom_string(Value, Text)
    ;   throw(config_fault(invalid_path(Value)))
    ),
    Text \== "",
    !.
normalize_path_text(Value, _) :-
    throw(config_fault(invalid_path(Value))).

path_atom(Value, Value) :-
    atom(Value),
    !.
path_atom(Value, Atom) :-
    string(Value),
    !,
    atom_string(Atom, Value).
path_atom(Value, _) :-
    throw(config_fault(invalid_path(Value))).

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
    ;   throw(config_fault(home_directory_unavailable))
    ).

/* Validation/outcomes ------------------------------------------------- */

require_dict(_, Value) :-
    is_dict(Value),
    !.
require_dict(Name, Value) :-
    throw(config_fault(expected_dict(Name, Value))).

require_dict_key(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(config_fault(missing_key(Key)))
    ).

dict_default(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Existing)
    ->  Value = Existing
    ;   Value = Default
    ).

require_exact(Value, Expected, _) :-
    Value == Expected,
    !.
require_exact(Value, _, Name) :-
    throw(config_fault(invalid_setting(Name, Value))).

require_ground_value(_, Value) :-
    ground(Value),
    !.
require_ground_value(Name, Value) :-
    throw(config_fault(non_ground_value(Name, Value))).

config_outcome(Phase, Goal, Outcome) :-
    catch(( call(Goal, Value),
            Outcome = ok(Value)
          ),
          Exception,
          config_exception(Phase, Exception, Outcome)).

config_exception(Phase, config_fault(Detail), error(Error)) :-
    !,
    fault_kind(Detail, Kind),
    Error = agentprolog_config_error{phase:Phase,
                                     kind:Kind,
                                     detail:Detail,
                                     message:"AgentProlog configuration operation failed"}.
config_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = agentprolog_config_error{phase:Phase,
                                     kind:exception,
                                     exception:Safe,
                                     message:"AgentProlog configuration operation raised an exception"}.

fault_kind(Detail, Kind) :-
    compound(Detail),
    !,
    functor(Detail, Kind, _).
fault_kind(Detail, Detail).

safe_exception(Exception, Safe) :-
    with_output_to(string(Safe),
                   write_term(Exception,
                              [ quoted(true),
                                portray(false),
                                max_depth(14)
                              ])).
