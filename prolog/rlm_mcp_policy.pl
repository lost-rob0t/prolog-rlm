:- module(rlm_mcp_policy,
          [ mcp_install_recipe_normalize/2,
            mcp_stdio_recipe_normalize/2,
            mcp_environment_normalize/2,
            mcp_working_directory_normalize/2,
            mcp_install_preflight/4,
            mcp_stdio_preflight/4,
            mcp_prepare_install/4,
            mcp_prepare_stdio/4,
            mcp_environment_metadata/2,
            mcp_working_directory_metadata/2
          ]).

/** <module> Hard execution policy for declarative MCP lifecycle

Server declarations select trusted host profiles. They never carry executable
paths, installer argv, runtime argv, or raw environment values. Profile lookup,
package syntax validation, configuration-reference validation and working
Directory confinement happen before host authority is consulted. Secret values
are resolved only by the explicit lifecycle continuation after authority permits
execution and are never returned by this module as metadata.
*/

:- use_module(library(lists)).

:- multifile mcp_installer_profile/2.
:- multifile mcp_stdio_profile/2.
:- multifile mcp_config_value/2.

/* -------------------------------------------------------------------------
 * Declarative recipe normalization
 * ---------------------------------------------------------------------- */

mcp_install_recipe_normalize(none, none) :- !.
mcp_install_recipe_normalize(package(Profile0, Package0, Version0),
                             package(Profile, Package, Version)) :-
    !,
    normalize_profile_name(Profile0, Profile),
    process_profile(installer, Profile, Spec),
    normalize_package(Spec.package_format, Package0, Package),
    normalize_version(Version0, Version).
mcp_install_recipe_normalize(Recipe, _) :-
    throw(mcp_policy_fault(invalid_install_recipe(Recipe))).

mcp_stdio_recipe_normalize(profile(Profile0), profile(Profile)) :-
    !,
    normalize_profile_name(Profile0, Profile),
    process_profile(stdio, Profile, _).
mcp_stdio_recipe_normalize(package(Profile0, Package0, Version0),
                           package(Profile, Package, Version)) :-
    !,
    normalize_profile_name(Profile0, Profile),
    process_profile(stdio, Profile, Spec),
    normalize_package(Spec.package_format, Package0, Package),
    normalize_version(Version0, Version).
mcp_stdio_recipe_normalize(Recipe, _) :-
    throw(mcp_policy_fault(invalid_stdio_recipe(Recipe))).

normalize_profile_name(Name, Name) :-
    atom(Name),
    Name \== '',
    safe_identifier_atom(Name),
    !.
normalize_profile_name(Name, _) :-
    throw(mcp_policy_fault(invalid_profile_name(Name))).

/* -------------------------------------------------------------------------
 * First-class configuration references
 * ---------------------------------------------------------------------- */

mcp_environment_normalize(Environment0, Environment) :-
    is_list(Environment0),
    ground(Environment0),
    !,
    maplist(normalize_environment_binding, Environment0, Environment),
    environment_names(Environment, Names),
    sort(Names, Unique),
    (   same_length(Names, Unique)
    ->  true
    ;   throw(mcp_policy_fault(duplicate_environment_binding))
    ).
mcp_environment_normalize(Environment, _) :-
    throw(mcp_policy_fault(invalid_environment(Environment))).

normalize_environment_binding(env(Name0, Ref0), env(Name, Ref)) :-
    !,
    normalize_environment_name(Name0, Name),
    normalize_config_reference(Ref0, Ref).
normalize_environment_binding(Binding, _) :-
    throw(mcp_policy_fault(invalid_environment_binding(Binding))).

environment_names([], []).
environment_names([env(Name, _)|Bindings], [Name|Names]) :-
    environment_names(Bindings, Names).

normalize_environment_name(Name0, Name) :-
    text_atom(Name0, Name),
    atom_chars(Name, [First|Rest]),
    environment_first_char(First),
    maplist(environment_rest_char, Rest),
    !.
normalize_environment_name(Name, _) :-
    throw(mcp_policy_fault(invalid_environment_name(Name))).

environment_first_char(Char) :-
    char_type(Char, alpha),
    !.
environment_first_char('_').

environment_rest_char(Char) :-
    char_type(Char, alnum),
    !.
environment_rest_char('_').

