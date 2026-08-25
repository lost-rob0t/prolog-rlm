:- begin_tests(rlm_closed_data).

:- use_module('../prolog/rlm_closed_data').

test(nested_anonymous_dicts_normalize_deterministically) :-
    A = _{b:2, a:_{c:3}},
    B = _{a:_{c:3}, b:2},
    closed_data_normalize(A, NormalA),
    closed_data_normalize(B, NormalB),
    assertion(ground(NormalA)),
    assertion(NormalA == NormalB),
    assertion(is_dict(NormalA, rlm_anonymous_dict)),
    assertion(is_dict(NormalA.a, rlm_anonymous_dict)).

test(named_dict_tags_remain_semantic) :-
    closed_data_normalize(foo{a:1}, Normal),
    assertion(Normal == foo{a:1}).

test(genuine_variable_value_fails_closed,
     [throws(rlm_closed_data_fault(non_ground_value))]) :-
    closed_data_normalize(data{a:_}, _).

test(cyclic_value_fails_closed,
     [throws(rlm_closed_data_fault(cyclic_value))]) :-
    X = cycle(X),
    closed_data_normalize(X, _).

:- end_tests(rlm_closed_data).
