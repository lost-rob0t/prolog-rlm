:- module(rlm_agent_async,
          [ agent_spawn_async/5,
            agent_send_async/5,
            agent_pump_async/4,
            agent_cancel_async/4
          ]).

/** <module> Asynchronous facade for supervised agent operations */

:- use_module(rlm_async).
:- use_module(rlm_agent).

agent_spawn_async(Runtime, Parent, Spec, Options, Future) :-
    rlm_async_submit(agent_spawn_task(Runtime, Parent, Spec, Options), Future).

agent_spawn_task(Runtime, Parent, Spec, Options, Outcome) :-
    rlm_agent:agent_spawn(Runtime, Parent, Spec, Options, Outcome).

agent_send_async(Runtime, Agent, Message, Options, Future) :-
    rlm_async_submit(agent_send_task(Runtime, Agent, Message, Options), Future).

agent_send_task(Runtime, Agent, Message, Options, Outcome) :-
    rlm_agent:agent_send(Runtime, Agent, Message, Options, Outcome).

agent_pump_async(Runtime, Agent, Options, Future) :-
    rlm_async_submit(agent_pump_task(Runtime, Agent, Options), Future).

agent_pump_task(Runtime, Agent, Options, Outcome) :-
    rlm_agent:agent_pump(Runtime, Agent, Options, Outcome).

agent_cancel_async(Runtime, Agent, Reason, Future) :-
    rlm_async_submit(agent_cancel_task(Runtime, Agent, Reason), Future).

agent_cancel_task(Runtime, Agent, Reason, Outcome) :-
    rlm_agent:agent_cancel(Runtime, Agent, Reason, Outcome).
