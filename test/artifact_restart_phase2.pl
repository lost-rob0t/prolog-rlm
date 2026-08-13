:- initialization(main, main).

:- use_module('../prolog/rlm_graph').
:- use_module('../prolog/rlm_artifact').
:- use_module('support/artifact_restart_fixture').

main([CheckpointFile, ArtifactFile]) :-
    artifact_store_open(persist(ArtifactFile), ok(Store)),
    set_artifact_restart_store(Store),
    compile_artifact_restart_graph(Compiled),
    graph_backend_open(persist(CheckpointFile), Backend),
    graph_checkpoint(Backend, artifact_restart, Snapshot),
    require_checkpoint(Snapshot, Ref),
    artifact_get(Store, Ref, ok(Artifact)),
    require_artifact(Artifact),
    graph_resume(Compiled,
                 Backend,
                 artifact_restart,
                 fresh_process_resume,
                 [],
                 Outcome),
    require_completed(Outcome, Ref),
    artifact_trace(Store, Ref.namespace, ok(Trace)),
    require_trace(Trace, Ref),
    graph_backend_close(Backend),
    clear_artifact_restart_store,
    artifact_store_close(Store, ok(closed)),
    halt(0).
main(_) :-
    format(user_error,
           'usage: swipl -q -s test/artifact_restart_phase2.pl -- <checkpoint-file> <artifact-file>~n',
           []),
    halt(2).

require_checkpoint(Snapshot, Ref) :-
    Snapshot.status == paused(needs_artifact_restart),
    Snapshot.current == resume,
    Snapshot.state.consumed == false,
    Snapshot.state.artifact_refs = [Ref],
    !.
require_checkpoint(Snapshot, _) :-
    format(user_error,
           'artifact phase2 could not reload expected checkpoint: ~q~n',
           [Snapshot]),
    halt(1).

require_artifact(Artifact) :-
    Artifact.kind == blackboard,
    Artifact.value.token == "restart-artifact",
    Artifact.provenance.run_id == artifact_restart,
    !.
require_artifact(Artifact) :-
    format(user_error,
           'artifact phase2 could not reload expected artifact: ~q~n',
           [Artifact]),
    halt(1).

require_completed(ok(Result), Ref) :-
    Result.status == completed,
    Result.state.consumed == true,
    Result.state.artifact_refs == [Ref],
    !.
require_completed(Outcome, _) :-
    format(user_error,
           'artifact phase2 did not resume with durable artifact context: ~q~n',
           [Outcome]),
    halt(1).

require_trace([Published, Consumed], Ref) :-
    Published.type == published,
    Published.ref == Ref,
    Published.producer.run_id == artifact_restart,
    Consumed.type == consumed,
    Consumed.refs == [Ref],
    Consumed.consumer.run_id == artifact_restart,
    Consumed.consumer.node == resume,
    !.
require_trace(Trace, _) :-
    format(user_error,
           'artifact phase2 producer/consumer trace mismatch: ~q~n',
           [Trace]),
    halt(1).
