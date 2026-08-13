:- begin_tests(rlm_artifact).

:- use_module('../prolog/rlm_artifact').
:- use_module('../prolog/rlm_artifact_agent').
:- use_module('../prolog/rlm_artifact_graph').
:- use_module('../prolog/rlm_agent').
:- use_module('../prolog/rlm_graph').

:- dynamic graph_test_store/1.

producer(Run, _{run_id:Run, agent_id:root, call_id:call_1}).

with_memory_store(Goal) :-
    setup_call_cleanup(
        artifact_store_open(memory, ok(Store)),
        call(Goal, Store),
        artifact_store_close(Store, _)).

test(versioned_writes_preserve_superseded_history) :-
    with_memory_store(versioned_history_case).

versioned_history_case(Store) :-
    producer(run_a, Provenance),
    artifact_put(Store,
                 [task, alpha],
                 summary,
                 summary,
                 _{text:"first"},
                 Provenance,
                 ok(V1)),
    artifact_put(Store,
                 [task, alpha],
                 summary,
                 summary,
                 _{text:"corrected"},
                 Provenance,
                 ok(V2)),
    assertion(V1.version =:= 1),
    assertion(V2.version =:= 2),
    artifact_get(Store, V1.ref, ok(Old)),
    assertion(Old.value.text == "first"),
    artifact_latest(Store, [task, alpha], summary, ok(Latest)),
    assertion(Latest.ref == V2.ref),
    artifact_ref_status(Store, V1.ref, ok(stale(V1.ref, V2.ref))),
    artifact_list(Store,
                  [task, alpha],
                  [history(true)],
                  ok(History)),
    length(History, 2),
    artifact_list(Store,
                  [task, alpha],
                  [],
                  ok(Current)),
    Current = [Only],
    assertion(Only.ref == V2.ref).

test(provenance_and_publish_consume_trace_are_explicit) :-
    with_memory_store(producer_consumer_trace_case).

producer_consumer_trace_case(Store) :-
    Producer = _{run_id:producer_run,
                 agent_id:producer_agent,
                 call_id:producer_call},
    artifact_put(Store,
                 [task, trace],
                 finding,
                 finding,
                 _{fact:"durable"},
                 Producer,
                 ok(Artifact)),
    Consumer = _{run_id:fresh_root,
                 agent_id:consumer_agent,
                 call_id:consumer_call},
    artifact_context_refs(Store,
                          [Artifact.ref],
                          [consumer(Consumer)],
                          ok(Pack)),
    assertion(Pack.item_count =:= 1),
    Pack.entries = [Entry],
    assertion(Entry.value.fact == "durable"),
    artifact_trace(Store, [task, trace], ok(Trace)),
    Trace = [Published, Consumed],
    assertion(Published.type == published),
    assertion(Published.producer.run_id == producer_run),
    assertion(Consumed.type == consumed),
    assertion(Consumed.consumer.run_id == fresh_root),
    assertion(Consumed.refs == [Artifact.ref]).

test(stale_ref_handoff_resolves_latest_and_reports_supersession) :-
    with_memory_store(stale_ref_handoff_case).

stale_ref_handoff_case(Store) :-
    producer(run_a, Provenance),
    artifact_put(Store, task, blackboard, blackboard,
                 _{status:"draft"}, Provenance, ok(V1)),
    artifact_put(Store, task, blackboard, blackboard,
                 _{status:"final"}, Provenance, ok(V2)),
    artifact_context_refs(Store,
                          [V1.ref],
                          [consumer(_{run_id:run_b}), max_items(4)],
                          ok(Pack)),
    Pack.entries = [Entry],
    assertion(Entry.ref == V2.ref),
    assertion(Entry.value.status == "final"),
    Pack.stale_refs = [Stale],
    assertion(Stale.requested == V1.ref),
    assertion(Stale.current == V2.ref).

test(context_selection_is_bounded_and_kind_filtered) :-
    with_memory_store(context_selection_case).

context_selection_case(Store) :-
    producer(run_a, Provenance),
    artifact_put(Store, [task, bounded], a, finding,
                 _{text:"one"}, Provenance, ok(_)),
    artifact_put(Store, [task, bounded], b, summary,
                 _{text:"two"}, Provenance, ok(_)),
    artifact_put(Store, [task, bounded], c, finding,
                 _{text:"three"}, Provenance, ok(_)),
    artifact_context_pack(Store,
                          [task, bounded],
                          [kinds([finding]), max_items(1), max_chars(4096)],
                          ok(Pack)),
    assertion(Pack.item_count =:= 1),
    assertion(Pack.truncated == true),
    Pack.entries = [Entry],
    assertion(Entry.kind == finding).

test(non_ground_payload_fails_closed) :-
    with_memory_store(non_ground_case).

non_ground_case(Store) :-
    artifact_put(Store,
                 task,
                 broken,
                 finding,
                 _{value:_Unbound},
                 _{run_id:test},
                 error(Error)),
    assertion(Error.kind == artifact_error).

test(persistent_store_survives_close_and_reopen) :-
    tmp_file(artifact_persist_test, File),
    setup_call_cleanup(
        true,
        persistent_reopen_case(File),
        cleanup_file(File)).

