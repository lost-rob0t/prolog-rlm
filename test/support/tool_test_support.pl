:- module(tool_test_support,
          [ reset_invocations/0,
            invocation_count/1,
            counting_tool/2,
            slow_tool/2,
            large_tool/2,
            echo_tool/2
          ]).

:- dynamic invocation_counter/1.

reset_invocations :-
    retractall(invocation_counter(_)),
    assertz(invocation_counter(0)).

invocation_count(Count) :-
    (   invocation_counter(Count)
    ->  true
    ;   Count = 0
    ).

counting_tool(Args, json{seen:Value}) :-
    increment_invocations,
    get_dict(value, Args, Value).

slow_tool(_, json{ok:true}) :-
    sleep(0.05).

large_tool(_, Text) :-
    length(Codes, 256),
    maplist(=(0'x), Codes),
    string_codes(Text, Codes).

echo_tool(Args, Args).

increment_invocations :-
    (   retract(invocation_counter(Current))
    ->  true
    ;   Current = 0
    ),
    Next is Current+1,
    assertz(invocation_counter(Next)).
