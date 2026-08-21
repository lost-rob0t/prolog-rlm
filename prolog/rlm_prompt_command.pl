:- module(rlm_prompt_command,
          [ prompt_command_compile/3,
            prompt_command_compile_ref/3,
            prompt_command_action/2
          ]).

/** <module> Closed short-prompt command bindings

Compiles inert KB prompt records into a small allow-listed loop-command
vocabulary.  Records are data: no prompt action is meta-called and compilation
never mutates authority, capabilities, Spec state, or runtime state.
*/

:- use_module(library(crypto)).
:- use_module(library(lists)).

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
    -> true
    ;  Outcome = error(prompt_command_error{phase:validate,
                                             kind:invalid_prompt,
                                             prompt_id:Id,
                                             message:"prompt text and trigger must be closed data"}), !
    ),
    ( prompt_command_action(Action, Command)
    -> Binding = prompt_command{prompt_id:Id,
                                text:Text,
                                trigger:Trigger,
                                command:Command,
                                provenance:kb(Id)},
       term_string(Binding, Canonical, [quoted(true), numbervars(true)]),
       crypto_data_hash(Canonical, Fingerprint, [algorithm(sha256)]),
       put_dict(fingerprint, Binding, Fingerprint, Compiled),
       Outcome = ok(Compiled)
    ;  Outcome = error(prompt_command_error{phase:validate,
                                             kind:invalid_action,
                                             prompt_id:Id,
                                             action:Action,
                                             message:"prompt action is not in the closed command vocabulary"})
    ).

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
