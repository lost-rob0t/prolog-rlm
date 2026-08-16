:- module(rlm_completion_async,
          [ rlm_completion_async/4,
            llm_query_async/3,
            rlm_query_async/4
          ]).

/** <module> Asynchronous facade for completion operations

Each predicate schedules the existing synchronous operation through rlm_async.
Awaiting the returned future yields exactly the same Outcome term that the
corresponding synchronous predicate would return.
*/

:- use_module(rlm_async).
:- use_module(rlm_completion).

rlm_completion_async(Query, Context, Options, Future) :-
    rlm_async_submit(completion_task(Query, Context, Options), Future).

completion_task(Query, Context, Options, Outcome) :-
    rlm_completion:rlm_completion(Query, Context, Options, Outcome).

llm_query_async(Prompt, Options, Future) :-
    rlm_async_submit(llm_query_task(Prompt, Options), Future).

llm_query_task(Prompt, Options, Outcome) :-
    rlm_completion:llm_query(Prompt, Options, Outcome).

rlm_query_async(Query, Context, Options, Future) :-
    rlm_async_submit(rlm_query_task(Query, Context, Options), Future).

rlm_query_task(Query, Context, Options, Outcome) :-
    rlm_completion:rlm_query(Query, Context, Options, Outcome).
