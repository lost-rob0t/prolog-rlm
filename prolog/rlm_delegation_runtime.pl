:- module(rlm_delegation_runtime,
          [ rlm_delegation_runtime_ready/0,
            delegation_resume/10
          ]).

/** <module> Bounded unresolved-delegation continuation

This module closes the generic orchestration gap between compiler-authenticated
short-prompt bindings and one parent continuation step. It does not add a
second agent runtime, scheduler, selector, or command executor.

The trusted host supplies runtime/parent identities, the child capability
request, completion/tool options, and a continuation closure. The parent
capability set is read from authoritative `rlm_agent` state; callers cannot
supply a wider synthetic parent capability set. KB/model-controlled data only
selects a closed prompt-command binding by trigger and becomes ordinary closed
resume input. It is never meta-called.

The path is deliberately linear:

  unresolved trigger
    -> prompt_command_compile/3
    -> authoritative parent capabilities
    -> rlm_subagent_register_command/8
    -> prompt_command_execute/6
    -> canonical completed subagent_result
    -> exactly one trusted continuation call

Only a canonical completed child result is resumable. Failed, cancelled,
timed-out, budget-exhausted, malformed, or otherwise non-completed child
results remain explicit errors and never enter the continuation as success.
*/

:- use_module(rlm_agent, []).
:- use_module(rlm_prompt_command, []).
:- use_module(rlm_subagent, []).
:- use_module(rlm_tool, []).

:- meta_predicate delegation_resume(+,+,+,+,+,+,+,+,2,-).

rlm_delegation_runtime_ready.

delegation_resume(Records,
                  Trigger,
                  Runtime,
                  Parent,
                  ChildCapabilities,
                  Context,
                  CompletionOptions,
                  ToolOptions,
                  ResumeHandler,
                  Outcome) :-
    catch(delegation_resume_(Records,
                             Trigger,
                             Runtime,
                             Parent,
                             ChildCapabilities,
                             Context,
                             CompletionOptions,
                             ToolOptions,
                             ResumeHandler,
                             Outcome),
          Exception,
          delegation_exception(Exception, Outcome)).

delegation_resume_(Records,
                   Trigger,
                   Runtime,
                   Parent,
                   ChildCapabilities,
                   Context,
                   CompletionOptions,
                   ToolOptions,
                   ResumeHandler,
                   Outcome) :-
    require_resume_handler(ResumeHandler),
    require_list(CompletionOptions, completion_options),
    require_list(ToolOptions, tool_options),
    parent_capabilities(Runtime, Parent, ParentCapabilities),
    rlm_prompt_command:prompt_command_compile(Records,
                                               Trigger,
                                               CompileOutcome),
    delegation_after_compile(CompileOutcome,
                             Trigger,
                             Runtime,
                             Parent,
                             ParentCapabilities,
                             ChildCapabilities,
                             Context,
                             CompletionOptions,
                             ToolOptions,
                             ResumeHandler,
                             Outcome).

parent_capabilities(Runtime, Parent, Capabilities) :-
    rlm_agent:agent_status(Runtime, Parent, StatusOutcome),
    require_parent_status(StatusOutcome, Parent, Capabilities).

require_parent_status(ok(Status), _, Capabilities) :-
    is_dict(Status),
    get_dict(capabilities, Status, Capabilities),
    is_list(Capabilities),
    !.
require_parent_status(error(Error), Parent, _) :-
    !,
    throw(delegation_runtime_fault(parent_status_failed(Parent, Error))).
require_parent_status(Status, Parent, _) :-
    throw(delegation_runtime_fault(invalid_parent_status(Parent, Status))).

delegation_after_compile(error(Error), _, _, _, _, _, _, _, _, _,
                         error(Error)) :-
    !.
delegation_after_compile(ok(Command),
                         Trigger,
                         Runtime,
                         Parent,
                         ParentCapabilities,
                         ChildCapabilities,
                         Context,
                         CompletionOptions,
                         ToolOptions,
                         ResumeHandler,
                         Outcome) :-
    setup_call_cleanup(
        rlm_tool:tool_registry_create(Registry),
        register_execute_resume(Registry,
                                Command,
                                Trigger,
                                Runtime,
                                Parent,
                                ParentCapabilities,
                                ChildCapabilities,
                                Context,
                                CompletionOptions,
                                ToolOptions,
                                ResumeHandler,
                                Outcome),
        rlm_tool:tool_registry_destroy(Registry)).

