:- module(rlm_prompt_command,
          [ prompt_command_compile/3,
            prompt_command_compile_ref/3,
            prompt_command_action/2,
            prompt_command_execute/6,
            prompt_command_subagent_options/3
          ]).

/** <module> Closed short-prompt command bindings

Compiles inert KB prompt records into a small allow-listed loop-command
vocabulary. Records and compiled commands are data: no prompt action or command
value is meta-called, and neither compilation nor execution grants authority or
capabilities.

`prompt_command_execute/6` is the narrow bridge from a compiler-authenticated
closed command to the canonical typed tool runtime. The bridge owns only command
validation and argument projection; tool capability, authority, effect,
cancellation, limits, and async scheduling remain owned by `rlm_tool` and the
registered tool handler.

Optional `prompt_role/2` and `prompt_skill/2` records are trusted symbolic
selection intent for the existing subagent path. They are fingerprinted with
the compiled command, but remain inert: the selected skill name is still
admitted and compiled by the canonical child `rlm_prompt_compiler`, and neither
role nor skill metadata grants capability or authority.
*/

:- use_module(library(crypto)).
:- use_module(library(lists)).
:- use_module(rlm_tool, []).

prompt_command_action(delegate_subagent, tool(rlm_subagent)).

prompt_command_compile(Records, Trigger, Outcome) :-
    catch(prompt_command_compile_(Records, Trigger, Outcome),
          Exception,
          command_exception(Exception, Outcome)).

prompt_command_compile_(Records, Trigger, Outcome) :-
    require_records(Records),
    findall(Id,
            ( member(prompt_trigger(Id, Trigger), Records),
              member(prompt(Id, _), Records),
              member(prompt_action(Id, _), Records)
            ),
            Ids0),
    sort(Ids0, Ids),
    compile_trigger_matches(Ids, Records, Trigger, Outcome).

compile_trigger_matches([], _, Trigger,
                        error(prompt_command_error{phase:resolve,
                                                   kind:missing_binding,
                                                   trigger:Trigger,
                                                   message:"no complete prompt binding matches trigger"})).
compile_trigger_matches([Id], Records, _, Outcome) :-
    !,
    prompt_command_compile_ref(Records, Id, Outcome).
compile_trigger_matches(Ids, _, Trigger,
                        error(prompt_command_error{phase:resolve,
                                                   kind:ambiguous_binding,
                                                   trigger:Trigger,
                                                   candidates:Ids,
                                                   message:"multiple prompt bindings match trigger"})).

prompt_command_compile_ref(Records, Id, Outcome) :-
    catch(prompt_command_compile_ref_(Records, Id, Outcome),
          Exception,
          command_exception(Exception, Outcome)).

prompt_command_compile_ref_(Records, Id, Outcome) :-
    require_records(Records),
    findall(Text, member(prompt(Id, Text), Records), Texts0),
    findall(Trigger, member(prompt_trigger(Id, Trigger), Records), Triggers0),
    findall(Action, member(prompt_action(Id, Action), Records), Actions0),
    findall(Role, member(prompt_role(Id, Role), Records), Roles0),
    findall(Skill, member(prompt_skill(Id, Skill), Records), Skills0),
    sort(Texts0, Texts), sort(Triggers0, Triggers), sort(Actions0, Actions),
    ( Texts = [Text], Triggers = [Trigger], Actions = [Action]
    -> compile_binding(Id, Text, Trigger, Action, Roles0, Skills0, Outcome)
    ;  Outcome = error(prompt_command_error{phase:resolve,
                                             kind:ambiguous_or_incomplete_reference,
                                             prompt_id:Id,
                                             message:"prompt reference must have exactly one text, trigger and action"})
    ).

compile_binding(Id, Text0, Trigger, Action, Roles0, Skills0, Outcome) :-
    ( text_string(Text0, Text), ground(Trigger)
    -> compile_valid_binding(Id, Text, Trigger, Action, Roles0, Skills0, Outcome)
    ;  Outcome = error(prompt_command_error{phase:validate,
                                             kind:invalid_prompt,
                                             prompt_id:Id,
                                             message:"prompt text and trigger must be closed data"})
    ).

compile_valid_binding(Id, Text, Trigger, Action, Roles0, Skills0, Outcome) :-
    ( prompt_command_action(Action, Command)
    -> compile_delegation_policy(Id, Roles0, Skills0, PolicyOutcome),
       compile_valid_binding_after_policy(PolicyOutcome,
                                          Id, Text, Trigger, Command, Outcome)
    ;  Outcome = error(prompt_command_error{phase:validate,
                                             kind:invalid_action,
                                             prompt_id:Id,
                                             action:Action,
                                             message:"prompt action is not in the closed command vocabulary"})
    ).

