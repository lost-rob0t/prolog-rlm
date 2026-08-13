:- initialization(main, main).

:- use_module('../prolog/rlm_graph').
:- use_module('../prolog/rlm_artifact').
:- use_module('support/artifact_restart_fixture').

main([CheckpointFile, ArtifactFile]) :-
    artifact_store_open(persist(ArtifactFile), ok(Store)),
    set_artifact_restart_store(Store),
    compile_artifact_restart_graph(Compiled),
    graph_backend_open(persist(CheckpointFile), Backend),
    graph_run(Compiled,
              _{},
              [backend(Backend), run_id(artifact_restart)],
              Outcome),
    require_paused(Outcome, Ref),
    artifact_get(Store, Ref, ok(Artifact)),
    require_artifact(Artifact),
    graph_backend_close(Backend),
    clear_artifact_restart_store,
    artifact_store_close(Store, ok(closed)),
    halt(0).
main(_) :-
    format(user_error,
           'usage: swipl -q -s test/artifact_restart_phase1.pl -- <checkpoint-file> <artifact-file>~n',
           []),
    halt(2).

require_paused(ok(Result), Ref) :-
    Result.status == paused(needs_artifact_restart),
    Result.current == resume,
    Result.state.consumed == false,
    Result.state.artifact_refs = [Ref],
    !.
require_paused(Outcome, _) :-
    format(user_error,
           'artifact phase1 did not persist the expected paused state: ~q~n',
           [Outcome]),
    halt(1).

require_artifact(Artifact) :-
    Artifact.kind == blackboard,
    Artifact.version =:= 1,
    Artifact.value.token == "restart-artifact",
    Artifact.provenance.run_id == artifact_restart,
    Artifact.provenance.node == publish,
    !.
require_artifact(Artifact) :-
    format(user_error,
           'artifact phase1 stored unexpected artifact: ~q~n',
           [Artifact]),
    halt(1).
