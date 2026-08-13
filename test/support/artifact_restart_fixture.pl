:- module(artifact_restart_fixture,
          [ compile_artifact_restart_graph/1,
            set_artifact_restart_store/1,
            clear_artifact_restart_store/0
          ]).

:- use_module('../../prolog/rlm_graph').
:- use_module('../../prolog/rlm_artifact_graph').

:- dynamic artifact_restart_store/1.

set_artifact_restart_store(Store) :-
    retractall(artifact_restart_store(_)),
    assertz(artifact_restart_store(Store)).

clear_artifact_restart_store :-
    retractall(artifact_restart_store(_)).

compile_artifact_restart_graph(Compiled) :-
    artifact_graph_schema_field(ArtifactField),
    Schema = [ ArtifactField,
               field(consumed, boolean, false, replace)
             ],
    Spec = graph(artifact_restart_graph,
                 Schema,
                 [ node(publish, publish_handler),
                   node(resume, resume_handler)
                 ],
                 [ edge(start, publish),
                   edge(publish, resume),
                   edge(resume, end)
                 ]),
    Registry = [ handler(publish_handler,
                         artifact_restart_fixture:publish_node),
                 handler(resume_handler,
                         artifact_restart_fixture:resume_node)
               ],
    graph_compile(Spec, Registry, [], ok(Compiled)).

publish_node(_, Context, interrupt(needs_artifact_restart, Patch)) :-
    artifact_restart_store(Store),
    graph_artifact_publish(Store,
                           Context,
                           blackboard,
                           blackboard,
                           _{token:"restart-artifact",
                             summary:"fresh root should consume this, not a transcript"},
                           _{call_id:phase1_publish},
                           ok(Published)),
    Patch = Published.patch.

resume_node(State, Context, update(_{consumed:true})) :-
    artifact_restart_store(Store),
    graph_artifact_context(Store,
                           Context,
                           State,
                           [max_items(4), max_chars(4096)],
                           ok(Pack)),
    Pack.entries = [Entry],
    Entry.value.token == "restart-artifact".
