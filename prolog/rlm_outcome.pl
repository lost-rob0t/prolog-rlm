:- module(rlm_outcome,
          [ plan_outcome/5,
            goal_outcome/3,
            plan_inspect/4,
            predicate_inspect/2,
            outcome_trace/3,
            plan_repair/6,
            default_outcome_limits/1
          ]).

/** <module> Structured execution outcomes, inspection, and bounded repair

This module is the diagnostic boundary above the closed plan runtime. It maps
plan and trusted-host goal execution into one serializable outcome vocabulary,
builds bounded trace trees, exposes inspection helpers, and supports scoped
plan repair without resetting the original execution budget.
*/

:- use_module(library(lists)).
:- use_module(library(time)).
:- use_module(rlm_plan).

:- meta_predicate goal_outcome(0, +, -).
:- meta_predicate predicate_inspect(:, -).
:- meta_predicate plan_repair(+, +, +, +, 4, -).

default_outcome_limits(
    outcome_limits{trace_max_nodes:64,
                   trace_max_bytes:8192,
                   goal_time_limit:2.0,
                   goal_depth_limit:256,
                   max_repairs:2,
                   repair_time_limit:2.0}).

/* -------------------------------------------------------------------------
 * Plan outcomes
 * ---------------------------------------------------------------------- */

plan_outcome(Plan, Capabilities, Options, Inputs, Outcome) :-
    catch(plan_outcome_(Plan, Capabilities, Options, Inputs, Outcome),
          Exception,
          unexpected_outcome_exception(plan, Exception, Outcome)).

plan_outcome_(Plan, Capabilities, Options, Inputs, Outcome) :-
    require_list(Options, options),
    outcome_limits(Options, Limits),
    plan_run(Plan, Capabilities, Options, Inputs, Raw),
    normalize_plan_result(Raw, Limits, Outcome).

normalize_plan_result(ok(Result), Limits, Outcome) :-
    !,
    plan_success_trace(Result, Limits, Trace),
    Outcome = execution_outcome{
                  status:success,
                  kind:plan,
                  phase:execute,
                  value:Result.value,
                  bindings:Result.vars,
                  residual_constraints:[],
                  error:none,
                  trace:Trace,
                  budget_remaining:Result.budget_remaining,
                  checkpoints:Result.checkpoints
              }.
normalize_plan_result(error(Error), Limits, Outcome) :-
    classify_plan_error(Error, Status, Phase),
    error_transitions(Error, Transitions),
    bounded_transition_trace(Transitions, Status, Limits, Trace),
    error_budget_remaining(Error, Remaining),
    Outcome = execution_outcome{
                  status:Status,
                  kind:plan,
                  phase:Phase,
                  value:none,
                  bindings:_{},
                  residual_constraints:[],
                  error:Error,
                  trace:Trace,
                  budget_remaining:Remaining,
                  checkpoints:[]
              }.

classify_plan_error(Error, capability_denied, Phase) :-
    dict_field(Error, phase, validate, Phase),
    dict_field(Error, kind, unknown, capability_denied),
    !.
classify_plan_error(Error, depth_exhausted, Phase) :-
    dict_field(Error, phase, validate, Phase),
    dict_field(Error, kind, unknown, budget_exceeded),
    dict_field(Error, budget, unknown, depth),
    !.
classify_plan_error(Error, resource_exhausted, Phase) :-
    dict_field(Error, phase, validate, Phase),
    dict_field(Error, kind, unknown, Kind),
    memberchk(Kind, [budget_exceeded, budget_exhausted]),
    !.
classify_plan_error(Error, resource_exhausted, Phase) :-
    dict_field(Error, phase, execute, Phase),
    dict_field(Error, kind, unknown, budget_exhausted),
    !.
classify_plan_error(Error, timeout, Phase) :-
    dict_field(Error, phase, execute, Phase),
    dict_field(Error, kind, unknown, Kind),
    memberchk(Kind, [time_limit_exceeded, timeout]),
    !.
