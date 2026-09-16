:- begin_tests(rlm_expert).

:- use_module('../prolog/rlm_expert').

:- dynamic provider_call/0.

pure_read(read(File), _, path(File)).
pure_search(search(Query, _), _, query(Query)).
unbounded(_, _, _) :- unbounded(_, _, _).

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

:- end_tests(rlm_expert).