register_execute_resume(Registry,
                        Command,
                        Trigger,
                        Runtime,
                        Parent,
                        ParentCapabilities,
                        ChildCapabilities,
                        Context,
                        CompletionOptions,
                        ToolOptions,
                        ResumeHandler,
                        Outcome) :-
    rlm_subagent:rlm_subagent_register_command(Registry,
                                                Runtime,
                                                Parent,
                                                ChildCapabilities,
                                                Context,
                                                CompletionOptions,
                                                Command,
                                                RegisterOutcome),
    delegation_after_register(RegisterOutcome,
                              Registry,
                              Command,
                              Trigger,
                              ParentCapabilities,
                              ToolOptions,
                              ResumeHandler,
                              Outcome).

delegation_after_register(error(Error), _, _, _, _, _, _,
                          error(DelegationError)) :-
    !,
    DelegationError = delegation_runtime_error{
                          phase:register,
                          kind:subagent_registration_failed,
                          cause:Error,
                          message:"canonical subagent registration failed"
                      }.
delegation_after_register(ok(_),
                          Registry,
                          Command,
                          Trigger,
                          ParentCapabilities,
                          ToolOptions,
                          ResumeHandler,
                          Outcome) :-
    rlm_prompt_command:prompt_command_execute(Command,
                                               Registry,
                                               ParentCapabilities,
                                               ToolOptions,
                                               ExecuteOutcome,
                                               ToolTrace),
    delegation_after_execute(ExecuteOutcome,
                             ToolTrace,
                             Command,
                             Trigger,
                             ResumeHandler,
                             Outcome).

delegation_after_execute(error(Error), _, _, _, _, error(Error)) :-
    !.
delegation_after_execute(ok(Execution),
                         ToolTrace,
                         Command,
                         Trigger,
                         ResumeHandler,
                         Outcome) :-
    child_envelope(Execution, EnvelopeOutcome),
    delegation_after_child(EnvelopeOutcome,
                           ToolTrace,
                           Command,
                           Trigger,
                           ResumeHandler,
                           Outcome).

child_envelope(Execution, Outcome) :-
    (   is_dict(Execution),
        get_dict(value, Execution, Envelope),
        is_dict(Envelope, subagent_result),
        ground(Envelope),
        get_dict(status, Envelope, Status)
    ->  child_status(Status, Envelope, Outcome)
    ;   Outcome = error(delegation_runtime_error{
                            phase:child_result,
                            kind:malformed_child_result,
                            message:"typed subagent execution did not return a closed canonical child result"
                        })
    ).

child_status(completed, Envelope, ok(Envelope)) :- !.
child_status(failed, Envelope, error(Error)) :-
    !,
    child_error_or_none(Envelope, Cause),
    Error = delegation_runtime_error{
                phase:child_result,
                kind:child_failed,
                cause:Cause,
                child_result:Envelope,
                message:"failed child result cannot resume the parent"
            }.
child_status(cancelled, Envelope, error(Error)) :-
    !,
    Error = delegation_runtime_error{
                phase:child_result,
                kind:child_cancelled,
                child_result:Envelope,
                message:"cancelled child result cannot resume the parent"
            }.
child_status(timeout, Envelope, error(Error)) :-
    !,
    Error = delegation_runtime_error{
                phase:child_result,
                kind:child_timeout,
                child_result:Envelope,
                message:"timed-out child result cannot resume the parent"
            }.
child_status(budget_exhausted, Envelope, error(Error)) :-
    !,
    Error = delegation_runtime_error{
                phase:child_result,
                kind:child_budget_exhausted,
                child_result:Envelope,
                message:"budget-exhausted child result cannot resume the parent"
            }.
child_status(Status, Envelope, error(Error)) :-
    Error = delegation_runtime_error{
                phase:child_result,
                kind:child_not_resumable,
                status:Status,
                child_result:Envelope,
                message:"only a completed canonical child result may resume the parent"
            }.

child_error_or_none(Envelope, Cause) :-
    (   get_dict(error, Envelope, Error)
    ->  Cause = Error
    ;   Cause = none
    ).

delegation_after_child(error(Error), _, _, _, _, error(Error)) :-
    !.