classify_plan_error(Error, validation_failure, Phase) :-
    dict_field(Error, phase, unknown, Phase),
    memberchk(Phase, [parse, normalize, validate, preflight]),
    !.
classify_plan_error(Error, exception, Phase) :-
    dict_field(Error, phase, execute, Phase),
    !.
classify_plan_error(Error, exception, Phase) :-
    dict_field(Error, phase, unknown, Phase).

/* -------------------------------------------------------------------------
 * Trusted host goal outcomes
 * ---------------------------------------------------------------------- */

goal_outcome(Goal, Options, Outcome) :-
    catch(goal_outcome_(Goal, Options, Outcome),
          Exception,
          unexpected_outcome_exception(goal, Exception, Outcome)).

goal_outcome_(Goal, Options, Outcome) :-
    require_list(Options, options),
    outcome_limits(Options, Limits),
    get_time(Start),
    run_goal_bounded(Goal, Limits, Raw),
    get_time(End),
    ElapsedMs is round((End-Start)*1000),
    normalize_goal_result(Raw, Goal, ElapsedMs, Limits, Outcome).

run_goal_bounded(Goal, Limits, Raw) :-
    catch(call_with_time_limit(
              Limits.goal_time_limit,
              run_goal_depth(Goal, Limits.goal_depth_limit, Raw0)),
          Exception,
          goal_control_exception(Exception, Raw0)),
    Raw = Raw0.

run_goal_depth(Goal, DepthLimit, Raw) :-
    (   call_with_depth_limit(Goal, DepthLimit, DepthResult)
    ->  (   DepthResult == depth_limit_exceeded
        ->  Raw = depth_exhausted
        ;   copy_term(Goal, BoundGoal, ResidualGoals),
            Raw = success(BoundGoal, ResidualGoals)
        )
    ;   Raw = logical_failure
    ).

goal_control_exception(time_limit_exceeded, timeout) :- !.
goal_control_exception(time_limit_exceeded(_), timeout) :- !.
goal_control_exception(Exception, exception(Safe)) :-
    safe_exception(Exception, Safe).

normalize_goal_result(success(BoundGoal, ResidualGoals), Goal, ElapsedMs,
                      Limits, Outcome) :-
    !,
    goal_trace(Goal, success, ElapsedMs, Limits, Trace),
    Outcome = execution_outcome{
                  status:success,
                  kind:goal,
                  phase:execute,
                  value:true,
                  bindings:BoundGoal,
                  residual_constraints:ResidualGoals,
                  error:none,
                  trace:Trace,
                  budget_remaining:unknown,
                  checkpoints:[]
              }.
normalize_goal_result(logical_failure, Goal, ElapsedMs, Limits, Outcome) :-
    !,
    goal_trace(Goal, logical_failure, ElapsedMs, Limits, Trace),
    Outcome = execution_outcome{
                  status:logical_failure,
                  kind:goal,
                  phase:execute,
                  value:false,
                  bindings:none,
                  residual_constraints:[],
                  error:none,
                  trace:Trace,
                  budget_remaining:unknown,
                  checkpoints:[]
              }.
normalize_goal_result(timeout, Goal, ElapsedMs, Limits, Outcome) :-
    !,
    goal_trace(Goal, timeout, ElapsedMs, Limits, Trace),
    Outcome = execution_outcome{
                  status:timeout,
                  kind:goal,
                  phase:execute,
                  value:none,
                  bindings:none,
                  residual_constraints:[],
                  error:goal_error{kind:timeout,
                                   message:"goal exceeded its wall-time limit"},
                  trace:Trace,
                  budget_remaining:unknown,
                  checkpoints:[]
              }.