compile_valid_binding_after_policy(error(Error), _, _, _, _, error(Error)) :- !.
compile_valid_binding_after_policy(ok(Policy), Id, Text, Trigger, Command,
                                   ok(Compiled)) :-
    Binding0 = prompt_command{prompt_id:Id,
                              text:Text,
                              trigger:Trigger,
                              command:Command,
                              provenance:kb(Id)},
    binding_with_delegation_policy(Policy, Binding0, Binding),
    command_fingerprint(Binding, Fingerprint),
    put_dict(fingerprint, Binding, Fingerprint, Compiled).

compile_delegation_policy(Id, Roles0, Skills0, Outcome) :-
    delegation_role_values(Roles0, RoleOutcome),
    delegation_policy_after_role(RoleOutcome, Id, Skills0, Outcome).

delegation_policy_after_role(error(Error), _, _, error(Error)) :- !.
delegation_policy_after_role(ok(Role), Id, Skills0, Outcome) :-
    delegation_skill_values(Skills0, SkillsOutcome),
    delegation_policy_after_skills(SkillsOutcome, Id, Role, Outcome).

delegation_policy_after_skills(error(Error), _, _, error(Error)) :- !.
delegation_policy_after_skills(ok(Skills), Id, Role,
                               ok(delegation_policy{role:Role,
                                                    skills:Skills,
                                                    provenance:kb(Id)})).

delegation_role_values(Values0, Outcome) :-
    normalize_policy_names(role, Values0, NamesOutcome),
    delegation_role_names(NamesOutcome, Outcome).

delegation_role_names(error(Error), error(Error)) :- !.
delegation_role_names(ok(Names0), Outcome) :-
    sort(Names0, Names),
    (   Names = []
    ->  Outcome = ok(none)
    ;   Names = [Role], Role \== none
    ->  Outcome = ok(Role)
    ;   Outcome = error(prompt_command_error{
                            phase:validate,
                            kind:ambiguous_delegation_role,
                            roles:Names,
                            message:"delegation role must resolve to one bounded generic role"})
    ).

delegation_skill_values(Values0, Outcome) :-
    normalize_policy_names(skill, Values0, NamesOutcome),
    (   NamesOutcome = error(Error)
    ->  Outcome = error(Error)
    ;   NamesOutcome = ok(Names0),
        sort(Names0, Names),
        length(Names, Count),
        (   Count =< 64
        ->  Outcome = ok(Names)
        ;   Outcome = error(prompt_command_error{
                                phase:validate,
                                kind:too_many_delegation_skills,
                                count:Count,
                                message:"delegation skill selection exceeds the bounded limit"})
        )
    ).

normalize_policy_names(_, [], ok([])) :- !.
normalize_policy_names(Field, [Value|Values], Outcome) :-
    (   normalize_policy_name(Value, Name)
    ->  normalize_policy_names(Field, Values, RestOutcome),
        prepend_policy_name(RestOutcome, Name, Outcome)
    ;   policy_name_error(Field, Value, Outcome)
    ).

prepend_policy_name(error(Error), _, error(Error)) :- !.
prepend_policy_name(ok(Names), Name, ok([Name|Names])).

policy_name_error(role, Value,
                  error(prompt_command_error{
                            phase:validate,
                            kind:invalid_delegation_role,
                            value:Value,
                            message:"delegation role must be a bounded identifier"})).
policy_name_error(skill, Value,
                  error(prompt_command_error{
                            phase:validate,
                            kind:invalid_delegation_skill,
                            value:Value,
                            message:"delegation skill must be a bounded identifier"})).

normalize_policy_name(Value, Name) :-
    atom(Value),
    !,
    Name = Value,
    valid_policy_name(Name).
normalize_policy_name(Value, Name) :-
    string(Value),
    atom_string(Name, Value),
    valid_policy_name(Name).

valid_policy_name(Name) :-
    atom_length(Name, Length),
    between(1, 64, Length),
    atom_chars(Name, [First|Chars]),
    char_type(First, lower),
    maplist(policy_name_char, Chars),
    last([First|Chars], Last),
    (char_type(Last, lower) ; char_type(Last, digit)),
    \+ sub_atom(Name, _, 2, _, '--').

policy_name_char(Char) :- char_type(Char, lower), !.
policy_name_char(Char) :- char_type(Char, digit), !.
policy_name_char('-').