persistent_reopen_case(File) :-
    producer(run_a, Provenance),
    artifact_store_open(persist(File), ok(Store1)),
    artifact_put(Store1,
                 [task, restart],
                 summary,
                 summary,
                 _{text:"survives"},
                 Provenance,
                 ok(Artifact)),
    artifact_store_close(Store1, ok(closed)),
    artifact_store_open(persist(File), ok(Store2)),
    artifact_get(Store2, Artifact.ref, ok(Restored)),
    assertion(Restored.value.text == "survives"),
    artifact_trace(Store2, [task, restart], ok(Trace)),
    Trace = [Published],
    assertion(Published.type == published),
    artifact_store_close(Store2, ok(closed)).

test(agent_checkpoint_state_carries_artifact_handle_not_transcript) :-
    setup_call_cleanup(
        artifact_store_open(memory, ok(Store)),
        agent_artifact_case(Store),
        artifact_store_close(Store, _)).

agent_artifact_case(Store) :-
    setup_call_cleanup(
        agent_runtime_create([], Runtime),
        agent_artifact_runtime_case(Runtime, Store),
        agent_runtime_destroy(Runtime)).

agent_artifact_runtime_case(Runtime, Store) :-
    agent_spawn(Runtime, none, agent_spec(root), [], ok(Agent)),
    agent_artifact_publish(Runtime,
                           Agent,
                           Store,
                           summary,
                           summary,
                           _{text:"compact state"},
                           _{call_id:publish_call},
                           ok(Published)),
    agent_artifact_refs(Runtime, Agent, ok(BeforePump)),
    assertion(BeforePump == []),
    agent_pump(Runtime, Agent, [], ok(Pump)),
    assertion(Pump.status == processed),
    agent_artifact_refs(Runtime, Agent, ok([Ref])),
    assertion(Ref == Published.artifact.ref),
    agent_status(Runtime, Agent, ok(Status)),
    assertion(Status.checkpoints == [artifact(Ref)]),
    assertion(Status.last_result == none),
    agent_artifact_context(Runtime,
                           Agent,
                           Store,
                           [call_id(fresh_call), max_items(4)],
                           ok(Pack)),
    Pack.entries = [Entry],
    assertion(Entry.value.text == "compact state"),
    artifact_trace(Store, Ref.namespace, ok(Trace)),
    last(Trace, Consumed),
    assertion(Consumed.consumer.call_id == fresh_call).

test(graph_checkpoint_state_carries_artifact_refs_and_consumes_them) :-
    setup_call_cleanup(
        artifact_store_open(memory, ok(Store)),
        graph_artifact_case(Store),
        artifact_store_close(Store, _)).

graph_artifact_case(Store) :-
    setup_call_cleanup(
        assertz(graph_test_store(Store)),
        graph_artifact_run_case(Store),
        retractall(graph_test_store(_))).

graph_artifact_run_case(Store) :-
    artifact_graph_schema_field(ArtifactField),
    Schema = [ArtifactField, field(seen, integer, 0, replace)],
    Spec = graph(artifact_graph,
                 Schema,
                 [node(publish, publish_handler),
                  node(consume, consume_handler)],
                 [edge(start, publish),
                  edge(publish, consume),
                  edge(consume, end)]),
    Registry = [handler(publish_handler,
                        plunit_rlm_artifact:graph_publish_node),
                handler(consume_handler,
                        plunit_rlm_artifact:graph_consume_node)],
    graph_compile(Spec, Registry, [], ok(Compiled)),
    setup_call_cleanup(
        graph_backend_open(memory, Backend),
        ( graph_run(Compiled,
                    _{},
                    [backend(Backend), run_id(artifact_run)],
                    ok(Result)),
          assertion(Result.state.seen =:= 1),
          Result.state.artifact_refs = [Ref],
          graph_checkpoint(Backend, artifact_run, Snapshot),
          assertion(Snapshot.state.artifact_refs == [Ref]),
          artifact_get(Store, Ref, ok(Artifact)),
          assertion(Artifact.provenance.run_id == artifact_run),
          assertion(Artifact.provenance.graph_id == artifact_graph),
          artifact_trace(Store, Ref.namespace, ok(Trace)),
          Trace = [Published, Consumed],
          assertion(Published.type == published),
          assertion(Consumed.type == consumed),
          assertion(Consumed.consumer.node == consume)
        ),
        graph_backend_close(Backend)).

graph_publish_node(_, Context, update(Patch)) :-
    graph_test_store(Store),
    graph_artifact_publish(Store,
                           Context,
                           blackboard,
                           blackboard,
                           _{finding:"graph durable state"},
                           _{call_id:graph_publish},
                           ok(Published)),
    Patch = Published.patch.

graph_consume_node(State, Context, update(_{seen:Count})) :-
    graph_test_store(Store),
    graph_artifact_context(Store,
                           Context,
                           State,
                           [max_items(4)],
                           ok(Pack)),
    Count = Pack.item_count.

cleanup_file(File) :-
    catch(delete_file(File), _, true).

:- end_tests(rlm_artifact).