normalize_goal_result(depth_exhausted, Goal, ElapsedMs, Limits, Outcome) :-
    !,
    goal_trace(Goal, depth_exhausted, ElapsedMs, Limits, Trace),
    Outcome = execution_outcome{
                  status:depth_exhausted,
                  kind:goal,
                  phase:execute,
                  value:none,
                  bindings:none,
                  residual_constraints:[],
                  error:goal_error{kind:depth_exhausted,
                                   message:"goal exceeded its depth limit"},
                  trace:Trace,
                  budget_remaining:unknown,
                  checkpoints:[]
              }.
normalize_goal_result(exception(Safe), Goal, ElapsedMs, Limits, Outcome) :-
    goal_trace(Goal, exception, ElapsedMs, Limits, Trace),
    Outcome = execution_outcome{
                  status:exception,
                  kind:goal,
                  phase:execute,
                  value:none,
                  bindings:none,
                  residual_constraints:[],
                  error:goal_error{kind:exception,
                                   exception:Safe,
                                   message:"goal raised an exception"},
                  trace:Trace,
                  budget_remaining:unknown,
                  checkpoints:[]
              }.

/* -------------------------------------------------------------------------
 * Inspection
 * ---------------------------------------------------------------------- */

plan_inspect(Plan, Capabilities, Budget, Inspection) :-
    plan_parse(Plan, ParseOutcome),
    inspect_parsed_plan(ParseOutcome, Capabilities, Budget, Inspection).

inspect_parsed_plan(error(Error), _, _, Inspection) :-
    !,
    classify_plan_error(Error, Status, Phase),
    Inspection = plan_inspection{status:Status,
                                 phase:Phase,
                                 normalized_plan:none,
                                 provided_capabilities:[],
                                 required_capabilities:[],
                                 estimate:none,
                                 error:Error}.
inspect_parsed_plan(ok(Normalized), Capabilities, Budget, Inspection) :-
    plan_required_capabilities(Normalized, Required),
    plan_validate(Normalized, Capabilities, Budget, Validation),
    inspect_validated_plan(Validation,
                           Normalized,
                           Capabilities,
                           Required,
                           Inspection).

inspect_validated_plan(ok(Validated), Normalized, Capabilities, Required,
                       Inspection) :-
    !,
    Inspection = plan_inspection{status:success,
                                 phase:validate,
                                 normalized_plan:Normalized,
                                 provided_capabilities:Capabilities,
                                 required_capabilities:Required,
                                 estimate:Validated.estimate,
                                 error:none}.
inspect_validated_plan(error(Error), Normalized, Capabilities, Required,
                       Inspection) :-
    classify_plan_error(Error, Status, Phase),
    Inspection = plan_inspection{status:Status,
                                 phase:Phase,
                                 normalized_plan:Normalized,
                                 provided_capabilities:Capabilities,
                                 required_capabilities:Required,
                                 estimate:none,
                                 error:Error}.

predicate_inspect(Callable0, Inspection) :-
    strip_module(Callable0, Module, Callable),
    callable(Callable),
    functor(Callable, Name, Arity),
    length(Args, Arity),
    Head =.. [Name|Args],
    Qualified = Module:Head,
    findall(Property,
            inspectable_predicate_property(Qualified, Property),
            Properties0),
    sort(Properties0, Properties),
    Inspection = predicate_inspection{module:Module,
                                      name:Name,
                                      arity:Arity,
                                      properties:Properties}.

inspectable_predicate_property(Head, dynamic) :- predicate_property(Head, dynamic).
inspectable_predicate_property(Head, static) :- predicate_property(Head, static).
inspectable_predicate_property(Head, multifile) :- predicate_property(Head, multifile).
inspectable_predicate_property(Head, imported_from(Module)) :-
    predicate_property(Head, imported_from(Module)).
inspectable_predicate_property(Head, meta_predicate(Template)) :-
    predicate_property(Head, meta_predicate(Template)).
inspectable_predicate_property(Head, number_of_clauses(Count)) :-
    predicate_property(Head, number_of_clauses(Count)).
