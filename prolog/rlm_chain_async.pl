:- module(rlm_chain_async,
          [ model_complete_async/3,
            model_stream_async/4,
            chain_invoke_async/4,
            chain_stream_async/5
          ]).

/** <module> Asynchronous facade for provider and chain calls */

:- use_module(rlm_async).
:- use_module(rlm_chain).

model_complete_async(Provider, Request, Future) :-
    rlm_async_submit(model_complete_task(Provider, Request), Future).

model_complete_task(Provider, Request, Outcome) :-
    rlm_chain:model_complete(Provider, Request, Outcome).

model_stream_async(Provider, Request, Handler, Future) :-
    rlm_async_submit(model_stream_task(Provider, Request, Handler), Future).

model_stream_task(Provider, Request, Handler, Outcome) :-
    rlm_chain:model_stream(Provider, Request, Handler, Outcome).

chain_invoke_async(Chain, Request, Options, Future) :-
    rlm_async_submit(chain_invoke_task(Chain, Request, Options), Future).

chain_invoke_task(Chain, Request, Options, Outcome) :-
    rlm_chain:chain_invoke(Chain, Request, Options, Outcome).

chain_stream_async(Chain, Request, Handler, Options, Future) :-
    rlm_async_submit(chain_stream_task(Chain, Request, Handler, Options), Future).

chain_stream_task(Chain, Request, Handler, Options, Outcome) :-
    rlm_chain:chain_stream(Chain, Request, Handler, Options, Outcome).
