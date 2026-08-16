:- module(rlm_agent_async,
          [ agent_spawn_async/5,
            agent_send_async/5,
            agent_pump_async/4,
            agent_cancel_async/4
          ]).

/** <module> Compatibility facade for canonical asynchronous agent operations

The canonical async/task implementation lives in rlm_agent. This module remains
for callers that import the historical async facade directly and delegates only
to asynchronous predicates. It never enters a synchronous public wrapper.
*/

:- use_module(rlm_agent, []).

agent_spawn_async(Runtime, Parent, Spec, Capabilities, Future) :-
    rlm_agent:agent_spawn_async(Runtime, Parent, Spec, Capabilities, Future).

agent_send_async(Runtime, Agent, Message, Options, Future) :-
    rlm_agent:agent_send_async(Runtime, Agent, Message, Options, Future).

agent_pump_async(Runtime, Agent, Options, Future) :-
    rlm_agent:agent_pump_async(Runtime, Agent, Options, Future).

agent_cancel_async(Runtime, Agent, Reason, Future) :-
    rlm_agent:agent_cancel_async(Runtime, Agent, Reason, Future).
