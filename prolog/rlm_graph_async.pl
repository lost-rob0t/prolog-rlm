:- module(rlm_graph_async,
          [ graph_run_async/4,
            graph_resume_async/6
          ]).

/** <module> Asynchronous facade for graph execution and resume */

:- use_module(rlm_async).
:- use_module(rlm_graph).

graph_run_async(Compiled, Input, Options, Future) :-
    rlm_async_submit(graph_run_task(Compiled, Input, Options), Future).

graph_run_task(Compiled, Input, Options, Outcome) :-
    rlm_graph:graph_run(Compiled, Input, Options, Outcome).

graph_resume_async(Compiled, RunId, State, Input, Options, Future) :-
    rlm_async_submit(graph_resume_task(Compiled,
                                       RunId,
                                       State,
                                       Input,
                                       Options),
                     Future).

graph_resume_task(Compiled, RunId, State, Input, Options, Outcome) :-
    rlm_graph:graph_resume(Compiled,
                           RunId,
                           State,
                           Input,
                           Options,
                           Outcome).
