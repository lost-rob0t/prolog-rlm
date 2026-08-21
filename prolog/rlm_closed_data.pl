:- module(rlm_closed_data,
          [ closed_data_normalize/2
          ]).

/** <module> Deterministic normalization for closed runtime data

SWI-Prolog's anonymous dict syntax (`_{...}`) uses a fresh variable as the
internal dict tag.  That representation detail must not make otherwise closed
runtime data fail `ground/1` checks or acquire a different hash on every call.

This helper recursively replaces only anonymous dict tags with the stable
`rlm_anonymous_dict` atom.  Named dict tags remain semantic.  Genuine variables
inside values and cyclic terms fail closed.
*/

closed_data_normalize(Value, Normalized) :-
    (   acyclic_term(Value)
    ->  closed_data_normalize_(Value, Normalized)
    ;   throw(rlm_closed_data_fault(cyclic_value))
    ).

closed_data_normalize_(Value, _) :-
    var(Value),
    !,
    throw(rlm_closed_data_fault(non_ground_value)).
closed_data_normalize_(Value, Normalized) :-
    is_dict(Value),
    !,
    dict_pairs(Value, Tag0, Pairs0),
    closed_dict_tag(Tag0, Tag),
    keysort(Pairs0, Sorted),
    maplist(closed_pair, Sorted, Pairs),
    dict_pairs(Normalized, Tag, Pairs).
closed_data_normalize_(Value, Normalized) :-
    is_list(Value),
    !,
    maplist(closed_data_normalize_, Value, Normalized).
closed_data_normalize_(Value, Normalized) :-
    compound(Value),
    !,
    Value =.. [Functor|Args0],
    maplist(closed_data_normalize_, Args0, Args),
    Normalized =.. [Functor|Args].
closed_data_normalize_(Value, Value) :-
    atomic(Value),
    !.
closed_data_normalize_(_, _) :-
    throw(rlm_closed_data_fault(unsupported_value)).

closed_dict_tag(Tag0, rlm_anonymous_dict) :-
    var(Tag0),
    !.
closed_dict_tag(Tag, Tag) :-
    atom(Tag),
    !.
closed_dict_tag(_, _) :-
    throw(rlm_closed_data_fault(invalid_dict_tag)).

closed_pair(Key-Value0, Key-Value) :-
    closed_data_normalize_(Value0, Value).
