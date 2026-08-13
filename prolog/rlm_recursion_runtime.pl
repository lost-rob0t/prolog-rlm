:- module(rlm_recursion_runtime,
          [ rlm_recursion_runtime_ready/0,
            recursion_execute/4,
            recursion_execution_context/4
          ]).

/** <module> Executable adaptive recursion routing

This module turns a policy decision into one bounded runtime action. It does
not perform provider inference itself. Callers supply explicit route handlers,
so direct continuation, deterministic context work, cheap-model delegation,
recursive RLM work, and supervised-agent delegation remain capability/runtime
boundaries rather than hidden policy side effects.

Handlers may return plain values, `ok(Value)`, `error(Error)`, or
`ok(Value, Metadata)`. Metadata can report `actual_cost`, `usage`, and a
`child_identity`. The execution trace always exposes parent/child identity,
reason, estimated cost, actual cost/usage (or `unknown`), and depth.
*/

:- use_module(library(option)).
:- use_module(rlm_recursion_policy).

rlm_recursion_runtime_ready.

recursion_execute(Signals0, Request0, Options, Outcome) :-
    catch(recursion_execute_(Signals0, Request0, Options, Outcome),
          Exception,
          runtime_exception(execute, Exception, Outcome)).

recursion_execute_(Signals0, Request0, Options, Outcome) :-
    normalize_request(Request0, Request),
    require_options(Options),
    recursion_execution_context(Signals0, Request, Options, ContextOutcome),
    (   ContextOutcome = ok(Context)
    ->  recursion_route(Context.signals,
                        Context.policy_options,
                        RouteOutcome),
        execute_route_outcome(RouteOutcome,
                              Context,
                              Request,
                              Outcome)
    ;   ContextOutcome = error(Error),
        Outcome = error(Error)
    ).

recursion_execution_context(Signals0, Request0, Options, Outcome) :-
    catch(( normalize_request(Request0, Request),
            require_options(Options),
            execution_context(Signals0, Request, Options, Context),
            Outcome = ok(Context) ),
          Exception,
          runtime_exception(context, Exception, Outcome)).

execution_context(Signals0, Request, Options, Context) :-
    require_dict(Signals0, signals),
    handler_available(Request, deterministic_context, DeterministicAvailable),
    handler_available(Request, cheap_submodel, CheapAvailable),
    handler_available(Request, delegated_subagent, DelegatedAvailable),
    handler_available(Request, recursive_rlm, RecursiveAvailable),
    request_fingerprint(Request, Fingerprint),
    option(previous_fingerprints(Previous0), Options, []),
    require_list(Previous0, previous_fingerprints),
    sort(Previous0, Previous),
    (   memberchk(Fingerprint, Previous)
    ->  Duplicate = true
    ;   Duplicate = false
    ),
    put_dict(_{deterministic_context_available:DeterministicAvailable,
               cheap_submodel_available:CheapAvailable,
               delegated_subagent_available:DelegatedAvailable,
               duplicate:Duplicate},
             Signals0,
             Signals1),
    constrain_recursive_availability(RecursiveAvailable, Signals1, Signals),
    policy_options_for_request(Request, Options, PolicyOptions),
    Context = recursion_execution_context{
                  signals:Signals,
                  fingerprint:Fingerprint,
                  parent_identity:Request.parent_identity,
                  previous_fingerprints:Previous,
                  policy_options:PolicyOptions
              }.

constrain_recursive_availability(true, Signals, Signals) :- !.
constrain_recursive_availability(false, Signals0, Signals) :-
    put_dict(_{remaining_calls:0}, Signals0, Signals).

policy_options_for_request(Request, Options, PolicyOptions) :-
    exclude(runtime_only_option, Options, BaseOptions),
    Request.selector = Selector,
    Request.generator = Generator,
    add_option_if_present(candidate_selector, Selector, BaseOptions, O1),
    add_option_if_present(candidate_generator, Generator, O1, PolicyOptions).

runtime_only_option(previous_fingerprints(_)).
runtime_only_option(progress(_)).