inspectable_predicate_property(Head, file(File)) :- predicate_property(Head, file(File)).
inspectable_predicate_property(Head, line_count(Line)) :-
    predicate_property(Head, line_count(Line)).

/* -------------------------------------------------------------------------
 * Bounded trace inspection
 * ---------------------------------------------------------------------- */

outcome_trace(Outcome, Options, Trace) :-
    require_list(Options, options),
    outcome_limits(Options, Limits),
    (   is_dict(Outcome), get_dict(trace, Outcome, RawTrace)
    ->  bound_trace_term(RawTrace, Limits, Trace)
    ;   Trace = trace_tree{root:trace_node{kind:unknown,
                                          status:exception,
                                          children:[]},
                          nodes:1,
                          truncated:false}
    ).

plan_success_trace(Result, Limits, Trace) :-
    bounded_transition_trace(Result.transitions, success, Limits, Trace).

bounded_transition_trace(Transitions, Status, Limits, Trace) :-
    ChildLimit is max(0, Limits.trace_max_nodes-1),
    take_prefix(Transitions,
                ChildLimit,
                Selected,
                NodeTruncated),
    maplist(transition_node, Selected, Children),
    length(Children, ChildCount),
    Nodes is ChildCount+1,
    Raw = trace_tree{root:trace_node{kind:plan,
                                    status:Status,
                                    children:Children},
                     nodes:Nodes,
                     truncated:NodeTruncated},
    bound_trace_term(Raw, Limits, Trace).

transition_node(Transition,
                trace_node{kind:transition,
                           sequence:Sequence,
                           operation:Operation,
                           bind:Bind,
                           status:Status,
                           children:[]}) :-
    dict_field(Transition, sequence, 0, Sequence),
    dict_field(Transition, operation, unknown, Operation),
    dict_field(Transition, bind, none, Bind),
    dict_field(Transition, status, unknown, Status).

goal_trace(Goal, Status, ElapsedMs, Limits, Trace) :-
    goal_shape(Goal, Shape),
    Raw = trace_tree{root:trace_node{kind:goal,
                                    goal:Shape,
                                    status:Status,
                                    elapsed_ms:ElapsedMs,
                                    children:[]},
                     nodes:1,
                     truncated:false},
    bound_trace_term(Raw, Limits, Trace).

bound_trace_term(Raw, Limits, Trace) :-
    term_bytes(Raw, Bytes),
    (   Bytes =< Limits.trace_max_bytes
    ->  Trace = Raw
    ;   trace_summary(Raw, Bytes, Limits.trace_max_bytes, Trace)
    ).

trace_summary(Raw, OriginalBytes, Limit,
              trace_tree{root:trace_node{kind:summary,
                                         status:Status,
                                         children:[]},
                         nodes:1,
                         truncated:true,
                         original_bytes:OriginalBytes,
                         byte_limit:Limit}) :-
    trace_status(Raw, Status).

trace_status(Trace, Status) :-
    (   is_dict(Trace),
        get_dict(root, Trace, Root),
        is_dict(Root),
        get_dict(status, Root, Found)
    ->  Status = Found
    ;   Status = unknown
    ).

/* -------------------------------------------------------------------------
 * Scoped bounded plan repair
 * ---------------------------------------------------------------------- */

plan_repair(Plan, Capabilities, Options, Inputs, RepairHandler, Outcome) :-
    catch(plan_repair_(Plan,
                       Capabilities,
                       Options,
                       Inputs,
                       RepairHandler,
                       Outcome),
          Exception,
          unexpected_outcome_exception(repair, Exception, Outcome)).

plan_repair_(Plan, Capabilities, Options, Inputs, RepairHandler, Outcome) :-
    require_list(Options, options),
    callable(RepairHandler),
    outcome_limits(Options, Limits),
    effective_plan_budget(Options, OriginalBudget),
    get_time(Start),
    repair_loop(0,
                Limits.max_repairs,
                Start,
                OriginalBudget,
                Plan,
                Capabilities,
                Options,
                Inputs,
                RepairHandler,
                [],
                Outcome).

