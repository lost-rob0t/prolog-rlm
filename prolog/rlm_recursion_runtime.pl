:- module(rlm_recursion_runtime,
          [ rlm_recursion_runtime_ready/0,
            recursion_execute/4,
            recursion_execution_context/4
          ]).

/** <module> Executable adaptive recursion routing

This module turns a policy decision into one bounded runtime action.  It does
not perform provider inference itself.  Callers supply explicit route handlers,
so direct continuation, deterministic context work, cheap-model delegation,
recursive RLM work, and supervised-agent delegation remain capability/runtime
boundaries rather than hidden policy side effects.
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

normalize_handler_outcome(ok(Value), ok(Value)) :- !.
normalize_handler_outcome(error(Error), error(Error)) :- !.
normalize_handler_outcome(Value, ok(Value)).

finish_execution(error(Error), _, _, _, error(Error)) :- !.
finish_execution(ok(Value), Decision, Context, IsRecursive, ok(Result)) :-
    next_fingerprints(IsRecursive,
                      Context.fingerprint,
                      Context.previous_fingerprints,
                      NextFingerprints),
    next_depth(IsRecursive,
               Context.signals.current_depth,
               NextDepth),
    Result = recursion_execution{
                 selected_policy:Decision.policy,
                 decision:Decision,
                 result:Value,
                 fingerprint:Context.fingerprint,
                 next_fingerprints:NextFingerprints,
                 next_depth:NextDepth,
                 trace:[Decision.trace,
                        recursion_trace{
                            type:recursion_route_executed,
                            selected_policy:Decision.policy,
                            fingerprint:Context.fingerprint,
                            recursive:IsRecursive,
                            next_depth:NextDepth
                        }]
             }.

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
    Request = recursion_request{
                  subject:Subject,
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
