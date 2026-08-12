:- initialization(main, main).

:- use_module(library(plunit)).
:- consult(live_openrouter_test).
:- consult(live_plan_openrouter_test).
:- consult(live_tool_openrouter_test).
:- consult(live_completion_openrouter_test).
:- consult(live_repair_openrouter_test).

main(_) :-
    (   run_tests([live_openrouter,
                   live_plan_openrouter,
                   live_tool_openrouter,
                   live_completion_openrouter,
                   live_repair_openrouter])
    ->  halt(0)
    ;   halt(1)
    ).
