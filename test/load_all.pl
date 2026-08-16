:- initialization(main, main).

:- use_module('../prolog/rlm').
:- use_module('../prolog/rlm_tool_loader', []).
:- use_module('../prolog/rlm_mcp_server', []).
:- use_module('../prolog/rlm_mcp_tool', []).

main(_) :-
    (   rlm:rlm_ready
    ->  halt(0)
    ;   halt(1)
    ).
