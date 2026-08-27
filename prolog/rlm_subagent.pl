:- module(rlm_subagent,
          [ rlm_subagent_register/7,
            rlm_subagent_register_command/8,
            rlm_subagent_handler/7
          ]).

/** <module> First-class bounded RLM subagent tool

Registers the canonical `rlm_subagent` tool as a normal `rlm_tool` entry.
The trusted binding captures the supervised agent runtime, parent identity,
child capability ceiling, context and completion options. Model/KB data only
supplies the subquery and may request a bounded task duration; it cannot choose
a callable, widen capabilities, or replace host-owned completion budgets.
Trusted completion options may carry host-selected explicit skills, generic
subagent role metadata, compiler-authenticated delegation provenance, and
host-owned timeout policy. These remain inert policy/provenance and never grant
capability or authority. A compiler-authenticated prompt command may supply the
same role/skill intent through `rlm_subagent_register_command/8`; that adapter
rejects a second host-side delegation policy and still registers this exact
canonical tool.

Task execution timeout, Future waiter timeout, and cancellation are distinct.
The resolved task timeout is written into the child completion budget. The
supervised-call and outer tool limits add only host-owned cleanup grace so they
do not preempt the semantic completion timeout. Existing trusted
`budget(...time_limit:T...)` remains a backwards-compatible host default when a
dedicated `subagent_timeout_default/1` is not supplied.

After spawn, the logical child owns the effective completion capabilities and
tool authority context. Recursive `rlm(...)` plans remain bounded by the
completion budget; registering the parent-bound `rlm_subagent` tool in its own
child ceiling fails closed until a depth-aware recursive binding exists.
*/

:- use_module(rlm_agent).
:- use_module(rlm_completion).
:- use_module(rlm_prompt_command, [prompt_command_subagent_options/3]).
:- use_module(rlm_tool).
:- use_module(library(apply), [exclude/3]).

rlm_subagent_register_command(Registry, Runtime, Parent, ChildCapabilities,
                              Context, CompletionOptions, Command, Outcome) :-
    prompt_command_subagent_options(Command,
                                    CompletionOptions,
                                    OptionsOutcome),
    subagent_register_command_options(OptionsOutcome,
                                      Registry,
                                      Runtime,
                                      Parent,
                                      ChildCapabilities,
                                      Context,
                                      Outcome).

subagent_register_command_options(error(Error), _, _, _, _, _, error(Error)) :-
    !.
subagent_register_command_options(ok(Options), Registry, Runtime, Parent,
                                  ChildCapabilities, Context, Outcome) :-
    rlm_subagent_register(Registry,
                          Runtime,
                          Parent,
                          ChildCapabilities,
                          Context,
                          Options,
                          Outcome).

rlm_subagent_register(Registry, Runtime, Parent, ChildCapabilities0,
                      Context, CompletionOptions0, Outcome) :-
    subagent_timeout_policy(CompletionOptions0, PolicyOutcome),
    subagent_register_after_policy(PolicyOutcome,
                                   Registry,
                                   Runtime,
                                   Parent,
                                   ChildCapabilities0,
                                   Context,
                                   Outcome).

subagent_register_after_policy(error(Error), _, _, _, _, _, error(Error)) :- !.
subagent_register_after_policy(ok(Prepared), Registry, Runtime, Parent,
                               ChildCapabilities0, Context, Outcome) :-
    capabilities_normalize(ChildCapabilities0, CapabilitiesOutcome),
    subagent_register_capabilities(CapabilitiesOutcome,
                                   Registry,
                                   Runtime,
                                   Parent,
                                   Context,
                                   Prepared.completion_options,
                                   Prepared.policy,
                                   Outcome).

subagent_register_capabilities(error(Cause), _, _, _, _, _, _, error(Error)) :-
    Error = tool_error{phase:register,
                       kind:invalid_child_capabilities,
                       cause:Cause,
                       message:"subagent child capabilities are invalid"}.