normalize_config_reference(env_ref(Name0), env_ref(Name)) :-
    !,
    normalize_environment_name(Name0, Name).
normalize_config_reference(config_ref(Key), config_ref(Key)) :-
    atom(Key),
    Key \== '',
    safe_identifier_atom(Key),
    !.
normalize_config_reference(Ref, _) :-
    throw(mcp_policy_fault(invalid_config_reference(Ref))).

mcp_environment_metadata(Environment, Metadata) :-
    maplist(environment_binding_metadata, Environment, Metadata).

environment_binding_metadata(env(Target, env_ref(Name)),
                             mcp_config_reference{target:Target,
                                                  kind:environment,
                                                  name:Name}).
environment_binding_metadata(env(Target, config_ref(Key)),
                             mcp_config_reference{target:Target,
                                                  kind:config,
                                                  name:Key}).

/* -------------------------------------------------------------------------
 * Working-directory policy
 * ---------------------------------------------------------------------- */

mcp_working_directory_normalize(inherit, inherit) :- !.
mcp_working_directory_normalize(directory(Path0), directory(Path)) :-
    !,
    text_atom(Path0, Path),
    is_absolute_file_name(Path),
    Path \== '/',
    !.
mcp_working_directory_normalize(Value, _) :-
    throw(mcp_policy_fault(invalid_working_directory(Value))).

mcp_working_directory_metadata(inherit, inherit).
mcp_working_directory_metadata(directory(_), configured).

/* -------------------------------------------------------------------------
 * Policy preflight before authority
 * ---------------------------------------------------------------------- */

mcp_install_preflight(package(Profile, _, _), Environment, WorkingDirectory,
                      Details) :-
    process_profile(installer, Profile, Spec),
    configuration_available(Environment),
    validate_working_directory(WorkingDirectory, Spec, _),
    mcp_environment_metadata(Environment, EnvironmentMetadata),
    mcp_working_directory_metadata(WorkingDirectory, CwdMetadata),
    Details = mcp_execution_policy{profile:Profile,
                                   environment:EnvironmentMetadata,
                                   working_directory:CwdMetadata,
                                   timeout:Spec.timeout,
                                   max_output_bytes:Spec.max_output_bytes}.
mcp_install_preflight(none, _, _, mcp_execution_policy{profile:none}).

mcp_stdio_preflight(profile(Profile), Environment, WorkingDirectory, Details) :-
    process_profile(stdio, Profile, Spec),
    configuration_available(Environment),
    validate_working_directory(WorkingDirectory, Spec, _),
    mcp_environment_metadata(Environment, EnvironmentMetadata),
    mcp_working_directory_metadata(WorkingDirectory, CwdMetadata),
    Details = mcp_execution_policy{profile:Profile,
                                   environment:EnvironmentMetadata,
                                   working_directory:CwdMetadata}.
mcp_stdio_preflight(package(Profile, _, _), Environment, WorkingDirectory,
                    Details) :-
    mcp_stdio_preflight(profile(Profile), Environment, WorkingDirectory,
                        Details).

configuration_available([]).
configuration_available([env(_, Ref)|Bindings]) :-
    config_reference_available(Ref),
    configuration_available(Bindings).

config_reference_available(env_ref(Name)) :-
    (   getenv(Name, Value),
        text_value(Value),
        Value \== ''
    ->  true
    ;   config_reference_metadata(env_ref(Name), Metadata),
        throw(mcp_policy_fault(missing_configuration(Metadata)))
    ).
config_reference_available(config_ref(Key)) :-
    config_values(Key, Values),
    config_values_available(Key, Values).

config_values(Key, Values) :-
    findall(Value, mcp_config_value(Key, Value), Values).

config_values_available(Key, [], _) :-
    config_reference_metadata(config_ref(Key), Metadata),
    throw(mcp_policy_fault(missing_configuration(Metadata))).
config_values_available(Key, [_|[_|_]], _) :-
    throw(mcp_policy_fault(duplicate_configuration(Key))).
config_values_available(Key, [Value], _) :-
    (   ground(Value), text_value(Value), Value \== ''
    ->  true
    ;   throw(mcp_policy_fault(invalid_configuration_value(Key)))
    ).

config_values_available(Key, Values) :-
    config_values_available(Key, Values, available).

