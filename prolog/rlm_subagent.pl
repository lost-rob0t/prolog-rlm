:- module(rlm_subagent,
          [ rlm_subagent_register/7,
            rlm_subagent_handler/7
          ]).

/** <module> First-class bounded RLM subagent tool

Registers the canonical `rlm_subagent` tool as a normal `rlm_tool` entry.
The trusted binding captures the supervised agent runtime, parent identity,
child capability ceiling, context and completion options. Model/KB data only
supplies the subquery string; it cannot choose a callable, widen capabilities,
or replace host-owned completion budgets. Trusted completion options may carry
host-selected explicit skills and generic subagent role metadata; these remain
inert delegation provenance and never grant capability or authority. After
spawn, the logical child owns the effective completion capabilities and tool
authority context. Recursive `rlm(...)` plans remain bounded by the completion
budget; registering the parent-bound `rlm_subagent` tool in its own child
ceiling fails closed until a depth-aware recursive binding exists.
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
                     CompletionOptions0, Args, Envelope) :-
    subagent_delegation_options(CompletionOptions0, DelegationOutcome),
    subagent_after_delegation(DelegationOutcome,
                              Runtime,
                              Parent,
                              ChildCapabilities,
                              Context,
                              Args,
                              Envelope).

subagent_after_delegation(error(Error), Runtime, Parent, _, _, _, Envelope) :-
    agent_trace(Runtime, Trace),
    Envelope = subagent_result{status:failed,
                               value:null,
                               evidence:[],
                               usage:usage{model_calls:0,total_tokens:0},
                               correlation:subagent_correlation{parent:Parent,
                                                                child:none},
                               delegation:none,
                               trace:Trace,
                               error:Error}.
subagent_after_delegation(ok(Prepared), Runtime, Parent, ChildCapabilities,
                          Context, Args, Envelope) :-
    get_dict(query, Args, Query),
    Delegation = Prepared.delegation,
    CompletionOptions = Prepared.completion_options,
    agent_spawn(Runtime, Parent,
                agent_spec{ name:rlm_subagent,
                            mode:rlm,
                            authority:inherit,
                            metadata:agent_metadata{purpose:delegation,
                                                    delegation:Delegation}},
                ChildCapabilities,
                SpawnOutcome),
    subagent_after_spawn(SpawnOutcome,
                         Runtime,
                         Parent,
                         ChildCapabilities,
                         Context,
                         CompletionOptions,
                         Delegation,
                         Query,
                         Envelope).

subagent_delegation_options(Options0, Outcome) :-
    (   is_list(Options0)
    ->  subagent_role_option(Options0, RoleOutcome),
        subagent_delegation_after_role(RoleOutcome, Options0, Outcome)
    ;   Outcome = error(tool_error{
                            phase:invoke,
                            kind:invalid_completion_options,
                            options:Options0,
                            message:"subagent completion options must be a list"})
    ).

subagent_delegation_after_role(error(Error), _, error(Error)) :- !.
subagent_delegation_after_role(ok(Role), Options0, Outcome) :-
    subagent_skill_option(Options0, SkillsOutcome),
    subagent_delegation_after_skills(SkillsOutcome, Role, Options0, Outcome).

subagent_delegation_after_skills(error(Error), _, _, error(Error)) :- !.
subagent_delegation_after_skills(ok(Skills), Role, Options0, ok(Prepared)) :-
    exclude(option_named(subagent_role), Options0, CompletionOptions),
    Delegation = delegation{role:Role,
                            skills:Skills,
                            source:trusted_host},
    Prepared = delegation_options{delegation:Delegation,
                                  completion_options:CompletionOptions}.

subagent_role_option(Options, Outcome) :-
    findall(Role0, member(subagent_role(Role0), Options), Roles),
    subagent_role_values(Roles, Outcome).

subagent_role_values([], ok(none)) :- !.
subagent_role_values([Role0], Outcome) :-
    !,
    (   normalize_delegation_name(Role0, Role)
    ->  Outcome = ok(Role)
    ;   Outcome = error(tool_error{
                            phase:invoke,
                            kind:invalid_subagent_role,
                            role:Role0,
                            message:"subagent role must be a bounded identifier"})
    ).
subagent_role_values(Roles, error(Error)) :-
    Error = tool_error{phase:invoke,
                       kind:duplicate_subagent_role,
                       roles:Roles,
                       message:"subagent role may be configured only once"}.

subagent_skill_option(Options, Outcome) :-
    findall(Skills0, member(explicit_skills(Skills0), Options), SkillOptions),
    subagent_skill_values(SkillOptions, Outcome).

subagent_skill_values([], ok([])) :- !.
subagent_skill_values([Skills0], Outcome) :-
    !,
    (   is_list(Skills0),
        length(Skills0, Count),
        Count =< 64,
        maplist(normalize_delegation_name, Skills0, Skills)
    ->  Outcome = ok(Skills)
    ;   Outcome = error(tool_error{
                            phase:invoke,
                            kind:invalid_subagent_skills,
                            skills:Skills0,
                            message:"explicit subagent skills must be bounded identifiers"})
    ).
subagent_skill_values(SkillOptions, error(Error)) :-
    Error = tool_error{phase:invoke,
                       kind:duplicate_explicit_skills,
                       values:SkillOptions,
                       message:"explicit subagent skills may be configured only once"}.

normalize_delegation_name(Value, Name) :-
    atom(Value),
    !,
    Name = Value,
    valid_delegation_name(Name).
normalize_delegation_name(Value, Name) :-
    string(Value),
    atom_string(Name, Value),
    valid_delegation_name(Name).

valid_delegation_name(Name) :-
    atom_length(Name, Length),
    between(1, 64, Length),
    atom_chars(Name, [First|Chars]),
    char_type(First, lower),
    maplist(delegation_name_char, Chars),
    last([First|Chars], Last),
    (char_type(Last, lower) ; char_type(Last, digit)),
    \+ sub_atom(Name, _, 2, _, '--').

delegation_name_char(Char) :- char_type(Char, lower), !.
delegation_name_char(Char) :- char_type(Char, digit), !.
delegation_name_char('-').

subagent_after_spawn(error(Error), Runtime, Parent, _, _, _, Delegation, _,
                     Envelope) :-
    agent_trace(Runtime, Trace),
    Envelope = subagent_result{status:failed,
                               value:null,
                               evidence:[],
                               usage:usage{model_calls:0,total_tokens:0},
                               correlation:subagent_correlation{parent:Parent,
                                                                child:none},
                               delegation:Delegation,
                               trace:Trace,
                               error:Error}.
subagent_after_spawn(ok(Child), Runtime, Parent, ChildCapabilities, Context,
                     Options0, Delegation, Query, Envelope) :-
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
                           Delegation,
                           Query,
                           Envelope).

subagent_after_options(error(Error), Runtime, Parent, Child, _, Delegation, _,
                       Envelope) :-
    subagent_after_call(error(Error), Runtime, Parent, Child, Delegation,
                        Envelope).
subagent_after_options(ok(Options), Runtime, Parent, Child, Context, Delegation,
                       Query, Envelope) :-
    Handler = rlm_subagent:subagent_completion_worker(Runtime,
                                                      Parent,
                                                      Child,
                                                      Context,
                                                      Options,
                                                      Delegation),
    rlm_agent:agent_supervised_call_execute(Runtime,
                                            Child,
                                            Handler,
                                            Query,
                                            [timeout(30.0)],
                                            CallOutcome),
    subagent_after_call(CallOutcome,
                        Runtime,
                        Parent,
                        Child,
                        Delegation,
                        Envelope).

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

subagent_completion_worker(Runtime, Parent, Child, Context, Options, Delegation,
                           Query, Envelope) :-
    rlm_completion:rlm_completion_execute(Query,
                                          Context,
                                          Options,
                                          CompletionOutcome),
    agent_trace(Runtime, Trace),
    subagent_completion_envelope(CompletionOutcome,
                                 Parent,
                                 Child,
                                 Delegation,
                                 Trace,
                                 Envelope).

subagent_after_call(ok(Envelope), _, _, _, _, Envelope) :- !.
subagent_after_call(error(Error), Runtime, Parent, Child, Delegation, Envelope) :-
    agent_trace(Runtime, Trace),
    Envelope = subagent_result{status:failed,
                               value:null,
                               evidence:[],
                               usage:usage{model_calls:0,total_tokens:0},
                               correlation:subagent_correlation{parent:Parent,
                                                                child:Child},
                               delegation:Delegation,
                               trace:Trace,
                               error:Error}.

subagent_completion_envelope(ok(Result), Parent, Child, Delegation, Trace,
                             Envelope) :-
    Envelope = subagent_result{status:completed,
                               value:Result.value,
                               evidence:[],
                               usage:Result.usage,
                               correlation:subagent_correlation{parent:Parent,
                                                                child:Child},
                               delegation:Delegation,
                               trace:Trace,
                               completion:Result}.
subagent_completion_envelope(error(Error), Parent, Child, Delegation, Trace,
                             Envelope) :-
    error_usage(Error, Usage),
    Envelope = subagent_result{status:failed,
                               value:null,
                               evidence:[],
                               usage:Usage,
                               correlation:subagent_correlation{parent:Parent,
                                                                child:Child},
                               delegation:Delegation,
                               trace:Trace,
                               error:Error}.

error_usage(Error, Usage) :-
    is_dict(Error), get_dict(usage, Error, Usage0), !, Usage = Usage0.
error_usage(_, usage{model_calls:0,total_tokens:0}).