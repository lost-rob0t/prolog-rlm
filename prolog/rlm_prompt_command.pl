:- module(rlm_prompt_command,
          [ prompt_command_compile/3,
            prompt_command_compile_ref/3,
            prompt_command_action/2,
            prompt_command_execute/6
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
    sort(Texts0, Texts), sort(Triggers0, Triggers), sort(Actions0, Actions),
    ( Texts = [Text], Triggers = [Trigger], Actions = [Action]
    -> compile_binding(Id, Text, Trigger, Action, Outcome)
    ;  Outcome = error(prompt_command_error{phase:resolve,
                                             kind:ambiguous_or_incomplete_reference,
                                             prompt_id:Id,
                                             message:"prompt reference must have exactly one text, trigger and action"})
    ).

compile_binding(Id, Text0, Trigger, Action, Outcome) :-
    ( text_string(Text0, Text), ground(Trigger)
    -> compile_valid_binding(Id, Text, Trigger, Action, Outcome)
    ;  Outcome = error(prompt_command_error{phase:validate,
                                             kind:invalid_prompt,
                                             prompt_id:Id,
                                             message:"prompt text and trigger must be closed data"})
    ).

compile_valid_binding(Id, Text, Trigger, Action, Outcome) :-
    ( prompt_command_action(Action, Command)
    -> Binding = prompt_command{prompt_id:Id,
                                text:Text,
                                trigger:Trigger,
                                command:Command,
                                provenance:kb(Id)},
       command_fingerprint(Binding, Fingerprint),
       put_dict(fingerprint, Binding, Fingerprint, Compiled),
       Outcome = ok(Compiled)
    ;  Outcome = error(prompt_command_error{phase:validate,
                                             kind:invalid_action,
                                             prompt_id:Id,
                                             action:Action,
                                             message:"prompt action is not in the closed command vocabulary"})
    ).

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
                                             message:"prompt command compilation failed"})) :-
    term_string(Exception, Safe).
