:- module(graph_restart_fixture,
          [ compile_restart_graph/1
          ]).

:- use_module('../../prolog/rlm_graph').

compile_restart_graph(Compiled) :-
    Schema = [ field(log, list, [], append),
               field(approved, boolean, false, replace)
             ],
    Spec = graph(process_restart_graph,
                 Schema,
                 [ node(wait, wait_handler),
                   node(resume, resume_handler)
                 ],
                 [ edge(start, wait),
                   edge(wait, resume),
                   edge(resume, end)
                 ]),
    Registry = [ handler(wait_handler,
                         graph_restart_fixture:wait_node),
                 handler(resume_handler,
                         graph_restart_fixture:resume_node)
               ],
    graph_compile(Spec, Registry, [], ok(Compiled)).

wait_node(_, _, interrupt(needs_restart, _{log:[paused]})).

resume_node(_, Context,
            update(_{approved:true,
                     log:[Context.resume]})).