add_option_if_present(_, none, Options, Options) :- !.
add_option_if_present(Name, Value, Options0, [Option|Options0]) :-
    Option =.. [Name, Value].

execute_route_outcome(error(Error), _, _, error(Error)) :- !.
execute_route_outcome(ok(Decision), Context, Request, Outcome) :-
    Selected = Decision.policy,
    (   route_handler(Request, Selected, Handler)
    ->  execute_selected(Selected,
                         Handler,
                         Decision,
                         Context,
                         Request,
                         Outcome)
    ;   redirect_unavailable(Decision,
                             Context,
                             Request,
                             Outcome)
    ).

execute_selected(recursive_rlm,
                 Handler,
                 Decision,
                 Context,
                 Request,
                 Outcome) :-
    !,
    progress_value(Context.signals, Progress),
    recursion_guard(Context.fingerprint,
                    Context.previous_fingerprints,
                    Progress,
                    Context.policy_options,
                    GuardOutcome),
    (   GuardOutcome = ok
    ->  invoke_handler(Handler,
                       Decision,
                       Request.subject,
                       HandlerOutcome),
        finish_execution(HandlerOutcome,
                         Decision,
                         Context,
                         true,
                         Outcome)
    ;   GuardOutcome = error(Error),
        Outcome = error(Error)
    ).
execute_selected(_, Handler, Decision, Context, Request, Outcome) :-
    invoke_handler(Handler,
                   Decision,
                   Request.subject,
                   HandlerOutcome),
    finish_execution(HandlerOutcome,
                     Decision,
                     Context,
                     false,
                     Outcome).

redirect_unavailable(Decision, Context, Request, Outcome) :-
    available_candidates(Decision.candidates, Request, Available),
    (   Available = [Alternative|_]
    ->  AlternativeDecision = Decision.put(_{
                                  policy:Alternative.route,
                                  reason:selected_route_unavailable,
                                  expected_utility:Alternative.expected_utility,
                                  estimated_cost:Alternative.estimated_cost,
                                  expected_value:Alternative.expected_value
                              }),
        route_handler(Request, Alternative.route, Handler),
        execute_selected(Alternative.route,
                         Handler,
                         AlternativeDecision,
                         Context,
                         Request,
                         Outcome)
    ;   Outcome = error(recursion_runtime_error{
                            phase:execute,
                            kind:no_available_route,
                            selected_policy:Decision.policy,
                            message:"adaptive recursion selected no executable route"
                        })
    ).

available_candidates(Candidates, Request, Available) :-
    include(candidate_has_handler(Request), Candidates, Available).

candidate_has_handler(Request, Candidate) :-
    route_handler(Request, Candidate.route, _).

invoke_handler(Handler, Decision, Subject, Outcome) :-
    catch((   call(Handler, Decision, Subject, Raw)
          ->  normalize_handler_outcome(Raw, Outcome)
          ;   Outcome = error(recursion_runtime_error{
                                  phase:handler,
                                  kind:handler_failed,
                                  route:Decision.policy,
                                  message:"selected recursion route handler failed"
                              })
          ),
          Exception,
          handler_exception(Decision.policy, Exception, Outcome)).

normalize_handler_outcome(error(Error), error(Error)) :- !.
normalize_handler_outcome(ok(Value, Metadata0), ok(Result)) :-
    !,
    normalize_handler_metadata(Metadata0, Metadata),
    Result = handler_result{value:Value, metadata:Metadata}.
normalize_handler_outcome(ok(Value), ok(Result)) :-
    !,
    empty_handler_metadata(Metadata),
    Result = handler_result{value:Value, metadata:Metadata}.
normalize_handler_outcome(Value, ok(Result)) :-
    empty_handler_metadata(Metadata),
    Result = handler_result{value:Value, metadata:Metadata}.

empty_handler_metadata(
    handler_metadata{actual_cost:unknown,
                     usage:unknown,
                     child_identity:auto}).