subagent_register_capabilities(ok(ChildCapabilities), _, _, _, _, _, _,
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
                               TimeoutPolicy,
                               Outcome) :-
    HandlerLimit is TimeoutPolicy.max_seconds +
                    TimeoutPolicy.handler_grace_seconds,
    Schema = tool_schema{
                 name:rlm_subagent,
                 description:"Delegate an unresolved question to one bounded supervised RLM child",
                 capability:tool(rlm_subagent),
                 effect:read,
                 arguments:_{type:object,
                             required:[query],
                             additional_properties:false,
                             properties:_{query:_{type:string},
                                         timeout_seconds:_{type:number,
                                                           exclusiveMinimum:0}}},
                 result:_{type:object},
                 limits:_{time_limit:HandlerLimit, max_output_bytes:65536}},
    Handler = rlm_subagent:rlm_subagent_policy_handler(Runtime,
                                                       Parent,
                                                       ChildCapabilities,
                                                       Context,
                                                       CompletionOptions,
                                                       TimeoutPolicy),
    tool_register(Registry, Schema, Handler, Outcome).

% Compatibility surface for trusted callers of the historical handler.
rlm_subagent_handler(Runtime, Parent, ChildCapabilities, Context,
                     CompletionOptions0, Args, Envelope) :-
    subagent_timeout_policy(CompletionOptions0, PolicyOutcome),
    subagent_direct_after_policy(PolicyOutcome,
                                 Runtime,
                                 Parent,
                                 ChildCapabilities,
                                 Context,
                                 Args,
                                 Envelope).

subagent_direct_after_policy(error(Error), Runtime, Parent, _, _, _, Envelope) :-
    pre_spawn_failure(Runtime, Parent, Error, none, Envelope).
subagent_direct_after_policy(ok(Prepared), Runtime, Parent, ChildCapabilities,
                             Context, Args, Envelope) :-
    rlm_subagent_policy_handler(Runtime,
                                Parent,
                                ChildCapabilities,
                                Context,
                                Prepared.completion_options,
                                Prepared.policy,
                                Args,
                                Envelope).

rlm_subagent_policy_handler(Runtime, Parent, ChildCapabilities, Context,
                            CompletionOptions0, TimeoutPolicy, Args, Envelope) :-
    subagent_effective_timeout(Args, TimeoutPolicy, TimeoutOutcome),
    subagent_after_timeout(TimeoutOutcome,
                           TimeoutPolicy,
                           Runtime,
                           Parent,
                           ChildCapabilities,
                           Context,
                           CompletionOptions0,
                           Args,
                           Envelope).

subagent_after_timeout(error(Error), _, Runtime, Parent, _, _, _, _, Envelope) :-
    pre_spawn_failure(Runtime, Parent, Error, none, Envelope).
subagent_after_timeout(ok(Timeout), TimeoutPolicy, Runtime, Parent,
                       ChildCapabilities, Context, CompletionOptions0, Args,
                       Envelope) :-
    subagent_completion_options(CompletionOptions0,
                                Timeout.effective_seconds,
                                CompletionOptionsOutcome),
    subagent_after_timeout_options(CompletionOptionsOutcome,
                                   Timeout,
                                   TimeoutPolicy,
                                   Runtime,
                                   Parent,
                                   ChildCapabilities,
                                   Context,
                                   Args,
                                   Envelope).

subagent_after_timeout_options(error(Error), _, _, Runtime, Parent, _, _, _,
                               Envelope) :-
    pre_spawn_failure(Runtime, Parent, Error, none, Envelope).
subagent_after_timeout_options(ok(CompletionOptions), Timeout, TimeoutPolicy,
                               Runtime, Parent, ChildCapabilities, Context, Args,
                               Envelope) :-
    subagent_delegation_options(CompletionOptions, DelegationOutcome),
    subagent_after_delegation(DelegationOutcome,
                              Timeout,
                              TimeoutPolicy,
                              Runtime,
                              Parent,
                              ChildCapabilities,
                              Context,
                              Args,
                              Envelope).

subagent_after_delegation(error(Error), Timeout, _, Runtime, Parent, _, _, _,
                          Envelope) :-
    pre_spawn_failure(Runtime, Parent, Error, Timeout, Envelope).
subagent_after_delegation(ok(Prepared), Timeout, TimeoutPolicy, Runtime, Parent,
                          ChildCapabilities, Context, Args, Envelope) :-
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
                         Timeout,
                         TimeoutPolicy,
                         Query,
                         Envelope).

pre_spawn_failure(Runtime, Parent, Error, Timeout, Envelope) :-
    agent_trace(Runtime, Trace),
    Base = subagent_result{status:failed,
                           value:null,
                           evidence:[],
                           usage:usage{model_calls:0,total_tokens:0},
                           correlation:subagent_correlation{parent:Parent,
                                                            child:none},
                           delegation:none,
                           trace:Trace,
                           error:Error},
    envelope_timeout(Base, Timeout, Envelope).

