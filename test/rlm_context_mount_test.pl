:- begin_tests(rlm_context_mount).

:- use_module('../prolog/rlm_artifact').
:- use_module('../prolog/rlm_context').
:- use_module('../prolog/rlm_context_mount').

with_two_memory_stores(Goal) :-
    setup_call_cleanup(
        ( artifact_store_open(memory, ok(StoreA)),
          artifact_store_open(memory, ok(StoreB))
        ),
        call(Goal, StoreA, StoreB),
        ( context_mount_runtime_reset,
          artifact_store_close(StoreA, _),
          artifact_store_close(StoreB, _)
        )).

cross_store_cache_isolation(StoreA, StoreB) :-
    Options = [lifetime(persistent), scope(project(demo))],
    context_mount(StoreA,
                  rules,
                  text("STORE-A-CONTEXT"),
                  Options,
                  ok(BindingA)),
    context_mount(StoreB,
                  rules,
                  text("STORE-B-CONTEXT"),
                  Options,
                  ok(BindingB)),
    context_slice(BindingA.context_ref.handle,
                  0,
                  64,
                  [],
                  ok(SliceA)),
    context_slice(BindingB.context_ref.handle,
                  0,
                  64,
                  [],
                  ok(SliceB)),
    assertion(SliceA.value == "STORE-A-CONTEXT"),
    assertion(SliceB.value == "STORE-B-CONTEXT"),
    assertion(BindingA.context_ref.handle \== BindingB.context_ref.handle).

test(persistent_cache_is_partitioned_by_artifact_store) :-
    with_two_memory_stores(cross_store_cache_isolation).

:- end_tests(rlm_context_mount).
