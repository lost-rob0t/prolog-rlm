:- begin_tests(deepseek_harness_route_store).

:- use_module('../agentProlog/deepseek-harness/prolog/deepseek_prolog_route_store').

test(memory_round_trip,
     [ setup(open_memory_routes),
       cleanup(close_routes)
     ]) :-
    deepseek_route_store_put("session-a",
                             2,
                             "openrouter",
                             "deepseek/deepseek-chat",
                             PutOutcome),
    assertion(PutOutcome = ok(_)),
    deepseek_route_store_get("session-a", 2, GetOutcome),
    GetOutcome = ok(Route),
    assertion(Route.provider == openrouter),
    assertion(Route.model == 'deepseek/deepseek-chat').

test(missing_route_is_explicit,
     [ setup(open_memory_routes),
       cleanup(close_routes)
     ]) :-
    deepseek_route_store_get("session-missing", 2, Outcome),
    assertion(Outcome = error(Error)),
    assertion(Error.kind == not_found).

test(persistent_round_trip_survives_detach,
     [ setup(temp_route_path(Path)),
       cleanup(cleanup_route_path(Path))
     ]) :-
    deepseek_route_store_open(persist(Path), OpenOutcome),
    assertion(OpenOutcome = ok(_)),
    deepseek_route_store_put("persisted-session",
                             4,
                             "deepseek",
                             "deepseek-v4-pro",
                             PutOutcome),
    assertion(PutOutcome = ok(_)),
    deepseek_route_store_close(CloseOutcome),
    assertion(CloseOutcome == ok(closed)),
    deepseek_route_store_open(persist(Path), ReopenOutcome),
    assertion(ReopenOutcome = ok(_)),
    deepseek_route_store_get("persisted-session", 4, GetOutcome),
    GetOutcome = ok(Route),
    assertion(Route.provider == deepseek),
    assertion(Route.model == 'deepseek-v4-pro'),
    deepseek_route_store_close(_).

open_memory_routes :-
    deepseek_route_store_open(memory, Outcome),
    (   Outcome = ok(_)
    ->  true
    ;   throw(Outcome)
    ).

close_routes :-
    deepseek_route_store_close(_).

temp_route_path(Path) :-
    tmp_file_stream(text, Path, Stream),
    close(Stream),
    delete_file(Path).

cleanup_route_path(Path) :-
    deepseek_route_store_close(_),
    (   exists_file(Path)
    ->  delete_file(Path)
    ;   true
    ).

:- end_tests(deepseek_harness_route_store).
