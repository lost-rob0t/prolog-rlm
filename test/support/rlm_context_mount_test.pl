:- begin_tests(rlm_context_mount).

:- use_module(library(filesex)).
:- use_module('../../prolog/rlm_artifact').
:- use_module('../../prolog/rlm_context').
:- use_module('../../prolog/rlm_context_mount').

with_memory_store(Goal) :-
    setup_call_cleanup(
        artifact_store_open(memory, ok(Store)),
        call(Goal, Store),
        ( context_mount_runtime_reset,
          artifact_store_close(Store, _)
        )).

with_persistent_store(Goal) :-
    tmp_file(rlm_context_mount, File),
    setup_call_cleanup(
        true,
        call(Goal, File),
        ( context_mount_runtime_reset,
          catch(delete_file(File), _, true)
        )).

persistent_mount_survives(File) :-
    artifact_store_open(persist(File), ok(Store1)),
    context_mount(Store1,
                  project_rules,
                  text("alpha persistent context omega"),
                  [lifetime(persistent),scope(project(demo))],
                  ok(Binding1)),
    assertion(Binding1.mount.visibility == opaque),
    assertion(Binding1.mount.version =:= 1),
    artifact_store_close(Store1, ok(closed)),
    context_mount_runtime_reset,
    artifact_store_open(persist(File), ok(Store2)),
    context_mount_resolve(Store2,
                          project_rules,
                          project(demo),
                          [],
                          ok(Resolution)),
    context_slice(Resolution.context_ref.handle,
                  0,
                  32,
                  [],
                  ok(Slice)),
    assertion(sub_string(Slice.value, _, _, _, "persistent context")),
    artifact_store_close(Store2, ok(closed)).

test(persistent_mount_survives_store_reopen_and_handle_rehydration) :-
    with_persistent_store(persistent_mount_survives).

default_opaque(Store) :-
    context_mount(Store,
                  rules,
                  text("SECRET-CONTEXT-BYTES"),
                  [lifetime(persistent),scope(project(demo))],
                  ok(Binding)),
    assertion(Binding.mount.visibility == opaque),
    context_mount_metadata(Store,
                           rules,
                           project(demo),
                           ok(Metadata)),
    assertion(\+ get_dict(source, Metadata, _)),
    assertion(\+ sub_term("SECRET-CONTEXT-BYTES", Metadata)),
    context_mount_prompt(Store,
                         rules,
                         project(demo),
                         [],
                         error(Error)),
    assertion(Error.operation == prompt).

test(persistent_context_is_opaque_by_default) :-
    with_memory_store(default_opaque).

prompt_projection(Store) :-
    context_mount(Store,
                  prompt_rules,
                  text("0123456789ABCDEFGHIJ"),
                  [ lifetime(persistent),
                    scope(project(demo)),
                    visibility(prompt)
                  ],
                  ok(_)),
    context_mount_prompt(Store,
                         prompt_rules,
                         project(demo),
                         [max_chars(10)],
                         ok(Projection)),
    assertion(Projection.text == "0123456789"),
    assertion(Projection.truncated == true),
    assertion(Projection.max_chars =:= 10).

test(prompt_visibility_is_explicit_and_bounded) :-
    with_memory_store(prompt_projection).

idempotent_mount(Store) :-
    Options = [lifetime(persistent),scope(project(demo))],
    context_mount(Store, rules, text("same"), Options, ok(First)),
    context_mount(Store, rules, text("same"), Options, ok(Second)),
    assertion(First.mount.artifact_ref == Second.mount.artifact_ref),
    assertion(Second.mount.version =:= 1),
    context_mount(Store, rules, text("changed"), Options, ok(Third)),
    assertion(Third.mount.version =:= 2),
    assertion(Third.mount.source_fingerprint \== First.mount.source_fingerprint).

test(identical_persistent_mount_is_idempotent_but_changed_source_versions) :-
    with_memory_store(idempotent_mount).

unmount_tombstone(Store) :-
    Options = [lifetime(persistent),scope(project(demo))],
    context_mount(Store, rules, text("mounted"), Options, ok(_)),
    context_mount_unmount(Store,
                          rules,
                          project(demo),
                          ok(Unmounted)),
    assertion(Unmounted.state == unmounted),
    context_mount_runtime_reset,
    context_mount_resolve(Store,
                          rules,
                          project(demo),
                          [],
                          error(Error)),
    assertion(Error.operation == resolve).

test(unmount_is_durable_tombstone_and_blocks_resolution) :-
    with_memory_store(unmount_tombstone).

scope_isolation(Store) :-
    context_mount(Store,
                  rules,
                  text("project-a"),
                  [lifetime(persistent),scope(project(a))],
                  ok(_)),
    context_mount_resolve(Store,
                          rules,
                          project(b),
                          [],
                          error(Error)),
    assertion(Error.operation == resolve).

test(scope_is_part_of_mount_identity) :-
    with_memory_store(scope_isolation).

session_lifetime(Store) :-
    context_mount(Store,
                  session_rules,
                  terms([rule(a),rule(b)]),
                  [lifetime(session),scope(session(run_1))],
                  ok(First)),
    context_mount_resolve(Store,
                          session_rules,
                          session(run_1),
                          [],
                          ok(Second)),
    assertion(First.context_ref.handle == Second.context_ref.handle),
    context_mount_runtime_reset,
    context_mount_resolve(Store,
                          session_rules,
                          session(run_1),
                          [],
                          error(Error)),
    assertion(Error.operation == resolve).

test(session_mount_is_process_local_not_durable) :-
    with_memory_store(session_lifetime).

ephemeral_lifetime(Store) :-
    context_mount(Store,
                  one_shot,
                  text("temporary"),
                  [lifetime(ephemeral)],
                  ok(Binding)),
    context_slice(Binding.context_ref.handle,
                  0,
                  9,
                  [],
                  ok(Slice)),
    assertion(Slice.value == "temporary"),
    context_mount_resolve(Store,
                          one_shot,
                          runtime,
                          [],
                          error(Error)),
    assertion(Error.operation == resolve).

test(ephemeral_mount_returns_handle_without_named_resolution_state) :-
    with_memory_store(ephemeral_lifetime).

:- end_tests(rlm_context_mount).
