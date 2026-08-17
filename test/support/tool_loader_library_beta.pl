:- module(tool_loader_library_beta,
          [ beta_echo/2
          ]).

:- use_module('../../prolog/rlm_tool').
:- use_module('../../prolog/rlm_tool_loader').

:- multifile rlm_tool_loader:tool_pack/2.
:- multifile rlm_tool_loader:tool_pack_manifest/2.

rlm_tool_loader:tool_pack(beta_filesystem,
                          tool_loader_library_beta:load_beta_filesystem).
rlm_tool_loader:tool_pack_manifest(
    beta_filesystem,
    tool_pack_manifest{
        library:beta_fixture_library,
        category:filesystem,
        tools:[tool_export{name:beta_echo,
                           capability:tool(beta_echo),
                           effect:read}]
    }).

load_beta_filesystem(Registry, Outcome) :-
    Schema = tool_schema{
                 name:beta_echo,
                 description:"beta external loader fixture",
                 capability:tool(beta_echo),
                 effect:read,
                 arguments:_{type:object,
                             required:[value],
                             additional_properties:false,
                             properties:_{value:_{type:integer}}},
                 result:_{type:integer},
                 limits:_{time_limit:1.0, max_output_bytes:1024}
             },
    tool_register(Registry,
                  Schema,
                  tool_loader_library_beta:beta_echo,
                  RegisterOutcome),
    (   RegisterOutcome = ok(_)
    ->  Outcome = ok(tool_pack{pack:beta_filesystem,
                               registered:[beta_echo]})
    ;   Outcome = RegisterOutcome
    ).

beta_echo(Args, Value) :-
    Value = Args.value.