repair_loop(Attempt,
            MaxRepairs,
            Start,
            OriginalBudget,
            Plan,
            Capabilities,
            Options,
            Inputs,
            RepairHandler,
            History0,
            Outcome) :-
    remaining_wall_time(Start, OriginalBudget.time_limit, RemainingTime),
    (   RemainingTime =< 0
    ->  repair_timeout_outcome(History0, Outcome)
    ;   options_with_time_limit(Options, RemainingTime, AttemptOptions),
        plan_outcome(Plan,
                     Capabilities,
                     AttemptOptions,
                     Inputs,
                     Current),
        repair_after_outcome(Current,
                             Attempt,
                             MaxRepairs,
                             Start,
                             OriginalBudget,
                             Plan,
                             Capabilities,
                             Options,
                             Inputs,
                             RepairHandler,
                             History0,
                             Outcome)
    ).

repair_after_outcome(Current,
                     Attempt,
                     _,
                     _,
                     _,
                     _,
                     _,
                     _,
                     _,
                     _,
                     History,
                     Outcome) :-
    Current.status == success,
    !,
    attach_repair_metadata(Current, Attempt, History, Outcome).
repair_after_outcome(Current,
                     Attempt,
                     MaxRepairs,
                     Start,
                     OriginalBudget,
                     Plan,
                     Capabilities,
                     Options,
                     Inputs,
                     RepairHandler,
                     History0,
                     Outcome) :-
    (   Attempt >= MaxRepairs
    ->  attach_repair_metadata(Current, Attempt, History0, Outcome)
    ;   repairable_status(Current.status)
    ->  NextAttempt is Attempt+1,
        repair_observation(Current,
                           NextAttempt,
                           Observation),
        repair_handler_call(RepairHandler,
                            Observation,
                            NextAttempt,
                            Plan,
                            Options,
                            Start,
                            OriginalBudget,
                            RepairResult),
        continue_after_repair(RepairResult,
                              Current,
                              NextAttempt,
                              MaxRepairs,
                              Start,
                              OriginalBudget,
                              Capabilities,
                              Options,
                              Inputs,
                              RepairHandler,
                              History0,
                              Outcome)
    ;   attach_repair_metadata(Current, Attempt, History0, Outcome)
    ).

repairable_status(validation_failure).
repairable_status(capability_denied).
repairable_status(logical_failure).
repairable_status(exception).
repairable_status(resource_exhausted).

repair_handler_call(Handler,
                    Observation,
                    Attempt,
                    Plan,
                    Options,
                    Start,
                    OriginalBudget,
                    Outcome) :-
    outcome_limits(Options, Limits),
    remaining_wall_time(Start,
                        OriginalBudget.time_limit,
                        RemainingTime),
    CallbackLimit is min(Limits.repair_time_limit, RemainingTime),
    (   CallbackLimit =< 0
    ->  Outcome = error(repair_error{kind:timeout,
                                     message:"repair loop wall-time budget exhausted"})
    ;   catch(call_with_time_limit(
                  CallbackLimit,
                  ( call(Handler,
                         Observation,
                         Attempt,
                         Plan,
                         RepairedPlan)
                  -> Outcome = ok(RepairedPlan)
                  ;  Outcome = error(repair_error{kind:logical_failure,
                                                   message:"repair handler failed"})
                  )),
              Exception,
              repair_handler_exception(Exception, Outcome))
    ).

repair_handler_exception(time_limit_exceeded,
                         error(repair_error{kind:timeout,
                                            message:"repair handler timed out"})) :- !.
repair_handler_exception(time_limit_exceeded(_),
                         error(repair_error{kind:timeout,
                                            message:"repair handler timed out"})) :- !.