subagent_timeout_policy(Options0, Outcome) :-
    (   is_list(Options0)
    ->  timeout_default_value(Options0, DefaultOutcome),
        timeout_policy_after_default(DefaultOutcome, Options0, Outcome)
    ;   Outcome = error(tool_error{
                            phase:register,
                            kind:invalid_completion_options,
                            message:"subagent completion options must be a list"})
    ).

timeout_default_value(Options, Outcome) :-
    findall(Value, member(subagent_timeout_default(Value), Options), Values),
    (   Values == []
    ->  legacy_budget_timeout_default(Options, LegacyOutcome),
        timeout_default_from_legacy(LegacyOutcome, Outcome)
    ;   timeout_option_values(subagent_timeout_default,
                              Values,
                              30.0,
                              Outcome)
    ).

timeout_default_from_legacy(ok(none), ok(30.0)) :- !.
timeout_default_from_legacy(ok(Value), ok(Value)) :- !.
timeout_default_from_legacy(error(Error), error(Error)).

legacy_budget_timeout_default(Options, Outcome) :-
    findall(Budget, member(budget(Budget), Options), Budgets),
    legacy_budget_timeout_values(Budgets, Outcome).

legacy_budget_timeout_values([], ok(none)) :- !.
legacy_budget_timeout_values([Budget], Outcome) :-
    !,
    (   is_dict(Budget), get_dict(time_limit, Budget, TimeLimit)
    ->  (   number(TimeLimit), TimeLimit > 0
        ->  Outcome = ok(TimeLimit)
        ;   Outcome = error(tool_error{
                                phase:register,
                                kind:invalid_subagent_timeout_policy,
                                option:budget_time_limit,
                                value:TimeLimit,
                                message:"legacy completion budget time_limit must be a positive number"})
        )
    ;   Outcome = ok(none)
    ).
legacy_budget_timeout_values(_, error(Error)) :-
    Error = tool_error{phase:register,
                       kind:duplicate_budget,
                       message:"subagent completion budget may be configured only once"}.

timeout_policy_after_default(error(Error), _, error(Error)) :- !.
timeout_policy_after_default(ok(Default), Options0, Outcome) :-
    timeout_option_value(subagent_timeout_max,
                         Options0,
                         300.0,
                         MaxOutcome),
    timeout_policy_after_max(MaxOutcome, Default, Options0, Outcome).

timeout_policy_after_max(error(Error), _, _, error(Error)) :- !.
timeout_policy_after_max(ok(Maximum), Default, Options0, Outcome) :-
    timeout_option_value(subagent_timeout_grace,
                         Options0,
                         2.0,
                         GraceOutcome),
    timeout_policy_after_grace(GraceOutcome,
                               Default,
                               Maximum,
                               Options0,
                               Outcome).

timeout_policy_after_grace(error(Error), _, _, _, error(Error)) :- !.
timeout_policy_after_grace(ok(Grace), Default, Maximum, Options0, Outcome) :-
    (   Default =< Maximum
    ->  exclude(timeout_policy_option, Options0, CompletionOptions),
        Policy = subagent_timeout_policy{default_seconds:Default,
                                         max_seconds:Maximum,
                                         handler_grace_seconds:Grace},
        Outcome = ok(timeout_policy_options{policy:Policy,
                                            completion_options:CompletionOptions})
    ;   Outcome = error(tool_error{
                            phase:register,
                            kind:invalid_subagent_timeout_policy,
                            default_seconds:Default,
                            maximum_seconds:Maximum,
                            message:"subagent timeout default must not exceed maximum"})
    ).

timeout_option_value(Name, Options, Default, Outcome) :-
    findall(Value,
            ( member(Option, Options),
              nonvar(Option),
              Option =.. [Name, Value]
            ),
            Values),
    timeout_option_values(Name, Values, Default, Outcome).

timeout_option_values(_, [], Default, ok(Default)) :- !.
timeout_option_values(Name, [Value], _, Outcome) :-
    !,
    (   number(Value), Value > 0
    ->  Outcome = ok(Value)
    ;   Outcome = error(tool_error{
                            phase:register,
                            kind:invalid_subagent_timeout_policy,
                            option:Name,
                            value:Value,
                            message:"subagent timeout policy values must be positive numbers"})
    ).
