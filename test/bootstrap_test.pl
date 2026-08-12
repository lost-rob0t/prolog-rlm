:- begin_tests(bootstrap).

:- use_module('../prolog/rlm').
:- use_module('support/fake_model_provider').

test(entrypoint_loads_all_runtime_modules) :-
    rlm:rlm_ready.

test(version_is_declared) :-
    rlm:rlm_version(Version),
    atom(Version),
    Version \== ''.

test(fake_provider_is_deterministic) :-
    Request = model_request{messages:[message{role:user, content:"ping"}]},
    fake_model_provider:fake_model_complete(Request, First),
    fake_model_provider:fake_model_complete(Request, Second),
    assertion(First == Second),
    assertion(get_dict(provider, First, fake)),
    assertion(get_dict(content, First, "deterministic fake response")).

test(fake_provider_is_not_in_production_chain_namespace) :-
    \+ current_predicate(rlm_chain:fake_model_complete/2).

:- end_tests(bootstrap).
