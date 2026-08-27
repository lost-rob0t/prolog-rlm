:- begin_tests(rlm_context).

:- use_module('../prolog/rlm_artifact').
:- use_module('../prolog/rlm_context').
:- use_module('../prolog/rlm_context_mount').

test(large_text_stays_opaque_and_is_queryable) :-
    make_large_text(Text),
    context_register(text(Text), [], ok(Ref)),
    get_dict(handle, Ref, Handle),
    get_dict(metadata, Ref, Metadata),
    assertion(Metadata.kind == text),
    assertion(Metadata.bytes > 20000),
    term_string(Ref, RefText),
    assertion(\+ sub_string(RefText, _, _, _, "needle payload")),
    context_search(Handle, "needle", [max_results(3), max_bytes(512)],
                   ok(SearchResult)),
    get_dict(value, SearchResult, Matches),
    assertion(length(Matches, 3)),
    get_dict(trace, SearchResult, Trace),
    assertion(Trace.bytes_inspected > 0),
    assertion(Trace.items_inspected > 0),
    assertion(Trace.truncated == true),
    context_delete(Handle, ok(_)).

test(term_context_supports_peek_slice_map_and_reduce) :-
    Terms = [alpha(1), beta(2), gamma(3), delta(4)],
    context_register(terms(Terms), [], ok(Ref)),
    Handle = Ref.handle,
    context_peek(Handle, item(1), [], ok(Peek)),
    assertion(Peek.value == beta(2)),
    context_slice(Handle, 1, 2, [], ok(Slice)),
    assertion(Slice.value == [beta(2), gamma(3)]),
    context_map(Handle, uppercase, [max_results(2)], ok(Map)),
    assertion(Map.value == ["ALPHA(1)", "BETA(2)"]),
    assertion(Map.truncated == true),
    context_reduce(Handle, count, [], ok(Reduce)),
    assertion(Reduce.value =:= 4),
    context_delete(Handle, ok(_)).

test(search_result_count_is_bounded) :-
    Text = "hit one\nhit two\nhit three\nhit four\nhit five",
    context_register(text(Text), [], ok(Ref)),
    Handle = Ref.handle,
    context_search(Handle, "hit", [max_results(2)], ok(Result)),
    assertion(length(Result.value, 2)),
    assertion(Result.truncated == true),
    context_delete(Handle, ok(_)).

test(partition_total_payload_respects_global_byte_budget) :-
    string_repeat("abcdefghij", 20, Text),
    context_register(text(Text), [], ok(Ref)),
    Handle = Ref.handle,
    context_partition(Handle, fixed(30),
                      [max_results(3), max_bytes(60)], ok(Result)),
    partition_payload_bytes(Result.value, Bytes),
    assertion(Bytes =< 60),
    assertion(Result.truncated == true),
    context_delete(Handle, ok(_)).

test(partition_count_is_bounded) :-
    string_repeat("0123456789", 20, Text),
    context_register(text(Text), [], ok(Ref)),
    Handle = Ref.handle,
    context_partition(Handle, fixed(10), [max_results(2)], ok(Result)),
    assertion(length(Result.value, 2)),
    assertion(Result.truncated == true),
    context_delete(Handle, ok(_)).

test(unsupported_sources_cannot_dereference_filesystem) :-
    context_register(file('/etc/passwd'), [], error(Error)),
    assertion(Error.kind == unsupported_source),
    assertion(Error.source_shape == file/1).

test(unknown_and_malformed_handles_are_structured_errors) :-
    context_metadata(not_a_handle, error(Malformed)),
    assertion(Malformed.kind == invalid_handle),
    context_metadata(context_handle('00000000-0000-4000-8000-000000000000', 1),
                     error(Unknown)),
    assertion(Unknown.kind == unknown_handle).

test(deleted_handle_becomes_stale) :-
    context_register(text("temporary"), [], ok(Ref)),
    Handle = Ref.handle,
    context_delete(Handle, ok(_)),
    context_metadata(Handle, error(Error)),
    assertion(Error.kind == stale_handle).

test(map_rejects_arbitrary_callable) :-
    context_register(terms([a,b,c]), [], ok(Ref)),
    Handle = Ref.handle,
    context_map(Handle, call(shell), [], error(Error)),
    assertion(Error.kind == capability_denied),
    context_delete(Handle, ok(_)).

test(reduce_rejects_arbitrary_callable) :-
    context_register(terms([a,b,c]), [], ok(Ref)),
    Handle = Ref.handle,
    context_reduce(Handle, call(system), [], error(Error)),
    assertion(Error.kind == capability_denied),
    context_delete(Handle, ok(_)).

