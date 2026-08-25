:- module(rlm_subagent,
          [ rlm_subagent_register/7,
            rlm_subagent_handler/7
          ]).

/** <module> First-class bounded RLM subagent tool

Registers the canonical `rlm_subagent` tool as a normal `rlm_tool` entry.
The trusted binding captures the supervised agent runtime, parent identity,
child capability ceiling, context and completion options. Model/KB data only
supplies the subquery string; it cannot choose a callable, widen capabilities,
or replace host-owned completion budgets. After spawn, the logical child owns
the effective completion capabilities and tool authority context. Recursive
`rlm(...)` plans remain bounded by the completion budget; registering the
parent-bound `rlm_subagent` tool in its own child ceiling fails closed until a
depth-aware recursive binding exists.
*/

:- use_module(rlm_agent).
:- use_module(rlm_completion).
:- use_module(rlm_tool).
:- use_module(library(apply), [exclude/3]).

rlm_subagent_register(Registry, Runtime, Parent, ChildCapabilities0,
                      Context, CompletionOptions, Outcome) :-
    capabilities_normalize(ChildCapabilities0, CapabilitiesOutcome),
    subagent_register_capabilities(CapabilitiesOutcome,
                                   Registry,
                                   Runtime,
                                   Parent,
                                   Context,
                                   CompletionOptions,
                                   Outcome).

subagent_register_capabilities(error(Cause), _, _, _, _, _, error(Error)) :-
    Error = tool_error{phase:register,
                       kind:invalid_child_capabilities,
                       cause:Cause,
                       message:"subagent child capabilities are invalid"}.
subagent_register_capabilities(ok(ChildCapabilities), _, _, _, _, _,
                               error(Error)) :-
    memberchk(tool(rlm_subagent), ChildCapabilities),
    !,
    Error = tool_error{
                phase:register,
                kind:unbounded_recursive_delegation,
                capability:tool(rlm_subagent),
                message:"recursive subagent tools require a depth-aware child binding"}.
subagent_register_capabilities(ok(ChildCapabilities),
                               Registry,
                               Runtime,
                               Parent,
                               Context,
                               CompletionOptions,
                               Outcome) :-
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
    subagent_after_spawn(SpawnOutcome, Runtime, Parent, ChildCapabilities,
                         Context, CompletionOptions, Query, Envelope).

subagent_after_spawn(error(Error), Runtime, Parent, _, _, _, _, Envelope) :-
    agent_trace(Runtime, Trace),
    Envelope = subagent_result{status:failed,
                               value:null,
                               evidence:[],
                               usage:usage{model_calls:0,total_tokens:0},
                               correlation:subagent_correlation{parent:Parent,
                                                                child:none},
                               trace:Trace,
                               error:Error}.
subagent_after_spawn(ok(Child), Runtime, Parent, ChildCapabilities, Context,
                     Options0, Query, Envelope) :-
    child_completion_options(Runtime,
                             Child,
                             ChildCapabilities,
                             Options0,
                             OptionsOutcome),
    subagent_after_options(OptionsOutcome,
                           Runtime,
                           Parent,
                           Child,
                           Context,
                           Query,
                           Envelope).

subagent_after_options(error(Error), Runtime, Parent, Child, _, _, Envelope) :-
    subagent_after_call(error(Error), Runtime, Parent, Child, Envelope).
subagent_after_options(ok(Options), Runtime, Parent, Child, Context, Query,
                       Envelope) :-
    Handler = rlm_subagent:subagent_completion_worker(Runtime,
                                                      Parent,
                                                      Child,
                                                      Context,
                                                      Options),
    rlm_agent:agent_supervised_call_execute(Runtime,
                                            Child,
                                            Handler,
                                            Query,
                                            [timeout(30.0)],
                                            CallOutcome),
    subagent_after_call(CallOutcome, Runtime, Parent, Child, Envelope).

child_completion_options(agent_runtime(RuntimeId),
                         agent(ChildId),
                         ChildCapabilities0,
                         Options0,
                         Outcome) :-
    (   is_list(Options0)
    ->  child_completion_options_list(RuntimeId,
                                      ChildId,
                                      ChildCapabilities0,
                                      Options0,
                                      Outcome)
    ;   Outcome = error(completion_error{
                            phase:runtime,
                            kind:invalid_options,
                            options:Options0,
                            message:"subagent completion options must be a list"})
    ).

child_completion_options_list(RuntimeId,
                              ChildId,
                              ChildCapabilities0,
                              Options0,
                              ok(Options)) :-
    capabilities_normalize(ChildCapabilities0, ok(ChildCapabilities)),
    replace_option(capabilities,
                   ChildCapabilities,
                   Options0,
                   CapabilityOptions),
    replace_option(authority_context,
                   agent(RuntimeId, ChildId),
                   CapabilityOptions,
                   AuthorityOptions),
    replace_option(runtime_id,
                   RuntimeId,
                   AuthorityOptions,
                   RuntimeOptions),
    replace_option(agent_id, ChildId, RuntimeOptions, Options).

replace_option(Name, Value, Options0, [Option|Options]) :-
    exclude(option_named(Name), Options0, Options),
    Option =.. [Name, Value].

option_named(Name, Option) :-
    nonvar(Option),
    functor(Option, Name, 1).

subagent_completion_worker(Runtime, Parent, Child, Context, Options, Query,
                           Envelope) :-
    rlm_completion:rlm_completion_execute(Query,
                                          Context,
                                          Options,
                                          CompletionOutcome),
    agent_trace(Runtime, Trace),
    subagent_completion_envelope(CompletionOutcome, Parent, Child, Trace,
                                 Envelope).

subagent_after_call(ok(Envelope), _, _, _, Envelope) :- !.
subagent_after_call(error(Error), Runtime, Parent, Child, Envelope) :-
    agent_trace(Runtime, Trace),
    Envelope = subagent_result{status:failed,
                               value:null,
                               evidence:[],
                               usage:usage{model_calls:0,total_tokens:0},
                               correlation:subagent_correlation{parent:Parent,
                                                                child:Child},
                               trace:Trace,
                               error:Error}.

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