timeout_option_values(Name, _, _, error(Error)) :-
    Error = tool_error{phase:register,
                       kind:duplicate_subagent_timeout_policy,
                       option:Name,
                       message:"subagent timeout policy option may be configured only once"}.

timeout_policy_option(Option) :- option_named(subagent_timeout_default, Option), !.
timeout_policy_option(Option) :- option_named(subagent_timeout_max, Option), !.
timeout_policy_option(Option) :- option_named(subagent_timeout_grace, Option).

subagent_effective_timeout(Args, Policy, Outcome) :-
    (   get_dict(timeout_seconds, Args, Requested)
    ->  subagent_requested_timeout(Requested, Policy, Outcome)
    ;   Timeout = subagent_timeout{source:default,
                                   requested_seconds:none,
                                   effective_seconds:Policy.default_seconds},
        Outcome = ok(Timeout)
    ).

subagent_requested_timeout(Requested, Policy, Outcome) :-
    (   number(Requested), Requested > 0
    ->  (   Requested =< Policy.max_seconds
        ->  Timeout = subagent_timeout{source:model_request,
                                       requested_seconds:Requested,
                                       effective_seconds:Requested},
            Outcome = ok(Timeout)
        ;   Outcome = error(subagent_error{
                                phase:timeout_policy,
                                kind:timeout_exceeds_maximum,
                                requested:Requested,
                                maximum:Policy.max_seconds,
                                message:"requested subagent timeout exceeds host policy"})
        )
    ;   Outcome = error(subagent_error{
                            phase:timeout_policy,
                            kind:invalid_timeout,
                            requested:Requested,
                            message:"requested subagent timeout must be a positive number"})
    ).

subagent_completion_options(Options0, EffectiveTimeout, Outcome) :-
    findall(Budget, member(budget(Budget), Options0), Budgets),
    subagent_completion_budget(Budgets,
                               Options0,
                               EffectiveTimeout,
                               Outcome).

subagent_completion_budget([], Options0, EffectiveTimeout, ok(Options)) :-
    !,
    Options = [budget(completion_budget{time_limit:EffectiveTimeout})|Options0].
subagent_completion_budget([Budget0], Options0, EffectiveTimeout, Outcome) :-
    !,
    (   is_dict(Budget0)
    ->  put_dict(time_limit, Budget0, EffectiveTimeout, Budget),
        exclude(option_named(budget), Options0, Rest),
        Options = [budget(Budget)|Rest],
        Outcome = ok(Options)
    ;   Outcome = error(completion_error{
                            phase:runtime,
                            kind:invalid_budget,
                            budget:Budget0,
                            message:"subagent completion budget must be a dict"})
    ).
subagent_completion_budget(_, _, _, error(Error)) :-
    Error = completion_error{phase:runtime,
                             kind:duplicate_budget,
                             message:"subagent completion budget may be configured only once"}.

subagent_delegation_options(Options0, Outcome) :-
    (   is_list(Options0)
    ->  subagent_role_option(Options0, RoleOutcome),
        subagent_delegation_after_role(RoleOutcome, Options0, Outcome)
    ;   Outcome = error(tool_error{
                            phase:invoke,
                            kind:invalid_completion_options,
                            message:"subagent completion options must be a list"})
    ).

subagent_delegation_after_role(error(Error), _, error(Error)) :- !.
subagent_delegation_after_role(ok(Role), Options0, Outcome) :-
    subagent_skill_option(Options0, SkillsOutcome),
    subagent_delegation_after_skills(SkillsOutcome, Role, Options0, Outcome).

subagent_delegation_after_skills(error(Error), _, _, error(Error)) :- !.
subagent_delegation_after_skills(ok(Skills), Role, Options0, Outcome) :-
    subagent_source_option(Options0, SourceOutcome),
    subagent_delegation_after_source(SourceOutcome,
                                     Role,
                                     Skills,
                                     Options0,
                                     Outcome).

