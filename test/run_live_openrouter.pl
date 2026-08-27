:- initialization(main, main).

:- use_module(library(plunit)).
:- consult(live_openrouter_test).
:- consult(live_chain_stream_openrouter_test).
:- consult(live_plan_openrouter_test).
:- consult(live_tool_openrouter_test).
:- consult(live_completion_openrouter_test).
:- consult(live_planner_context_openrouter_test).

main(_) :-
    (   run_tests([live_openrouter,
                   live_chain_stream_openrouter,
                   live_plan_openrouter,
                   live_tool_openrouter,
                   live_completion_openrouter,
                   live_planner_context_openrouter])
    ->  halt(0)
    ;   halt(1)
    ).