config_reference_metadata(env_ref(Name),
                          mcp_config_reference{kind:environment, name:Name}).
config_reference_metadata(config_ref(Key),
                          mcp_config_reference{kind:config, name:Key}).

/* -------------------------------------------------------------------------
 * Trusted preparation after authority permits execution
 * ---------------------------------------------------------------------- */

mcp_prepare_install(package(Profile, Package, Version), Environment,
                    WorkingDirectory, Prepared) :-
    process_profile(installer, Profile, Spec),
    package_argv(Spec, Package, Version, Args),
    resolve_environment(Environment, ResolvedEnvironment),
    validate_working_directory(WorkingDirectory, Spec, Cwd),
    Prepared = mcp_prepared_process{profile:Profile,
                                    executable:Spec.executable,
                                    argv:Args,
                                    environment:ResolvedEnvironment,
                                    cwd:Cwd,
                                    timeout:Spec.timeout,
                                    max_output_bytes:Spec.max_output_bytes}.

mcp_prepare_stdio(profile(Profile), Environment, WorkingDirectory, Prepared) :-
    process_profile(stdio, Profile, Spec),
    profile_static_argv(Spec, Args),
    resolve_environment(Environment, ResolvedEnvironment),
    validate_working_directory(WorkingDirectory, Spec, Cwd),
    Prepared = mcp_prepared_process{profile:Profile,
                                    executable:Spec.executable,
                                    argv:Args,
                                    environment:ResolvedEnvironment,
                                    cwd:Cwd,
                                    timeout:Spec.timeout,
                                    max_output_bytes:Spec.max_output_bytes}.
mcp_prepare_stdio(package(Profile, Package, Version), Environment,
                  WorkingDirectory, Prepared) :-
    process_profile(stdio, Profile, Spec),
    package_argv(Spec, Package, Version, Args),
    resolve_environment(Environment, ResolvedEnvironment),
    validate_working_directory(WorkingDirectory, Spec, Cwd),
    Prepared = mcp_prepared_process{profile:Profile,
                                    executable:Spec.executable,
                                    argv:Args,
                                    environment:ResolvedEnvironment,
                                    cwd:Cwd,
                                    timeout:Spec.timeout,
                                    max_output_bytes:Spec.max_output_bytes}.

resolve_environment([], []).
resolve_environment([env(Name, Ref)|Bindings], [Name=Value|Resolved]) :-
    resolve_config_reference(Ref, Value),
    resolve_environment(Bindings, Resolved).

resolve_config_reference(env_ref(Name), Value) :-
    (   getenv(Name, Found),
        text_value(Found),
        Found \== ''
    ->  Value = Found
    ;   config_reference_metadata(env_ref(Name), Metadata),
        throw(mcp_policy_fault(missing_configuration(Metadata)))
    ).
resolve_config_reference(config_ref(Key), Value) :-
    config_values(Key, Values),
    resolve_config_values(Key, Values, Value).

resolve_config_values(Key, [], _) :-
    config_reference_metadata(config_ref(Key), Metadata),
    throw(mcp_policy_fault(missing_configuration(Metadata))).
resolve_config_values(Key, [_|[_|_]], _) :-
    throw(mcp_policy_fault(duplicate_configuration(Key))).
resolve_config_values(Key, [Value], Value) :-
    (   ground(Value), text_value(Value), Value \== ''
    ->  true
    ;   throw(mcp_policy_fault(invalid_configuration_value(Key)))
    ).

/* -------------------------------------------------------------------------
 * Trusted profile lookup and closed schema
 * ---------------------------------------------------------------------- */

process_profile(Kind, Name, Spec) :-
    profile_candidates(Kind, Name, Specs),
    profile_result(Kind, Name, Specs, Spec0),
    normalize_process_profile(Spec0, Spec).

profile_candidates(installer, Name, Specs) :-
    findall(Spec, mcp_installer_profile(Name, Spec), Specs).
profile_candidates(stdio, Name, Specs) :-
    findall(Spec, mcp_stdio_profile(Name, Spec), Specs).

profile_result(Kind, Name, [], _) :-
    throw(mcp_policy_fault(unallowed_execution_profile(Kind, Name))).