subagent_delegation_after_source(error(Error), _, _, _, error(Error)) :- !.
subagent_delegation_after_source(ok(Source), Role, Skills, Options0,
                                 ok(Prepared)) :-
    exclude(option_named(subagent_role), Options0, Options1),
    exclude(option_named(subagent_delegation_source),
            Options1,
            Options2),
    % A delegated child is never a root: drop any caller-provided scope and
    % mark it delegated so the child planner call carries no root identity.
    exclude(option_named(agent_scope), Options2, Options3),
    CompletionOptions = [agent_scope(delegated)|Options3],
    Delegation = delegation{role:Role,
                            skills:Skills,
                            source:Source},
    Prepared = delegation_options{delegation:Delegation,
                                  completion_options:CompletionOptions}.

subagent_role_option(Options, Outcome) :-
    findall(Role0, member(subagent_role(Role0), Options), Roles),
    subagent_role_values(Roles, Outcome).

subagent_role_values([], ok(none)) :- !.
subagent_role_values([Role0], Outcome) :-
    !,
    (   normalize_delegation_name(Role0, Role), Role \== none
    ->  Outcome = ok(Role)
    ;   Outcome = error(tool_error{
                            phase:invoke,
                            kind:invalid_subagent_role,
                            message:"subagent role must be a bounded identifier"})
    ).
subagent_role_values(_, error(Error)) :-
    Error = tool_error{phase:invoke,
                       kind:duplicate_subagent_role,
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
        maplist(normalize_delegation_name, Skills0, Skills),
        sort(Skills, UniqueSkills),
        length(UniqueSkills, Count)
    ->  Outcome = ok(Skills)
    ;   Outcome = error(tool_error{
                            phase:invoke,
                            kind:invalid_subagent_skills,
                            message:"explicit subagent skills must be bounded unique identifiers"})
    ).
subagent_skill_values(_, error(Error)) :-
    Error = tool_error{phase:invoke,
                       kind:duplicate_explicit_skills,
                       message:"explicit subagent skills may be configured only once"}.

subagent_source_option(Options, Outcome) :-
    findall(Source,
            member(subagent_delegation_source(Source), Options),
            Sources),
    subagent_source_values(Sources, Outcome).

subagent_source_values([], ok(trusted_host)) :- !.
subagent_source_values([Source], Outcome) :-
    !,
    (   valid_delegation_source(Source)
    ->  Outcome = ok(Source)
    ;   Outcome = error(tool_error{
                            phase:invoke,
                            kind:invalid_delegation_source,
                            message:"delegation source must be bounded trusted provenance data"})
    ).
subagent_source_values(_, error(Error)) :-
    Error = tool_error{phase:invoke,
                       kind:duplicate_delegation_source,
                       message:"delegation source may be configured only once"}.

valid_delegation_source(trusted_host) :- !.
valid_delegation_source(Source) :-
    is_dict(Source, delegation_source),
    ground(Source),
    dict_pairs(Source, delegation_source, Pairs),
    findall(Key, member(Key-_, Pairs), Keys0),
    sort(Keys0, Keys),
    Keys == [fingerprint,kind,prompt_id],
    get_dict(kind, Source, prompt_command),
    get_dict(prompt_id, Source, PromptId),
    valid_delegation_prompt_id(PromptId),
    get_dict(fingerprint, Source, Fingerprint),
    valid_delegation_fingerprint(Fingerprint).

valid_delegation_prompt_id(Value) :-
    atom(Value),
    atom_length(Value, Length),
    between(1, 128, Length),
    !.
valid_delegation_prompt_id(Value) :-
    string(Value),
    string_length(Value, Length),
    between(1, 128, Length),
    !.
valid_delegation_prompt_id(Value) :- number(Value).

valid_delegation_fingerprint(Fingerprint) :-
    atom(Fingerprint),
    atom_length(Fingerprint, 64),
    atom_chars(Fingerprint, Chars),
    maplist(hex_char, Chars).

hex_char(Char) :- char_type(Char, xdigit(_)).

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

subagent_after_spawn(error(Error), Runtime, Parent, _, _, _, Delegation, Timeout,
                     _, _, Envelope) :-
    agent_trace(Runtime, Trace),
    Envelope0 = subagent_result{status:failed,
                                value:null,
                                evidence:[],
                                usage:usage{model_calls:0,total_tokens:0},
                                correlation:subagent_correlation{parent:Parent,
                                                                 child:none},
                                delegation:Delegation,
                                trace:Trace,
                                error:Error},
    envelope_timeout(Envelope0, Timeout, Envelope).