repair_handler_exception(Exception,
                         error(repair_error{kind:exception,
                                            exception:Safe,
                                            message:"repair handler raised an exception"})) :-
    safe_exception(Exception, Safe).

continue_after_repair(error(RepairError),
                      Current,
                      Attempt,
                      _, _, _, _, _, _, _, History0,
                      Outcome) :-
    is_dict(RepairError),
    get_dict(kind, RepairError, timeout),
    !,
    Event = repair_event{attempt:Attempt,
                         status:repair_failed,
                         diagnostic:Current.status,
                         error:RepairError},
    reverse([Event|History0], History),
    put_dict(_{status:timeout,
               phase:repair,
               error:RepairError,
               repair:repair_summary{attempts:Attempt,
                                     history:History}},
             Current,
             Outcome).
continue_after_repair(error(RepairError),
                      Current,
                      Attempt,
                      _, _, _, _, _, _, _, History0,
                      Outcome) :-
    !,
    Event = repair_event{attempt:Attempt,
                         status:repair_failed,
                         diagnostic:Current.status,
                         error:RepairError},
    attach_repair_metadata(Current, Attempt, [Event|History0], Outcome).
continue_after_repair(ok(RepairedPlan),
                      Current,
                      Attempt,
                      MaxRepairs,
                      Start,
                      OriginalBudget,
                      Capabilities,
                      Options,
                      Inputs,
                      RepairHandler,
                      History0,
                      Outcome) :-
    Event = repair_event{attempt:Attempt,
                         status:repair_proposed,
                         diagnostic:Current.status,
                         error:none},
    next_attempt_options(Current,
                         Start,
                         OriginalBudget,
                         Options,
                         NextOptions),
    repair_loop(Attempt,
                MaxRepairs,
                Start,
                OriginalBudget,
                RepairedPlan,
                Capabilities,
                NextOptions,
                Inputs,
                RepairHandler,
                [Event|History0],
                Outcome).

repair_observation(Current, Attempt,
                   repair_observation{attempt:Attempt,
                                      status:Current.status,
                                      phase:Current.phase,
                                      error:Current.error,
                                      trace:Current.trace,
                                      budget_remaining:Current.budget_remaining}).

attach_repair_metadata(Current, Attempts, History0, Outcome) :-
    reverse(History0, History),
    put_dict(repair,
             Current,
             repair_summary{attempts:Attempts,
                            history:History},
             Outcome).

repair_timeout_outcome(History0, Outcome) :-
    reverse(History0, History),
    Outcome = execution_outcome{
                  status:timeout,
                  kind:repair,
                  phase:repair,
                  value:none,
                  bindings:_{},
                  residual_constraints:[],
                  error:repair_error{kind:timeout,
                                     message:"repair loop exhausted original wall-time budget"},
                  trace:trace_tree{root:trace_node{kind:repair,
                                                  status:timeout,
                                                  children:[]},
                                   nodes:1,
                                   truncated:false},
                  budget_remaining:unknown,
                  checkpoints:[],
                  repair:repair_summary{attempts:0,
                                        history:History}
              }.

next_attempt_options(Current,
                     Start,
                     OriginalBudget,
                     Options,
                     NextOptions) :-
    remaining_wall_time(Start, OriginalBudget.time_limit, RemainingTime),
    next_budget(Current.budget_remaining,
                OriginalBudget,
                RemainingTime,
                NextBudget),
    replace_option(budget, budget(NextBudget), Options, NextOptions).

next_budget(Remaining, Original, RemainingTime, Budget) :-
    is_dict(Remaining),
    !,
    Budget = _{max_steps:Remaining.steps,
               max_depth:Original.max_depth,
               max_parallel:Original.max_parallel,
               max_model_calls:Remaining.model_calls,
               max_tool_calls:Remaining.tool_calls,
               max_context_ops:Remaining.context_ops,
               max_output_bytes:Remaining.output_bytes,
               time_limit:RemainingTime}.