binding_with_delegation_policy(delegation_policy{role:none,skills:[]},
                               Binding, Binding) :-
    !.
binding_with_delegation_policy(Policy, Binding0, Binding) :-
    put_dict(delegation_policy, Binding0, Policy, Binding).

prompt_command_execute(Command, Registry, Capabilities, Options, Outcome, Trace) :-
    prompt_command_invocation(Command, InvocationOutcome),
    execute_invocation(InvocationOutcome,
                       Registry,
                       Capabilities,
                       Options,
                       Outcome,
                       Trace).

prompt_command_invocation(Command, Outcome) :-
    (   is_dict(Command, prompt_command),
        ground(Command),
        get_dict(command, Command, Target)
    ->  command_target_invocation(Target, Command, Outcome)
    ;   Outcome = error(prompt_command_error{
                            phase:execute,
                            kind:invalid_command,
                            message:"compiled prompt command must be closed prompt_command data"})
    ).

command_target_invocation(tool(rlm_subagent), Command, Outcome) :-
    !,
    validate_compiled_fingerprint(Command, FingerprintOutcome),
    command_after_fingerprint(FingerprintOutcome, Command, Outcome).
command_target_invocation(Target, _,
                          error(prompt_command_error{
                                    phase:execute,
                                    kind:unsupported_command,
                                    command:Target,
                                    message:"compiled prompt command target is not executable by this runtime"})).

validate_compiled_fingerprint(Command, Outcome) :-
    (   get_dict(fingerprint, Command, Fingerprint),
        atom(Fingerprint),
        del_dict(fingerprint, Command, Fingerprint, Binding),
        command_fingerprint(Binding, Expected),
        Fingerprint == Expected
    ->  Outcome = ok
    ;   Outcome = error(prompt_command_error{
                            phase:execute,
                            kind:invalid_fingerprint,
                            message:"compiled prompt command fingerprint does not match its payload"})
    ).

command_after_fingerprint(error(Error), _, error(Error)) :- !.
command_after_fingerprint(ok, Command, Outcome) :-
    (   get_dict(text, Command, Text),
        string(Text)
    ->  Outcome = ok(command_invocation{
                         tool:rlm_subagent,
                         args:json{query:Text}})
    ;   Outcome = error(prompt_command_error{
                            phase:execute,
                            kind:invalid_command,
                            message:"compiled subagent command must contain normalized text"})
    ).

execute_invocation(error(Error), _, _, _, error(Error), Trace) :-
    !,
    Trace = prompt_command_trace{status:command_rejected,
                                 authorization:denied}.
execute_invocation(ok(Invocation), Registry, Capabilities, Options,
                   Outcome, Trace) :-
    rlm_tool:tool_invoke(Registry,
                         Capabilities,
                         Invocation.tool,
                         Invocation.args,
                         Options,
                         Outcome,
                         Trace).

prompt_command_subagent_options(Command, BaseOptions, Outcome) :-
    catch(prompt_command_subagent_options_(Command, BaseOptions, Outcome),
          Exception,
          command_exception(Exception, Outcome)).

prompt_command_subagent_options_(Command, BaseOptions, Outcome) :-
    (   is_list(BaseOptions)
    ->  prompt_command_invocation(Command, InvocationOutcome),
        subagent_options_after_invocation(InvocationOutcome,
                                          Command,
                                          BaseOptions,
                                          Outcome)
    ;   Outcome = error(prompt_command_error{
                            phase:policy,
                            kind:invalid_base_options,
                            message:"subagent base options must be a list"})
    ).

subagent_options_after_invocation(error(Error), _, _, error(Error)) :- !.
subagent_options_after_invocation(ok(_), Command, BaseOptions, Outcome) :-
    delegation_option_conflicts(BaseOptions, Conflicts),
    (   Conflicts == []
    ->  command_delegation_policy(Command, PolicyOutcome),
        subagent_options_after_policy(PolicyOutcome,
                                      Command,
                                      BaseOptions,
                                      Outcome)
    ;   Outcome = error(prompt_command_error{
                            phase:policy,
                            kind:delegation_policy_conflict,
                            conflicting_options:Conflicts,
                            message:"compiled delegation policy cannot be combined with a second role/skill/source policy"})
    ).

delegation_option_conflicts(Options, Conflicts) :-
    findall(Name,
            ( member(Option, Options),
              compound(Option),
              functor(Option, Name, _),
              delegation_option_name(Name)
            ),
            Names0),
    sort(Names0, Conflicts).