subagent_after_spawn(ok(Child), Runtime, Parent, ChildCapabilities, Context,
                     Options0, Delegation, Timeout, TimeoutPolicy, Query,
                     Envelope) :-
    child_completion_options(Runtime,
                             Child,
                             ChildCapabilities,
                             Options0,
                             OptionsOutcome0),
    delegated_options_outcome(OptionsOutcome0,
                              Delegation,
                              Timeout,
                              TimeoutPolicy,
                              OptionsOutcome),
    subagent_after_options(OptionsOutcome,
                           Runtime,
                           Parent,
                           Child,
                           Context,
                           Query,
                           Envelope).

delegated_options_outcome(ok(Options), Delegation, Timeout, TimeoutPolicy,
                          ok(delegated(Options, Delegation, Timeout,
                                       TimeoutPolicy))) :- !.
delegated_options_outcome(error(Error), Delegation, Timeout, TimeoutPolicy,
                          error(delegated(Error, Delegation, Timeout,
                                          TimeoutPolicy))).

subagent_after_options(error(delegated(Error, Delegation, Timeout, _)),
                       Runtime, Parent, Child, _, _, Envelope) :-
    subagent_after_call(error(Error), Runtime, Parent, Child, Delegation,
                        Timeout, Envelope).
subagent_after_options(ok(delegated(Options, Delegation, Timeout,
                                    TimeoutPolicy)),
                       Runtime, Parent, Child, Context, Query, Envelope) :-
    Handler = rlm_subagent:subagent_completion_worker(Runtime,
                                                      Parent,
                                                      Child,
                                                      Context,
                                                      Options,
                                                      Delegation,
                                                      Timeout),
    SupervisedLimit is Timeout.effective_seconds +
                       TimeoutPolicy.handler_grace_seconds,
    rlm_agent:agent_supervised_call_execute(Runtime,
                                            Child,
                                            Handler,
                                            Query,
                                            [timeout(SupervisedLimit)],
                                            CallOutcome),
    subagent_after_call(CallOutcome,
                        Runtime,
                        Parent,
                        Child,
                        Delegation,
                        Timeout,
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
                           Timeout, Query, Envelope) :-
    rlm_completion:rlm_completion_execute(Query,
                                          Context,
                                          Options,
                                          CompletionOutcome),
    agent_trace(Runtime, Trace),
    subagent_completion_envelope(CompletionOutcome,
                                 Parent,
                                 Child,
                                 Delegation,
                                 Timeout,
                                 Trace,
                                 Envelope).

subagent_after_call(ok(Envelope), _, _, _, _, _, Envelope) :- !.
subagent_after_call(error(Error), Runtime, Parent, Child, Delegation, Timeout,
                    Envelope) :-
    agent_trace(Runtime, Trace),
    Envelope0 = subagent_result{status:failed,
                                value:null,
                                evidence:[],
                                usage:usage{model_calls:0,total_tokens:0},
                                correlation:subagent_correlation{parent:Parent,
                                                                 child:Child},
                                delegation:Delegation,
                                trace:Trace,
                                error:Error},
    envelope_timeout(Envelope0, Timeout, Envelope).

subagent_completion_envelope(ok(Result), Parent, Child, Delegation, Timeout,
                             Trace, Envelope) :-
    Envelope0 = subagent_result{status:completed,
                                value:Result.value,
                                evidence:[],
                                usage:Result.usage,
                                correlation:subagent_correlation{parent:Parent,
                                                                 child:Child},
                                delegation:Delegation,
                                trace:Trace,
                                completion:Result},
    envelope_timeout(Envelope0, Timeout, Envelope).
subagent_completion_envelope(error(Error), Parent, Child, Delegation, Timeout,
                             Trace, Envelope) :-
    error_usage(Error, Usage),
    Envelope0 = subagent_result{status:failed,
                                value:null,
                                evidence:[],
                                usage:Usage,
                                correlation:subagent_correlation{parent:Parent,
                                                                 child:Child},
                                delegation:Delegation,
                                trace:Trace,
                                error:Error},
    envelope_timeout(Envelope0, Timeout, Envelope).

envelope_timeout(Envelope, none, Envelope) :- !.
envelope_timeout(Envelope0, Timeout, Envelope) :-
    put_dict(timeout, Envelope0, Timeout, Envelope).

error_usage(Error, Usage) :-
    is_dict(Error), get_dict(usage, Error, Usage0), !, Usage = Usage0.
error_usage(_, usage{model_calls:0,total_tokens:0}).