next_budget(_, Original, RemainingTime, Budget) :-
    Budget = _{max_steps:Original.max_steps,
               max_depth:Original.max_depth,
               max_parallel:Original.max_parallel,
               max_model_calls:Original.max_model_calls,
               max_tool_calls:Original.max_tool_calls,
               max_context_ops:Original.max_context_ops,
               max_output_bytes:Original.max_output_bytes,
               time_limit:RemainingTime}.

/* -------------------------------------------------------------------------
 * Capability inspection
 * ---------------------------------------------------------------------- */

plan_required_capabilities(plan(Steps), Capabilities) :-
    findall(Capability,
            required_capability_in_steps(Steps, Capability),
            Raw),
    sort(Raw, Capabilities).

required_capability_in_steps(Steps, Capability) :-
    member(Step, Steps),
    required_capability_in_step(Step, Capability).

required_capability_in_step(context(_, Action, _), Capability) :-
    context_action_capability(Action, Capability).
required_capability_in_step(model(Provider, _, _, _), model(Provider)).
required_capability_in_step(tool(Name, _, _), tool(Name)).
required_capability_in_step(rlm(_, _), rlm).
required_capability_in_step(rlm(Plan, _), Capability) :-
    plan_required_capabilities(Plan, Nested),
    member(Capability, Nested).
required_capability_in_step(parallel(_, _), parallel).
required_capability_in_step(parallel(Plans, _), Capability) :-
    member(Plan, Plans),
    plan_required_capabilities(Plan, Nested),
    member(Capability, Nested).
required_capability_in_step(retry(_, _, _), retry).
required_capability_in_step(retry(_, Plan, _), Capability) :-
    plan_required_capabilities(Plan, Nested),
    member(Capability, Nested).
required_capability_in_step(checkpoint(_), checkpoint).

context_action_capability(peek(_), context(peek)).
context_action_capability(slice(_, _), context(slice)).
context_action_capability(search(_), context(search)).
context_action_capability(partition(_), context(partition)).
context_action_capability(map(_), context(map)).
context_action_capability(reduce(_), context(reduce)).

/* -------------------------------------------------------------------------
 * Options, limits, and helpers
 * ---------------------------------------------------------------------- */

outcome_limits(Options, Limits) :-
    default_outcome_limits(Default),
    option_value(outcome_limits, Options, _{}, Updates),
    (   is_dict(Updates)
    ->  put_dict(Updates, Default, Limits0)
    ;   throw(outcome_fault(invalid_outcome_limits(Updates)))
    ),
    validate_outcome_limits(Limits0),
    Limits = Limits0.

validate_outcome_limits(Limits) :-
    positive_integer(Limits.trace_max_nodes, trace_max_nodes),
    positive_integer(Limits.trace_max_bytes, trace_max_bytes),
    positive_number(Limits.goal_time_limit, goal_time_limit),
    positive_integer(Limits.goal_depth_limit, goal_depth_limit),
    nonnegative_integer(Limits.max_repairs, max_repairs),
    positive_number(Limits.repair_time_limit, repair_time_limit).

effective_plan_budget(Options, Budget) :-
    default_plan_budget(Default),
    option_value(budget, Options, _{}, Updates),
    (   is_dict(Updates)
    ->  put_dict(Updates, Default, Budget)
    ;   throw(outcome_fault(invalid_plan_budget(Updates)))
    ).

options_with_time_limit(Options, TimeLimit, Updated) :-
    effective_plan_budget(Options, Budget0),
    put_dict(time_limit, Budget0, TimeLimit, Budget),
    replace_option(budget, budget(Budget), Options, Updated).

replace_option(Name, Replacement, Options, Updated) :-
    exclude(option_name(Name), Options, Rest),
    Updated = [Replacement|Rest].