test(invalid_partition_size_is_structured) :-
    context_register(text("abcdef"), [], ok(Ref)),
    Handle = Ref.handle,
    context_partition(Handle, fixed(0), [], error(Error)),
    assertion(Error.kind == invalid_argument),
    context_delete(Handle, ok(_)).

test(trace_history_records_inspection_metrics) :-
    context_register(text("alpha\nbeta\ngamma"), [], ok(Ref)),
    Handle = Ref.handle,
    context_peek(Handle, head(5), [], ok(_)),
    context_search(Handle, "beta", [], ok(_)),
    context_trace(Handle, 10, ok(Events)),
    assertion(length(Events, 2)),
    Events = [First, Second],
    assertion(First.sequence =:= 1),
    assertion(Second.sequence =:= 2),
    assertion(First.bytes_inspected > 0),
    assertion(Second.items_inspected > 0),
    context_delete(Handle, ok(_)).

test(invalid_limits_fail_without_executing_context_operation) :-
    context_register(text("abcdef"), [], ok(Ref)),
    Handle = Ref.handle,
    context_peek(Handle, head(2), [max_bytes(0)], error(Error)),
    assertion(Error.kind == invalid_limit),
    context_delete(Handle, ok(_)).

test(backend_declares_no_filesystem_or_network_capability) :-
    context_backend(memory, Caps),
    assertion(Caps.filesystem == false),
    assertion(Caps.network == false),
    assertion(Caps.persistent == false).

test(persistent_mount_rehydrates_canonical_persisted_text_source) :-
    setup_call_cleanup(
        artifact_store_open(memory, ok(Store)),
        ( Options = [lifetime(persistent), scope(project(demo))],
          context_mount(Store,
                        canonical_text,
                        text("CANONICAL-PERSISTED-CONTEXT"),
                        Options,
                        ok(Binding)),
          context_slice(Binding.context_ref.handle,
                        0,
                        64,
                        [],
                        ok(Slice)),
          assertion(Slice.value == "CANONICAL-PERSISTED-CONTEXT")
        ),
        ( context_mount_runtime_reset,
          artifact_store_close(Store, _)
        )).

test(persistent_mount_cache_is_partitioned_by_artifact_store) :-
    setup_call_cleanup(
        ( artifact_store_open(memory, ok(StoreA)),
          artifact_store_open(memory, ok(StoreB))
        ),
        ( Options = [lifetime(persistent), scope(project(demo))],
          context_mount(StoreA,
                        rules,
                        text("STORE-A-CONTEXT"),
                        Options,
                        MountAOutcome),
          expect_ok(mount_a, MountAOutcome, BindingA),
          context_mount(StoreB,
                        rules,
                        text("STORE-B-CONTEXT"),
                        Options,
                        MountBOutcome),
          expect_ok(mount_b, MountBOutcome, BindingB),
          context_slice(BindingA.context_ref.handle,
                        0,
                        64,
                        [],
                        SliceAOutcome),
          expect_ok(slice_a, SliceAOutcome, SliceA),
          context_slice(BindingB.context_ref.handle,
                        0,
                        64,
                        [],
                        SliceBOutcome),
          expect_ok(slice_b, SliceBOutcome, SliceB),
          assertion(SliceA.value == "STORE-A-CONTEXT"),
          assertion(SliceB.value == "STORE-B-CONTEXT"),
          assertion(BindingA.context_ref.handle \==
                    BindingB.context_ref.handle)
        ),
        ( context_mount_runtime_reset,
          artifact_store_close(StoreA, _),
          artifact_store_close(StoreB, _)
        )).

expect_ok(_, ok(Value), Value) :- !.
expect_ok(Stage, Outcome, _) :-
    throw(error(unexpected_context_mount_outcome(Stage, Outcome), _)).

make_large_text(Text) :-
    findall(Line,
            ( between(1, 2500, N),
              format(string(Line), "row-~d needle payload\n", [N])
            ),
            Lines),
    atomics_to_string(Lines, "", Text).

string_repeat(Unit, Count, Text) :-
    findall(Unit, between(1, Count, _), Units),
    atomics_to_string(Units, "", Text).

partition_payload_bytes(Partitions, Bytes) :-
    findall(Size,
            ( member(Partition, Partitions),
              get_dict(value, Partition, Value),
              string_bytes(Value, Octets, utf8),
              length(Octets, Size)
            ),
            Sizes),
    sum_list(Sizes, Bytes).

:- end_tests(rlm_context).
