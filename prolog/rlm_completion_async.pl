:- module(rlm_completion_async,
           [ rlm_completion_async/4,
             rlm_direct_async/4,
            llm_query_async/3,
            rlm_query_async/4
          ]).

/** <module> Compatibility facade for canonical asynchronous completion APIs

The canonical async/task implementation lives in rlm_completion. This module is
kept for source compatibility with callers that import the historical async
facade directly. It delegates only to asynchronous predicates and never enters a
synchronous public wrapper.
*/

:- use_module(rlm_completion, []).
:- use_module(rlm_direct, []).

rlm_completion_async(Query, Context, Options, Future) :-
    rlm_completion:rlm_completion_async(Query, Context, Options, Future).

rlm_direct_async(Query, Context, Options, Future) :-
    rlm_direct:rlm_direct_async(Query, Context, Options, Future).

llm_query_async(Prompt, Options, Future) :-
    rlm_completion:llm_query_async(Prompt, Options, Future).

rlm_query_async(Query, Context, Options, Future) :-
    rlm_completion:rlm_query_async(Query, Context, Options, Future).
