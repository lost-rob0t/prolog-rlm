:- begin_tests(rlm_expert).

:- use_module('../prolog/rlm_expert').

:- dynamic provider_call/0.

pure_read(read(File), _, path(File)).
pure_search(search(Query, _), _, query(Query)).
unbounded(_, _, _) :- unbounded(_, _, _).
open_result(_, _, partial(_)).
cyclic_result(_, _, Cyclic) :- Cyclic = cycle(Cyclic).
large_result(_, _, Values) :- length(Values, 3000), maplist(=(x), Values).
secret_exception(_, _, _) :- throw(error(secret_password, private_context)).
cancelled_handler(_, _, _) :- throw(error(rlm_cancelled(cancel_token), expert)).
timeout_handler(_, _, _) :- throw(time_limit_exceeded).

contract(Id, Goal, Priority, Requires, Handler,
         expert_contract{id:Id, version:1, goal:Goal,
                         priority:Priority, requires:Requires,
                         handler:plunit_rlm_expert:Handler}).

test(symbolic_selection_and_pure_invocation) :-
    retractall(provider_call),
    expert_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( contract(reader, read/1, 10, [tool(read)], pure_read, Read),
          contract(searcher, search/2, 10, [tool(search)], pure_search, Search),
          expert_register(Registry, Read, ok(reader)),
          expert_register(Registry, Search, ok(searcher)),
          expert_call(Registry, read('notes.md'),
                      expert_context{capabilities:[tool(read)]}, ok(Result)),
          assertion(Result.expert_id == reader),
          assertion(Result.value == path('notes.md')),
          assertion(\+ provider_call),
          expert_catalog(Registry, Catalog),
          assertion(length(Catalog, 2)),
          assertion(\+ (member(Item, Catalog), get_dict(handler, Item, _)))
        ),
        expert_registry_destroy(Registry)).

test(missing_capability_blocks_handler) :-
    expert_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( contract(reader, read/1, 10, [tool(read)], pure_read, Read),
          expert_register(Registry, Read, ok(reader)),
          expert_call(Registry, read(secret),
                      expert_context{capabilities:[]}, error(Error)),
          assertion(Error.kind == no_eligible_expert),
          assertion(Error.candidates ==
                    [expert_candidate{id:reader, version:1, priority:10,
                                      reason:missing_capability([tool(read)])}])
        ),
        expert_registry_destroy(Registry)).

test(equal_priority_is_structured_ambiguity) :-
    expert_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( contract(one, read/1, 10, [], pure_read, One),
          contract(two, read/1, 10, [], pure_read, Two),
          expert_register(Registry, One, ok(one)),
          expert_register(Registry, Two, ok(two)),
          expert_select(Registry, read(file),
                        expert_context{capabilities:[]}, error(Error)),
          assertion(Error.kind == ambiguous_experts),
          assertion(Error.experts == [one, two])
        ),
        expert_registry_destroy(Registry)).

test(plan_native_operation_is_not_expert) :-
    expert_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( contract(runner, run/1, 10, [], pure_read, Run),
          expert_register(Registry, Run, error(Error)),
          assertion(Error.kind == plan_native_excluded)
        ),
        expert_registry_destroy(Registry)).

test(explicit_invocation_rechecks_goal_and_capability) :-
    expert_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( contract(reader, read/1, 10, [tool(read)], pure_read, Read),
          expert_register(Registry, Read, ok(reader)),
          expert_invoke(Registry, reader, search(x, y),
                        expert_context{capabilities:[tool(read)]},
                        error(ShapeError)),
          assertion(ShapeError.candidate.reason == goal_mismatch),
          expert_invoke(Registry, reader, read(secret),
                        expert_context{capabilities:[]},
                        error(CapError)),
          assertion(CapError.candidate.reason ==
                    missing_capability([tool(read)]))
        ),
        expert_registry_destroy(Registry)).

test(duplicate_id_does_not_replace_trusted_handler) :-
    expert_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( contract(reader, read/1, 10, [], pure_read, First),
          contract(reader, search/2, 50, [], pure_search, Replacement),
          expert_register(Registry, First, ok(reader)),
          expert_register(Registry, Replacement, error(Duplicate)),
          assertion(Duplicate.kind == duplicate_expert),
          expert_call(Registry, read(file),
                      expert_context{capabilities:[]}, ok(Result)),
          assertion(Result.value == path(file))
        ),
        expert_registry_destroy(Registry)).

test(local_work_limit_stops_nonterminating_expert) :-
    expert_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( contract(looper, read/1, 10, [], unbounded, Loop),
          expert_register(Registry, Loop, ok(looper)),
          expert_call(Registry, read(file),
                      expert_context{capabilities:[]}, error(Error)),
          assertion(Error.kind == work_limit_exceeded)
        ),
        expert_registry_destroy(Registry)).

test(rejects_open_cyclic_and_oversized_results) :-
    expert_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( forall(member(Id-Handler, [open-open_result,
                                     cyclic-cyclic_result,
                                     large-large_result]),
                 ( contract(Id, read/1, 1, [], Handler, Contract),
                   expert_register(Registry, Contract, ok(Id)),
                   expert_invoke(Registry, Id, read(file),
                                 expert_context{capabilities:[]}, error(Error)),
                   assertion(Error.kind == invalid_result) ))
        ),
        expert_registry_destroy(Registry)).

test(exception_is_sanitized_and_timeout_is_distinct) :-
    expert_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( contract(secret, read/1, 1, [], secret_exception, Secret),
          contract(timeout, read/1, 1, [], timeout_handler, Timeout),
          expert_register(Registry, Secret, ok(secret)),
          expert_register(Registry, Timeout, ok(timeout)),
          expert_invoke(Registry, secret, read(file),
                        expert_context{capabilities:[]}, error(SecretError)),
          assertion(SecretError.kind == handler_exception),
          term_string(SecretError, PublicText),
          assertion(\+ sub_string(PublicText, _, _, _, "secret_password")),
          expert_invoke(Registry, timeout, read(file),
                        expert_context{capabilities:[]}, error(TimeoutError)),
          assertion(TimeoutError.kind == handler_timeout)
        ),
        expert_registry_destroy(Registry)).

test(cancellation_propagates) :-
    expert_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( contract(cancel, read/1, 1, [], cancelled_handler, Contract),
          expert_register(Registry, Contract, ok(cancel)),
          catch(expert_invoke(Registry, cancel, read(file),
                              expert_context{capabilities:[]}, _),
                error(rlm_cancelled(cancel_token), _), Caught = true),
          assertion(Caught == true)
        ),
        expert_registry_destroy(Registry)).

:- end_tests(rlm_expert).