option_name(Name, Option) :-
    compound(Option),
    functor(Option, Name, 1).

option_value(Name, Options, Default, Value) :-
    (   member(Option, Options),
        compound(Option),
        Option =.. [Name, Found]
    ->  Value = Found
    ;   Value = Default
    ).

remaining_wall_time(Start, Limit, Remaining) :-
    get_time(Now),
    Elapsed is Now-Start,
    Remaining is max(0.0, Limit-Elapsed).

error_transitions(Error, Transitions) :-
    (   is_dict(Error), get_dict(transitions, Error, Found), is_list(Found)
    ->  Transitions = Found
    ;   Transitions = []
    ).

error_budget_remaining(Error, Remaining) :-
    (   is_dict(Error), get_dict(budget_remaining, Error, Found)
    ->  Remaining = Found
    ;   Remaining = unknown
    ).

dict_field(Dict, Key, Default, Value) :-
    (   is_dict(Dict), get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

take_prefix(List, Max, Prefix, Truncated) :-
    take_prefix_(List, Max, Prefix, Rest),
    (Rest == [] -> Truncated = false ; Truncated = true).

take_prefix_(Rest, 0, [], Rest) :- !.
take_prefix_([], _, [], []) :- !.
take_prefix_([Item|Items], Max, [Item|Prefix], Rest) :-
    Next is Max-1,
    take_prefix_(Items, Next, Prefix, Rest).

goal_shape(Goal0, Shape) :-
    strip_module(Goal0, Module, Goal),
    (   callable(Goal)
    ->  functor(Goal, Name, Arity),
        Shape = Module:Name/Arity
    ;   Shape = noncallable
    ).

term_bytes(Term, Bytes) :-
    term_string(Term, Text, [quoted(true), numbervars(true)]),
    string_bytes(Text, Octets, utf8),
    length(Octets, Bytes).

positive_integer(Value, _) :- integer(Value), Value > 0, !.
positive_integer(Value, Field) :- throw(outcome_fault(invalid_positive_integer(Field, Value))).

nonnegative_integer(Value, _) :- integer(Value), Value >= 0, !.
nonnegative_integer(Value, Field) :- throw(outcome_fault(invalid_nonnegative_integer(Field, Value))).

positive_number(Value, _) :- number(Value), Value > 0, !.
positive_number(Value, Field) :- throw(outcome_fault(invalid_positive_number(Field, Value))).

require_list(Value, _) :- is_list(Value), !.
require_list(Value, Field) :- throw(outcome_fault(invalid_list(Field, Value))).

safe_exception(Exception, Safe) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).

unexpected_outcome_exception(Kind, outcome_fault(Fault), Outcome) :-
    !,
    Outcome = execution_outcome{
                  status:validation_failure,
                  kind:Kind,
                  phase:diagnostic,
                  value:none,
                  bindings:_{},
                  residual_constraints:[],
                  error:diagnostic_error{kind:invalid_operation,
                                         detail:Fault,
                                         message:"structured outcome operation is invalid"},
                  trace:trace_tree{root:trace_node{kind:Kind,
                                                  status:validation_failure,
                                                  children:[]},
                                   nodes:1,
                                   truncated:false},
                  budget_remaining:unknown,
                  checkpoints:[]
              }.
unexpected_outcome_exception(Kind, Exception, Outcome) :-
    safe_exception(Exception, Safe),
    Outcome = execution_outcome{
                  status:exception,
                  kind:Kind,
                  phase:diagnostic,
                  value:none,
                  bindings:_{},
                  residual_constraints:[],
                  error:diagnostic_error{kind:exception,
                                         exception:Safe,
                                         message:"structured outcome operation raised an exception"},
                  trace:trace_tree{root:trace_node{kind:Kind,
                                                  status:exception,
                                                  children:[]},
                                   nodes:1,
                                   truncated:false},
                  budget_remaining:unknown,
                  checkpoints:[]
              }.
