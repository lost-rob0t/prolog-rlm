:- module(plan_test_tools,
          [ count_items/2,
            mark/2,
            marked/0,
            reset_marks/0,
            flaky/2,
            reset_flaky/0,
            large_payload/2
          ]).

/** <module> Trusted host closures for plan-runtime tests

These predicates are supplied by host test configuration. They are not model
plan operators and cannot be named into existence without a corresponding
`tool(Name, Handler)` runtime entry.
*/

:- dynamic mark_seen/0.
:- dynamic flaky_count/1.

count_items(Items, Count) :-
    is_list(Items),
    length(Items, Count).

mark(Value, Value) :-
    assertz(mark_seen).

marked :-
    mark_seen.

reset_marks :-
    retractall(mark_seen).

reset_flaky :-
    retractall(flaky_count(_)),
    assertz(flaky_count(0)).

flaky(Value, Value) :-
    retract(flaky_count(Count0)),
    Count is Count0+1,
    assertz(flaky_count(Count)),
    (   Count =:= 1
    ->  throw(error(transient_test_failure, context(plan_test_tools, flaky)))
    ;   true
    ).

large_payload(_, Payload) :-
    Payload = "0123456789012345678901234567890123456789".
