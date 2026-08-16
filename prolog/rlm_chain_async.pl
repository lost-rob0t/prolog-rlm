:- module(rlm_chain_async,
          [ model_complete_async/3,
            model_stream_async/4,
            chain_invoke_async/4,
            chain_stream_async/5
          ]).

/** <module> Compatibility facade for canonical asynchronous chain APIs */

:- use_module(rlm_chain, []).

model_complete_async(Provider, Request, Future) :-
    rlm_chain:model_complete_async(Provider, Request, Future).

model_stream_async(Provider, Request, Handler, Future) :-
    rlm_chain:model_stream_async(Provider, Request, Handler, Future).

chain_invoke_async(Chain, Request, Options, Future) :-
    rlm_chain:chain_invoke_async(Chain, Request, Options, Future).

chain_stream_async(Chain, Request, Handler, Options, Future) :-
    rlm_chain:chain_stream_async(Chain, Request, Handler, Options, Future).
