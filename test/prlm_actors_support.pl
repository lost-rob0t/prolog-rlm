:- module(prlm_actors_support,
          [ sup_host_behavior/3,
            sup_flaky_behavior/3,
            sup_counter_behavior/3,
            sup_collector/3
          ]).

sup_host_behavior(_State, _Msg, outcome(counted, [])).
sup_flaky_behavior(State, _, outcome(NewState, [])) :-
    (   State == boom -> fail ; NewState = boom ).
sup_counter_behavior(State, _, outcome(NewState, [])) :-
    (   var(State) -> NewState = 1
    ;   State == none -> NewState = 1
    ;   NewState is State + 1
    ).
sup_collector(State, Msg, outcome(NewState, [])) :-
    (   Msg = actor_failed(Id, _)
    ->  NewState = [failed(Id)|State]
    ;   NewState = [Msg|State]
    ).