normalize_handler_metadata(Metadata0, Metadata) :-
    require_dict(Metadata0, handler_metadata),
    metadata_actual_cost(Metadata0, ActualCost),
    metadata_ground_value(Metadata0, usage, unknown, Usage),
    metadata_ground_value(Metadata0,
                          child_identity,
                          auto,
                          ChildIdentity),
    Metadata = handler_metadata{actual_cost:ActualCost,
                                usage:Usage,
                                child_identity:ChildIdentity}.

metadata_actual_cost(Metadata, ActualCost) :-
    (   get_dict(actual_cost, Metadata, Raw)
    ->  normalize_actual_cost(Raw, ActualCost)
    ;   ActualCost = unknown
    ).

normalize_actual_cost(unknown, unknown) :- !.
normalize_actual_cost(Value, Cost) :-
    number(Value),
    Value >= 0,
    !,
    Cost is float(Value).
normalize_actual_cost(Value, _) :-
    throw(recursion_runtime_fault(invalid_actual_cost(Value))).

metadata_ground_value(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Raw)
    ->  ground_value(Raw, Key),
        Value = Raw
    ;   Value = Default
    ).

ground_value(Value, _) :- ground(Value), !.
ground_value(Value, Name) :-
    throw(recursion_runtime_fault(non_ground_metadata(Name, Value))).

finish_execution(error(Error), _, _, _, error(Error)) :- !.
finish_execution(ok(HandlerResult),
                 Decision,
                 Context,
                 IsRecursive,
                 ok(Result)) :-
    Value = HandlerResult.value,
    Metadata = HandlerResult.metadata,
    next_fingerprints(IsRecursive,
                      Context.fingerprint,
                      Context.previous_fingerprints,
                      NextFingerprints),
    next_depth(IsRecursive,
               Context.signals.current_depth,
               NextDepth),
    child_identity(Decision,
                   Context,
                   Metadata.child_identity,
                   ChildIdentity),
    ExecutionTrace = recursion_trace{
                         type:recursion_route_executed,
                         selected_policy:Decision.policy,
                         reason:Decision.reason,
                         fingerprint:Context.fingerprint,
                         parent_identity:Context.parent_identity,
                         child_identity:ChildIdentity,
                         recursive:IsRecursive,
                         depth:NextDepth,
                         next_depth:NextDepth,
                         estimated_cost:Decision.estimated_cost,
                         actual_cost:Metadata.actual_cost,
                         actual_usage:Metadata.usage
                     },
    Result = recursion_execution{
                 selected_policy:Decision.policy,
                 decision:Decision,
                 result:Value,
                 fingerprint:Context.fingerprint,
                 parent_identity:Context.parent_identity,
                 child_identity:ChildIdentity,
                 estimated_cost:Decision.estimated_cost,
                 actual_cost:Metadata.actual_cost,
                 actual_usage:Metadata.usage,
                 next_fingerprints:NextFingerprints,
                 next_depth:NextDepth,
                 trace:[Decision.trace, ExecutionTrace]
             }.

child_identity(_, _, ChildIdentity, ChildIdentity) :-
    ChildIdentity \== auto,
    !.
child_identity(Decision, Context, auto, ChildIdentity) :-
    atomic_list_concat([Decision.policy, Context.fingerprint],
                       ':',
                       ChildIdentity).

next_fingerprints(true, Fingerprint, Previous, Next) :-
    !,
    sort([Fingerprint|Previous], Next).
next_fingerprints(false, _, Previous, Previous).

next_depth(true, Current, Next) :- !, Next is Current+1.
next_depth(false, Current, Current).

progress_value(Signals, Progress) :-
    (   get_dict(progress, Signals, Progress0)
    ->  Progress = Progress0
    ;   Progress = 1.0
    ).

/* Request --------------------------------------------------------------- */