delegation_after_child(ok(Envelope),
                       ToolTrace,
                       Command,
                       Trigger,
                       ResumeHandler,
                       Outcome) :-
    resume_input(Command, Trigger, Envelope, ResumeInput),
    invoke_resume_handler(ResumeHandler, ResumeInput, ResumeOutcome),
    delegation_after_resume(ResumeOutcome,
                            ToolTrace,
                            Command,
                            Envelope,
                            ResumeInput,
                            Outcome).

resume_input(Command, Trigger, Envelope, ResumeInput) :-
    ResumeInput = delegation_resume_input{
                      trigger:Trigger,
                      prompt_id:Command.prompt_id,
                      command_fingerprint:Command.fingerprint,
                      child_result:Envelope,
                      evidence:Envelope.evidence,
                      usage:Envelope.usage,
                      correlation:Envelope.correlation,
                      delegation:Envelope.delegation,
                      trace:Envelope.trace
                  }.

invoke_resume_handler(ResumeHandler, ResumeInput, Outcome) :-
    catch((   once(call(ResumeHandler, ResumeInput, Raw))
          ->  normalize_resume_outcome(Raw, Outcome)
          ;   Outcome = error(delegation_runtime_error{
                                  phase:resume,
                                  kind:continuation_failed,
                                  message:"trusted continuation failed without a structured outcome"
                              })
          ),
          Exception,
          resume_exception(Exception, Outcome)).

normalize_resume_outcome(ok(Value), ok(Value)) :-
    ground(Value),
    !.
normalize_resume_outcome(error(Error), error(DelegationError)) :-
    ground(Error),
    !,
    DelegationError = delegation_runtime_error{
                          phase:resume,
                          kind:continuation_error,
                          cause:Error,
                          message:"trusted continuation returned an explicit failure"
                      }.
normalize_resume_outcome(Raw, error(Error)) :-
    safe_term(Raw, Shape),
    Error = delegation_runtime_error{
                phase:resume,
                kind:invalid_continuation_result,
                result:Shape,
                message:"trusted continuation must return closed ok(Value) or error(Error)"
            }.

delegation_after_resume(error(Error), _, _, _, _, error(Error)) :-
    !.
delegation_after_resume(ok(Continuation),
                        ToolTrace,
                        Command,
                        Envelope,
                        ResumeInput,
                        ok(Result)) :-
    Result = delegation_resume_result{
                 command:Command,
                 child_result:Envelope,
                 resume_input:ResumeInput,
                 continuation:Continuation,
                 trace:delegation_resume_trace{
                           status:resumed,
                           command_fingerprint:Command.fingerprint,
                           tool:ToolTrace
                       }
             }.

require_resume_handler(Handler) :-
    callable(Handler),
    ground(Handler),
    !.
require_resume_handler(Handler) :-
    throw(delegation_runtime_fault(invalid_resume_handler(Handler))).

require_list(Value, _) :- is_list(Value), !.
require_list(Value, Field) :-
    throw(delegation_runtime_fault(expected_list(Field, Value))).

resume_exception(Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
resume_exception(Exception, error(Error)) :-
    safe_term(Exception, Safe),
    Error = delegation_runtime_error{
                phase:resume,
                kind:continuation_exception,
                exception:Safe,
                message:"trusted continuation raised an exception"
            }.

delegation_exception(Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
delegation_exception(delegation_runtime_fault(Detail), error(Error)) :-
    !,
    safe_term(Detail, Safe),
    Error = delegation_runtime_error{
                phase:validate,
                kind:invalid_runtime_request,
                detail:Safe,
                message:"delegation resume request is invalid"
            }.
delegation_exception(Exception, error(Error)) :-
    safe_term(Exception, Safe),
    Error = delegation_runtime_error{
                phase:runtime,
                kind:exception,
                exception:Safe,
                message:"delegation resume runtime raised an exception"
            }.

control_exception(time_limit_exceeded).
control_exception(time_limit_exceeded(_)).
control_exception('$aborted').
control_exception(abort).
control_exception(cancelled(_)).
control_exception(rlm_cancelled(_)).
control_exception(chain_cancelled(_)).
control_exception(graph_cancelled(_)).

safe_term(Term, Safe) :-
    term_string(Term, Safe, [quoted(true), numbervars(true)]).
