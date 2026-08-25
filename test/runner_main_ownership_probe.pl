:- initialization(probe_main, main).

:- consult(run_tool_mcp_async_tests).

probe_main :-
    format('aggregate_main_owner=probe~n'),
    halt(0).