normalize_request(Request0, Request) :-
    require_dict(Request0, request),
    require_key(Request0, subject, Subject),
    ground_subject(Subject),
    normalize_handler(Request0, direct_continuation, Direct),
    normalize_handler(Request0, deterministic_context, Deterministic),
    normalize_handler(Request0, cheap_submodel, Cheap),
    normalize_handler(Request0, recursive_rlm, Recursive),
    normalize_handler(Request0, delegated_subagent, Delegated),
    normalize_hook(Request0, selector, Selector),
    normalize_hook(Request0, generator, Generator),
    normalize_identity(Request0, parent_identity, root, ParentIdentity),
    Request = recursion_request{
                  subject:Subject,
                  parent_identity:ParentIdentity,
                  direct_continuation:Direct,
                  deterministic_context:Deterministic,
                  cheap_submodel:Cheap,
                  recursive_rlm:Recursive,
                  delegated_subagent:Delegated,
                  selector:Selector,
                  generator:Generator
              }.

normalize_handler(Dict, Key, Handler) :-
    (   get_dict(Key, Dict, Raw)
    ->  callable_or_none(Raw, Key),
        Handler = Raw
    ;   Handler = none
    ).

normalize_hook(Dict, Key, Hook) :-
    (   get_dict(Key, Dict, Raw)
    ->  callable_or_none(Raw, Key),
        Hook = Raw
    ;   Hook = none
    ).

normalize_identity(Dict, Key, Default, Identity) :-
    (   get_dict(Key, Dict, Raw)
    ->  ground_value(Raw, Key),
        Identity = Raw
    ;   Identity = Default
    ).

handler_available(Request, Route, true) :-
    route_handler(Request, Route, _),
    !.
handler_available(_, _, false).

route_handler(Request, direct_continuation, Handler) :-
    Handler = Request.direct_continuation,
    Handler \== none.
route_handler(Request, deterministic_context, Handler) :-
    Handler = Request.deterministic_context,
    Handler \== none.
route_handler(Request, cheap_submodel, Handler) :-
    Handler = Request.cheap_submodel,
    Handler \== none.
route_handler(Request, recursive_rlm, Handler) :-
    Handler = Request.recursive_rlm,
    Handler \== none.
route_handler(Request, delegated_subagent, Handler) :-
    Handler = Request.delegated_subagent,
    Handler \== none.

request_fingerprint(Request, Fingerprint) :-
    recursion_fingerprint(Request.subject, Fingerprint).

ground_subject(Subject) :-
    (   ground(Subject)
    ->  true
    ;   throw(recursion_runtime_fault(non_ground_subject(Subject)))
    ).

/* Errors and validation ------------------------------------------------- */

handler_exception(_, Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
handler_exception(Route, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = recursion_runtime_error{
                phase:handler,
                kind:handler_exception,
                route:Route,
                exception:Safe,
                message:"selected recursion route handler raised an exception"
            }.

runtime_exception(_, Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
runtime_exception(Phase, recursion_runtime_fault(Detail), error(Error)) :-
    !,
    Error = recursion_runtime_error{
                phase:Phase,
                kind:runtime_error,
                detail:Detail,
                message:"adaptive recursion runtime rejected the request"
            }.
runtime_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = recursion_runtime_error{
                phase:Phase,
                kind:exception,
                exception:Safe,
                message:"adaptive recursion runtime raised an exception"
            }.

control_exception(time_limit_exceeded).
control_exception('$aborted').
control_exception(abort).
control_exception(cancelled(_)).
control_exception(rlm_cancelled(_)).
control_exception(chain_cancelled(_)).
control_exception(graph_cancelled(_)).

require_dict(Value, _) :- is_dict(Value), !.
require_dict(Value, Name) :-
    throw(recursion_runtime_fault(expected_dict(Name, Value))).

require_options(Options) :- is_list(Options), !.
require_options(Options) :-
    throw(recursion_runtime_fault(invalid_options(Options))).

require_list(Value, _) :- is_list(Value), !.
require_list(Value, Name) :-
    throw(recursion_runtime_fault(expected_list(Name, Value))).

require_key(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(recursion_runtime_fault(missing_key(Key)))
    ).

callable_or_none(none, _) :- !.
callable_or_none(Value, _) :- callable(Value), !.
callable_or_none(Value, Name) :-
    throw(recursion_runtime_fault(invalid_callable(Name, Value))).
