:- module(plan_graph_test_tools,
          [ reset_calls/0,
            record_call/2,
            expert_call/2,
            index_handler/2,
            read_handler/2,
            search_handler/2,
            fail_handler/2,
            cancel_handler/2,
            verifier_handler/2,
            spawn_handler/2
          ]).

/** <module> Host-supplied expert closures for plan-graph tests

Handlers live in a real module so that module-qualified closure atoms are
visible from rlm_plan's trusted tool invocation path, mirroring how
production hosts register expert closures.
*/

:- dynamic(expert_call/2).

reset_calls :-
    retractall(expert_call(_, _)).

record_call(Name, Args) :-
    assertz(expert_call(Name, Args)).

index_handler(_Args, ok(indexed)) :-
    record_call(index, called).

read_handler(_Args, ok(read)) :-
    record_call(read, called).

search_handler(_Args, ok(searched)) :-
    record_call(search, called).

%% failing read expert -> tool error -> step failed
fail_handler(_Args, _Result) :-
    record_call(read, called),
    fail.

%% handler that throws cancellation
cancel_handler(_Args, _Result) :-
    record_call(sync_remote, called),
    throw(error(rlm_cancelled(tok123), context(cancel_test))).

%% host verifier closure for validate/1
verifier_handler(Args, Result) :-
    record_call(validate, Args),
    (   Args == validate(spec(fingerprint(fp001)))
    ->  Result = ok(spec_verify_result{status:satisfied})
    ;   Result = error(verify_mismatch(Args))
    ).

spawn_handler(_Args, ok(spawned)) :-
    record_call(spawn_agent, called).
