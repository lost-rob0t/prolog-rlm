:- module(rlm_subagent,
          [ rlm_subagent_register/7,
            rlm_subagent_handler/7
          ]).

/** <module> First-class bounded RLM subagent tool

Registers the canonical `rlm_subagent` tool as a normal `rlm_tool` entry.
The trusted binding captures the supervised agent runtime, parent identity,
child capability ceiling, context and completion options. Model/KB data only
supplies the subquery string; it cannot choose a callable, widen capabilities,
or replace host-owned completion budgets.
*/

:- use_module(rlm_agent).
:- use_module(rlm_completion).
:- use_module(rlm_tool).

rlm_subagent_register(Registry, Runtime, Parent, ChildCapabilities,
                      Context, CompletionOptions, Outcome) :-
    Schema = tool_schema{
                 name:rlm_subagent,
                 description:"Delegate an unresolved question to one bounded supervised RLM child",
                 capability:tool(rlm_subagent),
                 effect:read,
                 arguments:_{type:object,
                             required:[query],
                             additional_properties:false,
                             properties:_{query:_{type:string}}},
                 result:_{type:object},
                 limits:_{time_limit:30.0, max_output_bytes:65536}},
    Handler = rlm_subagent:rlm_subagent_handler(Runtime, Parent,
                                                ChildCapabilities, Context,
                                                CompletionOptions),
    tool_register(Registry, Schema, Handler, Outcome).

rlm_subagent_handler(Runtime, Parent, ChildCapabilities, Context,
                     CompletionOptions, Args, Envelope) :-
    get_dict(query, Args, Query),
    agent_spawn(Runtime, Parent,
                agent_spec{ name:rlm_subagent,
                            mode:rlm,
                            authority:inherit,
                            metadata:agent_metadata{purpose:delegation}},
                ChildCapabilities,
                SpawnOutcome),
    subagent_after_spawn(SpawnOutcome, Runtime, Parent, Context,
                         CompletionOptions, Query, Envelope).

subagent_after_spawn(error(Error), Runtime, Parent, _, _, _, Envelope) :-
    agent_trace(Runtime, Trace),
    Envelope = subagent_result{status:failed,
                               value:null,
                               evidence:[],
                               usage:usage{model_calls:0,total_tokens:0},
                               correlation:subagent_correlation{parent:Parent,
                                                                child:none},
                               trace:Trace,
                               error:Error}.
subagent_after_spawn(ok(Child), Runtime, Parent, Context, Options, Query,
                     Envelope) :-
    rlm_completion(Query, Context, Options, CompletionOutcome),
    agent_trace(Runtime, Trace),
    subagent_completion_envelope(CompletionOutcome, Parent, Child, Trace,
                                 Envelope).

subagent_completion_envelope(ok(Result), Parent, Child, Trace, Envelope) :-
    Envelope = subagent_result{status:completed,
                               value:Result.value,
                               evidence:[],
                               usage:Result.usage,
                               correlation:subagent_correlation{parent:Parent,
                                                                child:Child},
                               trace:Trace,
                               completion:Result}.
subagent_completion_envelope(error(Error), Parent, Child, Trace, Envelope) :-
    error_usage(Error, Usage),
    Envelope = subagent_result{status:failed,
                               value:null,
                               evidence:[],
                               usage:Usage,
                               correlation:subagent_correlation{parent:Parent,
                                                                child:Child},
                               trace:Trace,
                               error:Error}.

error_usage(Error, Usage) :-
    is_dict(Error), get_dict(usage, Error, Usage0), !, Usage = Usage0.
error_usage(_, usage{model_calls:0,total_tokens:0}).
