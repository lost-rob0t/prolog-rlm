:- module(rlm_graph_async,
          [ graph_run_async/4,
            graph_resume_async/6
          ]).

/** <module> Compatibility facade for canonical asynchronous graph operations

The canonical async/task implementation lives in rlm_graph. This module remains
for callers that import the historical async facade directly and delegates only
to asynchronous predicates. It never enters a synchronous public wrapper.
*/

:- use_module(rlm_graph, []).

graph_run_async(Compiled, Input, Options, Future) :-
    rlm_graph:graph_run_async(Compiled, Input, Options, Future).

graph_resume_async(Compiled, Backend, RunId, Resume, Options, Future) :-
    rlm_graph:graph_resume_async(Compiled,
                                 Backend,
                                 RunId,
                                 Resume,
                                 Options,
                                 Future).
