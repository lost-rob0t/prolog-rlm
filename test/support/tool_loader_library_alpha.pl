:- module(tool_loader_library_alpha,
          [ alpha_echo/2,
            alpha_git_echo/2
          ]).

:- use_module('../../prolog/rlm_tool').
:- use_module('../../prolog/rlm_tool_loader').

:- multifile rlm_tool_loader:tool_pack/2.
:- multifile rlm_tool_loader:tool_pack_manifest/2.

rlm_tool_loader:tool_pack(alpha_filesystem,
                          tool_loader_library_alpha:load_alpha_filesystem).
rlm_tool_loader:tool_pack_manifest(
    alpha_filesystem,
    tool_pack_manifest{
        library:alpha_fixture_library,
        category:filesystem,
        tools:[tool_export{name:alpha_echo,
                           capability:tool(alpha_echo),
                           effect:read}]
    }).

rlm_tool_loader:tool_pack(alpha_git,
                          tool_loader_library_alpha:load_alpha_git).
rlm_tool_loader:tool_pack_manifest(
    alpha_git,
    tool_pack_manifest{
        library:alpha_fixture_library,
        category:git,
        tools:[tool_export{name:alpha_git_echo,
                           capability:tool(alpha_git_echo),
                           effect:read}]
    }).

load_alpha_filesystem(Registry, Outcome) :-
    alpha_schema(alpha_echo, Schema),
    tool_register(Registry,
                  Schema,
                  tool_loader_library_alpha:alpha_echo,
                  RegisterOutcome),
    finish_registration(RegisterOutcome, alpha_filesystem, [alpha_echo], Outcome).

load_alpha_git(Registry, Outcome) :-
    alpha_schema(alpha_git_echo, Schema),
    tool_register(Registry,
                  Schema,
                  tool_loader_library_alpha:alpha_git_echo,
                  RegisterOutcome),
    finish_registration(RegisterOutcome, alpha_git, [alpha_git_echo], Outcome).

finish_registration(ok(_), Pack, Tools,
                    ok(tool_pack{pack:Pack, registered:Tools})) :- !.
finish_registration(error(Error), _, _, error(Error)).

alpha_schema(Name,
             tool_schema{
                 name:Name,
                 description:"alpha external loader fixture",
                 capability:tool(Name),
                 effect:read,
                 arguments:_{type:object,
                             required:[value],
                             additional_properties:false,
                             properties:_{value:_{type:integer}}},
                 result:_{type:integer},
                 limits:_{time_limit:1.0, max_output_bytes:1024}
             }).

alpha_echo(Args, Value) :-
    Value = Args.value.

alpha_git_echo(Args, Value) :-
    Value = Args.value.