delegation_option_name(subagent_role).
delegation_option_name(explicit_skills).
delegation_option_name(subagent_delegation_source).

command_delegation_policy(Command, Outcome) :-
    get_dict(prompt_id, Command, Id),
    (   get_dict(delegation_policy, Command, Policy)
    ->  validate_command_delegation_policy(Policy, Id, Outcome)
    ;   Outcome = ok(delegation_policy{role:none,
                                       skills:[],
                                       provenance:kb(Id)})
    ).

validate_command_delegation_policy(Policy, Id, Outcome) :-
    (   is_dict(Policy, delegation_policy),
        get_dict(role, Policy, Role0),
        get_dict(skills, Policy, Skills0),
        get_dict(provenance, Policy, kb(Id)),
        normalize_policy_role(Role0, Role),
        normalize_policy_skill_list(Skills0, Skills)
    ->  Outcome = ok(delegation_policy{role:Role,
                                       skills:Skills,
                                       provenance:kb(Id)})
    ;   Outcome = error(prompt_command_error{
                            phase:policy,
                            kind:invalid_delegation_policy,
                            message:"compiled delegation policy is not bounded canonical data"})
    ).

normalize_policy_role(none, none) :- !.
normalize_policy_role(Role0, Role) :-
    normalize_policy_name(Role0, Role),
    Role \== none.

normalize_policy_skill_list(Skills0, Skills) :-
    is_list(Skills0),
    length(Skills0, Count),
    Count =< 64,
    maplist(normalize_policy_name, Skills0, Names0),
    sort(Names0, Skills),
    length(Skills, Count).

subagent_options_after_policy(error(Error), _, _, error(Error)) :- !.
subagent_options_after_policy(ok(Policy), Command, BaseOptions, Outcome) :-
    command_delegation_source(Command, SourceOutcome),
    subagent_options_after_source(SourceOutcome,
                                  Policy,
                                  BaseOptions,
                                  Outcome).

command_delegation_source(Command, Outcome) :-
    get_dict(prompt_id, Command, PromptId0),
    get_dict(fingerprint, Command, Fingerprint),
    (   source_prompt_id(PromptId0, PromptId)
    ->  Outcome = ok(delegation_source{kind:prompt_command,
                                       prompt_id:PromptId,
                                       fingerprint:Fingerprint})
    ;   Outcome = error(prompt_command_error{
                            phase:policy,
                            kind:invalid_delegation_prompt_id,
                            prompt_id:PromptId0,
                            message:"delegation provenance prompt id exceeds the bounded metadata form"})
    ).

source_prompt_id(Value, Value) :-
    atom(Value),
    atom_length(Value, Length),
    between(1, 128, Length),
    !.
source_prompt_id(Value, Value) :-
    string(Value),
    string_length(Value, Length),
    between(1, 128, Length),
    !.
source_prompt_id(Value, Value) :-
    number(Value),
    !.
source_prompt_id(Value, Text) :-
    ground(Value),
    term_string(Value, Text, [quoted(true), numbervars(true)]),
    string_length(Text, Length),
    between(1, 128, Length).

subagent_options_after_source(error(Error), _, _, error(Error)) :- !.
subagent_options_after_source(ok(Source), Policy, BaseOptions, ok(Options)) :-
    Options0 = [subagent_delegation_source(Source)|BaseOptions],
    add_delegation_role_option(Policy.role, Options0, Options1),
    add_delegation_skill_option(Policy.skills, Options1, Options).

add_delegation_role_option(none, Options, Options) :- !.
add_delegation_role_option(Role, Options, [subagent_role(Role)|Options]).

add_delegation_skill_option([], Options, Options) :- !.
add_delegation_skill_option(Skills, Options, [explicit_skills(Skills)|Options]).

command_fingerprint(Binding, Fingerprint) :-
    term_string(Binding, Canonical, [quoted(true), numbervars(true)]),
    crypto_data_hash(Canonical, Fingerprint, [algorithm(sha256)]).

require_records(Records) :-
    ( is_list(Records), ground(Records) -> true
    ; throw(prompt_command_fault(invalid_records))
    ).

text_string(Value, String) :- string(Value), !, String = Value.
text_string(Value, String) :- atom(Value), !, atom_string(Value, String).

command_exception(Exception,
                  error(prompt_command_error{phase:internal,
                                             kind:exception,
                                             exception:Safe,
                                             message:"prompt command processing failed"})) :-
    term_string(Exception, Safe).