profile_result(Kind, Name, [_|[_|_]], _) :-
    throw(mcp_policy_fault(duplicate_execution_profile(Kind, Name))).
profile_result(_, _, [Spec], Spec).

normalize_process_profile(Spec0, Spec) :-
    is_dict(Spec0, mcp_process_profile),
    closed_profile_dict(Spec0),
    get_dict(executable, Spec0, Executable),
    normalize_executable(Executable, NormalizedExecutable),
    get_dict(argv_prefix, Spec0, Prefix),
    get_dict(argv_suffix, Spec0, Suffix),
    validate_static_argv(Prefix),
    validate_static_argv(Suffix),
    get_dict(package_format, Spec0, PackageFormat),
    valid_package_format(PackageFormat),
    get_dict(cwd_roots, Spec0, CwdRoots),
    validate_cwd_roots(CwdRoots),
    get_dict(timeout, Spec0, Timeout),
    bounded_timeout(Timeout),
    get_dict(max_output_bytes, Spec0, MaxOutputBytes),
    bounded_output(MaxOutputBytes),
    Spec = mcp_process_profile{executable:NormalizedExecutable,
                               argv_prefix:Prefix,
                               argv_suffix:Suffix,
                               package_format:PackageFormat,
                               cwd_roots:CwdRoots,
                               timeout:Timeout,
                               max_output_bytes:MaxOutputBytes},
    !.
normalize_process_profile(Spec, _) :-
    throw(mcp_policy_fault(invalid_execution_profile(Spec))).

closed_profile_dict(Spec) :-
    dict_pairs(Spec, mcp_process_profile, Pairs),
    length(Pairs, 7),
    forall(member(Key-_, Pairs), allowed_profile_key(Key)).

allowed_profile_key(executable).
allowed_profile_key(argv_prefix).
allowed_profile_key(argv_suffix).
allowed_profile_key(package_format).
allowed_profile_key(cwd_roots).
allowed_profile_key(timeout).
allowed_profile_key(max_output_bytes).

normalize_executable(path(Name), path(Name)) :-
    atom(Name),
    Name \== '',
    safe_executable_name(Name),
    !.
normalize_executable(file(Path0), file(Path)) :-
    text_atom(Path0, Path),
    is_absolute_file_name(Path),
    Path \== '',
    file_base_name(Path, Base),
    safe_executable_name(Base),
    !.
normalize_executable(Executable, _) :-
    throw(mcp_policy_fault(invalid_profile_executable(Executable))).

safe_executable_name(Name) :-
    \+ memberchk(Name, [sh,bash,zsh,dash,ksh,fish,powershell,pwsh,cmd,'cmd.exe']).

validate_static_argv(Args) :-
    is_list(Args),
    ground(Args),
    maplist(valid_static_arg, Args),
    !.
validate_static_argv(Args) :-
    throw(mcp_policy_fault(invalid_profile_argv(Args))).

valid_static_arg(Arg) :- atomic(Arg), !.
valid_static_arg(Arg) :-
    throw(mcp_policy_fault(invalid_profile_argument(Arg))).

valid_package_format(npm).
valid_package_format(pip).
valid_package_format(plain).

validate_cwd_roots(Roots) :-
    is_list(Roots),
    ground(Roots),
    maplist(valid_cwd_root, Roots),
    !.
validate_cwd_roots(Roots) :-
    throw(mcp_policy_fault(invalid_cwd_roots(Roots))).

valid_cwd_root(Root0) :-
    text_atom(Root0, Root),
    is_absolute_file_name(Root),
    Root \== '/'.

bounded_timeout(Value) :-
    number(Value),
    Value > 0,
    Value =< 300.

bounded_output(Value) :-
    integer(Value),
    Value >= 0,
    Value =< 1048576.

/* -------------------------------------------------------------------------
 * Package and argv construction
 * ---------------------------------------------------------------------- */

normalize_package(Format, Package0, Package) :-
    text_atom(Package0, Package),
    package_atom_valid(Format, Package),
    !.
normalize_package(_, Package, _) :-
    throw(mcp_policy_fault(invalid_package_name(Package))).

normalize_version(Version0, Version) :-
    text_atom(Version0, Version),
    atom_length(Version, Length),
    Length > 0,
    Length =< 128,
    atom_chars(Version, Chars),
    Chars = [First|_],
    First \== '-',
    maplist(version_char, Chars),
    !.
