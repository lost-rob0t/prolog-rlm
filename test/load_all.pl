:- initialization(main, main).

:- use_module('../prolog/rlm').
:- use_module('../prolog/rlm_effect', []).
:- use_module('../prolog/rlm_effect_authority', []).
:- use_module('../prolog/rlm_effect_persist', []).
:- use_module('../prolog/rlm_tool_loader', []).
:- use_module('../prolog/rlm_mcp_policy', []).
:- use_module('../prolog/rlm_mcp_server', []).
:- use_module('../prolog/rlm_mcp_tool', []).
:- use_module('../prolog/rlm_mcp_tool_pack', []).

main(_) :-
    (   rlm:rlm_ready
    ->  halt(0)
    ;   halt(1)
    ).