normalize_version(Version, _) :-
    throw(mcp_policy_fault(invalid_package_version(Version))).

package_atom_valid(npm, Package) :-
    atom_length(Package, Length),
    Length > 0,
    Length =< 214,
    npm_package_shape(Package).
package_atom_valid(pip, Package) :-
    conservative_package(Package).
package_atom_valid(plain, Package) :-
    conservative_package(Package).

conservative_package(Package) :-
    atom_chars(Package, [First|Chars]),
    First \== '-',
    conservative_package_char(First),
    maplist(conservative_package_char, Chars).

npm_package_shape(Package) :-
    atom_chars(Package, ['@'|Rest]),
    !,
    Rest \== [],
    \+ memberchk('@', Rest),
    append(Scope, ['/ '|_], Rest),
    Scope \== [],
    npm_chars(Rest).
npm_package_shape(Package) :-
    atom_chars(Package, [First|Rest]),
    First \== '-',
    First \== '@',
    \+ memberchk('/', Rest),
    npm_chars([First|Rest]).

npm_chars(Chars) :-
    maplist(npm_package_char, Chars).

npm_package_char(Char) :-
    char_type(Char, alnum),
    !.
npm_package_char(Char) :- memberchk(Char, ['-','_','.','/']).

conservative_package_char(Char) :-
    char_type(Char, alnum),
    !.
conservative_package_char(Char) :- memberchk(Char, ['-','_','.']).

version_char(Char) :-
    char_type(Char, alnum),
    !.
version_char(Char) :- memberchk(Char, ['-','_','.','+']).

package_argv(Spec, Package, Version, Args) :-
    package_argument(Spec.package_format, Package, Version, PackageArg),
    append(Spec.argv_prefix, [PackageArg|Spec.argv_suffix], Args).

profile_static_argv(Spec, Args) :-
    append(Spec.argv_prefix, Spec.argv_suffix, Args).

package_argument(npm, Package, Version, Argument) :-
    atomic_list_concat([Package, '@', Version], Argument).
package_argument(pip, Package, Version, Argument) :-
    atomic_list_concat([Package, '==', Version], Argument).
package_argument(plain, Package, Version, Argument) :-
    atomic_list_concat([Package, '=', Version], Argument).

/* -------------------------------------------------------------------------
 * CWD confinement
 * ---------------------------------------------------------------------- */

validate_working_directory(inherit, _, inherit) :- !.
validate_working_directory(directory(Path), Spec, Canonical) :-
    Spec.cwd_roots \== [],
    canonical_directory(Path, Canonical),
    member(Root0, Spec.cwd_roots),
    canonical_directory(Root0, Root),
    path_within_root(Canonical, Root),
    !.
validate_working_directory(directory(_), _, _) :-
    throw(mcp_policy_fault(working_directory_not_allowed(configured))).

canonical_directory(Path, Canonical) :-
    (   absolute_file_name(Path,
                           Canonical,
                           [ file_type(directory),
                             access(execute),
                             solutions(first),
                             file_errors(fail)
                           ])
    ->  true
    ;   throw(mcp_policy_fault(invalid_working_directory(configured)))
    ).

path_within_root(Path, Root) :- Path == Root, !.
path_within_root(Path, Root) :-
    ensure_trailing_slash(Root, Prefix),
    sub_atom(Path, 0, _, _, Prefix).

ensure_trailing_slash(Root, Root) :- sub_atom(Root, _, 1, 0, '/'), !.
ensure_trailing_slash(Root, Prefix) :- atom_concat(Root, '/', Prefix).

/* -------------------------------------------------------------------------
 * Small validators
 * ---------------------------------------------------------------------- */

safe_identifier_atom(Atom) :-
    atom_chars(Atom, Chars),
    Chars \== [],
    maplist(identifier_char, Chars).

identifier_char(Char) :-
    char_type(Char, alnum),
    !.
identifier_char(Char) :- memberchk(Char, ['_','-','.',' ':']).

text_atom(Value, Value) :- atom(Value), !.
text_atom(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
text_atom(Value, _) :-
    throw(mcp_policy_fault(expected_text(Value))).

text_value(Value) :- atom(Value), !.
text_value(Value) :- string(Value).
