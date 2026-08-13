:- module(rlm_recursion_policy,
          [ rlm_recursion_policy_ready/0,
            default_recursion_policy/1,
            recursion_route/3,
            recursion_candidates/3,
            recursion_guard/5,
            recursion_fingerprint/2
          ]).

/** <module> Adaptive recursion and context-program routing policy

The policy compares bounded routing candidates using explicit utility/cost
scores.  Recursion is one route, not the default control flow.  Production
configuration permits one recursive level by default; deeper recursion requires
both an explicit option and capability.
*/

:- use_module(library(option)).

rlm_recursion_policy_ready.

default_recursion_policy(
    recursion_policy{
        max_candidates:5,
        max_recursion_depth:1,
        allow_deep_recursion:false,
        deep_recursion_capability:false,
        min_progress:0.05,
        cost_weight:0.55,
        native_context_chars:120000,
        cheap_submodel_available:false,
        delegated_subagent_available:false,
        deterministic_context_available:true,
        artifact_context_available:false,
        candidate_generator:none,
        candidate_selector:none
    }).

recursion_route(Signals0, Options, Outcome) :-
    policy_outcome(route,
                   recursion_route_(Signals0, Options),
                   Outcome).

recursion_route_(Signals0, Options, Decision) :-
    normalize_options(Options, Policy),
    normalize_signals(Signals0, Policy, Signals),
    build_candidates(Signals, Policy, Candidates0),
    apply_candidate_generator(Policy,
                              Signals,
                              Candidates0,
                              Candidates1),
    normalize_candidates(Candidates1, Candidates2),
    bound_candidates(Candidates2, Policy.max_candidates, Candidates),
    Candidates \== [],
    select_candidate(Policy, Signals, Candidates, Selected),
    decision_reason(Selected, Signals, Reason),
    budget_remaining(Signals, BudgetRemaining),
    Decision = recursion_decision{
                   policy:Selected.route,
                   reason:Reason,
                   signals:Signals,
                   budget_remaining:BudgetRemaining,
                   expected_utility:Selected.expected_utility,
                   estimated_cost:Selected.estimated_cost,
                   expected_value:Selected.expected_value,
                   candidates:Candidates,
                   trace:recursion_trace{
                             type:recursion_policy_selected,
                             selected_policy:Selected.route,
                             reason:Reason,
                             signals:Signals,
                             budget_remaining:BudgetRemaining,
                             expected_utility:Selected.expected_utility,
                             estimated_cost:Selected.estimated_cost,
                             expected_value:Selected.expected_value
                         }
               }.

recursion_candidates(Signals0, Options, Outcome) :-
    policy_outcome(candidates,
                   recursion_candidates_(Signals0, Options),
                   Outcome).

recursion_candidates_(Signals0, Options, Candidates) :-
    normalize_options(Options, Policy),
    normalize_signals(Signals0, Policy, Signals),
    build_candidates(Signals, Policy, Candidates0),
    apply_candidate_generator(Policy,
                              Signals,
                              Candidates0,
                              Candidates1),
    normalize_candidates(Candidates1, Candidates2),
    bound_candidates(Candidates2, Policy.max_candidates, Candidates).

recursion_guard(Fingerprint,
                PreviousFingerprints,
                Progress0,
                Options,
                Outcome) :-
    policy_status(guard,
                  recursion_guard_(Fingerprint,
                                   PreviousFingerprints,
                                   Progress0,
                                   Options),
                  Outcome).

recursion_guard_(Fingerprint, PreviousFingerprints, Progress0, Options) :-
    ground(Fingerprint),
    require_list(PreviousFingerprints, previous_fingerprints),
    normalize_options(Options, Policy),
    score(Progress0, progress, Progress),
    (   memberchk(Fingerprint, PreviousFingerprints)
    ->  throw(recursion_policy_fault(duplicate_subcall(Fingerprint)))
    ;   Progress < Policy.min_progress
    ->  throw(recursion_policy_fault(no_progress(Progress,
                                                  Policy.min_progress)))
    ;   true
    ).

recursion_fingerprint(Term, Fingerprint) :-
    (   ground(Term)
    ->  term_hash(Term, Hash),
        format(atom(Fingerprint), 'rlm-~16r', [Hash])
    ;   throw(error(instantiation_error,
                    context(rlm_recursion_policy:recursion_fingerprint/2,
                            'fingerprinted recursion request must be ground')))
    ).

/* ---------------------------------------------------------------------- */

normalize_options(Options, Policy) :-
    (   is_list(Options)
    ->  true
    ;   throw(recursion_policy_fault(invalid_options(Options)))
    ),
    default_recursion_policy(Default),
    option(max_candidates(MaxCandidates), Options, Default.max_candidates),
    option(max_recursion_depth(MaxDepth),
           Options,
           Default.max_recursion_depth),
    option(allow_deep_recursion(AllowDeep),
           Options,
           Default.allow_deep_recursion),
    option(deep_recursion_capability(DeepCapability),
           Options,
           Default.deep_recursion_capability),
    option(min_progress(MinProgress), Options, Default.min_progress),
    option(cost_weight(CostWeight), Options, Default.cost_weight),
    option(native_context_chars(NativeChars),
           Options,
           Default.native_context_chars),
    option(cheap_submodel_available(CheapAvailable),
           Options,
           Default.cheap_submodel_available),
    option(delegated_subagent_available(SubagentAvailable),
           Options,
           Default.delegated_subagent_available),
    option(deterministic_context_available(DeterministicAvailable),
           Options,
           Default.deterministic_context_available),
    option(artifact_context_available(ArtifactAvailable),
           Options,
           Default.artifact_context_available),
    option(candidate_generator(Generator),
           Options,
           Default.candidate_generator),
    option(candidate_selector(Selector),
           Options,
           Default.candidate_selector),
    positive_integer(MaxCandidates, max_candidates),
    nonnegative_integer(MaxDepth, max_recursion_depth),
    boolean(AllowDeep, allow_deep_recursion),
    boolean(DeepCapability, deep_recursion_capability),
    unit_score(MinProgress, min_progress),
    nonnegative_score(CostWeight, cost_weight),
    positive_integer(NativeChars, native_context_chars),
    boolean(CheapAvailable, cheap_submodel_available),
    boolean(SubagentAvailable, delegated_subagent_available),
    boolean(DeterministicAvailable, deterministic_context_available),
    boolean(ArtifactAvailable, artifact_context_available),
    callable_or_none(Generator, candidate_generator),
    callable_or_none(Selector, candidate_selector),
    effective_max_depth(MaxDepth,
                        AllowDeep,
                        DeepCapability,
                        EffectiveMaxDepth),
    Policy = recursion_policy{
                 max_candidates:MaxCandidates,
                 max_recursion_depth:EffectiveMaxDepth,
                 configured_max_recursion_depth:MaxDepth,
                 allow_deep_recursion:AllowDeep,
                 deep_recursion_capability:DeepCapability,
                 min_progress:MinProgress,
                 cost_weight:CostWeight,
                 native_context_chars:NativeChars,
                 cheap_submodel_available:CheapAvailable,
                 delegated_subagent_available:SubagentAvailable,
                 deterministic_context_available:DeterministicAvailable,
                 artifact_context_available:ArtifactAvailable,
                 candidate_generator:Generator,
                 candidate_selector:Selector
             }.

effective_max_depth(MaxDepth, true, true, MaxDepth) :- !.
effective_max_depth(MaxDepth, _, _, Effective) :-
    Effective is min(MaxDepth, 1).

normalize_signals(Signals0, Policy, Signals) :-
    (   is_dict(Signals0)
    ->  true
    ;   throw(recursion_policy_fault(invalid_signals(Signals0)))
    ),
    dict_score(Signals0, task_complexity, 0.5, Complexity),
    dict_score(Signals0, uncertainty, 0.5, Uncertainty),
    dict_score(Signals0, branch_diversity, 0.0, BranchDiversity),
    dict_score(Signals0, progress, 1.0, Progress),
    dict_nonnegative_integer(Signals0, context_chars, 0, ContextChars),
    dict_nonnegative_integer(Signals0, current_depth, 0, CurrentDepth),
    dict_nonnegative_integer(Signals0, remaining_calls, 0, RemainingCalls),
    dict_nonnegative_integer(Signals0, remaining_tokens, 0, RemainingTokens),
    dict_boolean(Signals0, duplicate, false, Duplicate),
    dict_boolean(Signals0,
                 deterministic_context_available,
                 Policy.deterministic_context_available,
                 DeterministicAvailable),
    dict_boolean(Signals0,
                 cheap_submodel_available,
                 Policy.cheap_submodel_available,
                 CheapAvailable),
    dict_boolean(Signals0,
                 delegated_subagent_available,
                 Policy.delegated_subagent_available,
                 SubagentAvailable),
    dict_boolean(Signals0,
                 artifact_context_available,
                 Policy.artifact_context_available,
                 ArtifactAvailable),
    ContextPressure is min(1.0,
                           ContextChars / Policy.native_context_chars),
    RemainingDepth is max(0,
                           Policy.max_recursion_depth-CurrentDepth),
    Signals = recursion_signals{
                  task_complexity:Complexity,
                  context_chars:ContextChars,
                  context_pressure:ContextPressure,
                  uncertainty:Uncertainty,
                  branch_diversity:BranchDiversity,
                  progress:Progress,
                  duplicate:Duplicate,
                  current_depth:CurrentDepth,
                  remaining_depth:RemainingDepth,
                  remaining_calls:RemainingCalls,
                  remaining_tokens:RemainingTokens,
                  deterministic_context_available:DeterministicAvailable,
                  cheap_submodel_available:CheapAvailable,
                  delegated_subagent_available:SubagentAvailable,
                  artifact_context_available:ArtifactAvailable
              }.

build_candidates(Signals, Policy, Candidates) :-
    direct_candidate(Signals, Policy, Direct),
    findall(Candidate,
            optional_candidate(Signals, Policy, Candidate),
            Optional),
    Candidates = [Direct|Optional].

direct_candidate(Signals, Policy, Candidate) :-
    Utility0 is 0.92
               - 0.58*Signals.task_complexity
               - 0.20*Signals.uncertainty
               - 0.12*Signals.context_pressure,
    clamp01(Utility0, Utility),
    Cost = 0.04,
    expected_value(Utility, Cost, Policy, Value),
    Candidate = recursion_candidate{
                    route:direct_continuation,
                    expected_utility:Utility,
                    estimated_cost:Cost,
                    expected_value:Value,
                    rationale:cheap_when_problem_is_already_tractable
                }.

optional_candidate(Signals, Policy, Candidate) :-
    Signals.deterministic_context_available == true,
    deterministic_candidate(Signals, Policy, Candidate).
optional_candidate(Signals, Policy, Candidate) :-
    Signals.cheap_submodel_available == true,
    cheap_submodel_candidate(Signals, Policy, Candidate).
optional_candidate(Signals, Policy, Candidate) :-
    recursion_available(Signals, Policy),
    recursive_candidate(Signals, Policy, Candidate).
optional_candidate(Signals, Policy, Candidate) :-
    Signals.delegated_subagent_available == true,
    delegated_candidate(Signals, Policy, Candidate).

recursion_available(Signals, Policy) :-
    Signals.remaining_depth > 0,
    Signals.remaining_calls > 0,
    Signals.remaining_tokens > 0,
    Signals.duplicate == false,
    Signals.progress >= Policy.min_progress.

deterministic_candidate(Signals, Policy, Candidate) :-
    Utility0 is 0.48
               + 0.32*Signals.context_pressure
               + 0.18*(1.0-Signals.uncertainty)
               - 0.10*Signals.task_complexity,
    clamp01(Utility0, Utility),
    Cost = 0.08,
    expected_value(Utility, Cost, Policy, Value),
    Candidate = recursion_candidate{
                    route:deterministic_context,
                    expected_utility:Utility,
                    estimated_cost:Cost,
                    expected_value:Value,
                    rationale:prefer_symbolic_context_work_when_sufficient
                }.

cheap_submodel_candidate(Signals, Policy, Candidate) :-
    Utility0 is 0.30
               + 0.44*Signals.task_complexity
               + 0.16*Signals.uncertainty
               + 0.08*Signals.context_pressure,
    clamp01(Utility0, Utility),
    Cost = 0.24,
    expected_value(Utility, Cost, Policy, Value),
    Candidate = recursion_candidate{
                    route:cheap_submodel,
                    expected_utility:Utility,
                    estimated_cost:Cost,
                    expected_value:Value,
                    rationale:delegate_bounded_semantic_subproblem_cheaply
                }.

recursive_candidate(Signals, Policy, Candidate) :-
    DepthPenalty is 0.10*Signals.current_depth,
    Utility0 is 0.20
               + 0.48*Signals.task_complexity
               + 0.40*Signals.context_pressure
               + 0.18*Signals.uncertainty
               + 0.08*Signals.branch_diversity
               - DepthPenalty,
    clamp01(Utility0, Utility),
    Cost0 is 0.38 + 0.12*Signals.current_depth,
    clamp01(Cost0, Cost),
    expected_value(Utility, Cost, Policy, Value),
    Candidate = recursion_candidate{
                    route:recursive_rlm,
                    expected_utility:Utility,
                    estimated_cost:Cost,
                    expected_value:Value,
                    rationale:use_isolated_recursive_context_for_complex_long_context_work
                }.

delegated_candidate(Signals, Policy, Candidate) :-
    Utility0 is 0.18
               + 0.42*Signals.task_complexity
               + 0.34*Signals.branch_diversity
               + 0.14*Signals.uncertainty,
    clamp01(Utility0, Utility),
    Cost = 0.52,
    expected_value(Utility, Cost, Policy, Value),
    Candidate = recursion_candidate{
                    route:delegated_subagent,
                    expected_utility:Utility,
                    estimated_cost:Cost,
                    expected_value:Value,
                    rationale:use_agent_harness_when_branching_or_tools_dominate
                }.

expected_value(Utility, Cost, Policy, Value) :-
    Raw is Utility-Policy.cost_weight*Cost,
    round_score(Raw, Value).

apply_candidate_generator(Policy, Signals, Base, Candidates) :-
    Generator = Policy.candidate_generator,
    (   Generator == none
    ->  Candidates = Base
    ;   catch(call(Generator, Signals, Base, Generated0),
              Exception,
              throw(recursion_policy_fault(candidate_generator_exception(Exception)))),
        require_list(Generated0, generated_candidates),
        append(Base, Generated0, Candidates)
    ).

normalize_candidates(Candidates0, Candidates) :-
    maplist(normalize_candidate, Candidates0, Candidates1),
    dedupe_routes(Candidates1, [], Candidates).

normalize_candidate(Candidate0, Candidate) :-
    (   is_dict(Candidate0)
    ->  true
    ;   throw(recursion_policy_fault(invalid_candidate(Candidate0)))
    ),
    require_route(Candidate0.route),
    score(Candidate0.expected_utility, expected_utility, Utility),
    nonnegative_score(Candidate0.estimated_cost, estimated_cost, Cost),
    (   get_dict(expected_value, Candidate0, Value0)
    ->  number(Value0),
        Value = Value0
    ;   Value is Utility-Cost
    ),
    (   get_dict(rationale, Candidate0, Rationale)
    ->  true
    ;   Rationale = generated_candidate
    ),
    Candidate = recursion_candidate{
                    route:Candidate0.route,
                    expected_utility:Utility,
                    estimated_cost:Cost,
                    expected_value:Value,
                    rationale:Rationale
                }.

require_route(Route) :-
    memberchk(Route,
              [ direct_continuation,
                cheap_submodel,
                recursive_rlm,
                delegated_subagent,
                deterministic_context
              ]),
    !.
require_route(Route) :-
    throw(recursion_policy_fault(invalid_route(Route))).

dedupe_routes([], _, []).
dedupe_routes([Candidate|Rest], Seen, Candidates) :-
    Route = Candidate.route,
    (   memberchk(Route, Seen)
    ->  dedupe_routes(Rest, Seen, Candidates)
    ;   Candidates = [Candidate|Tail],
        dedupe_routes(Rest, [Route|Seen], Tail)
    ).

bound_candidates(Candidates0, MaxCandidates, Candidates) :-
    predsort(compare_candidate, Candidates0, Sorted),
    take(MaxCandidates, Sorted, Candidates).

compare_candidate(Order, A, B) :-
    compare_desc(A.expected_value, B.expected_value, ValueOrder),
    (   ValueOrder == (=)
    ->  route_rank(A.route, ARank),
        route_rank(B.route, BRank),
        compare(Order, ARank, BRank)
    ;   Order = ValueOrder
    ).

compare_desc(A, B, (<)) :- A > B, !.
compare_desc(A, B, (>)) :- A < B, !.
compare_desc(_, _, (=)).

route_rank(deterministic_context, 1).
route_rank(direct_continuation, 2).
route_rank(cheap_submodel, 3).
route_rank(recursive_rlm, 4).
route_rank(delegated_subagent, 5).

select_candidate(Policy, Signals, Candidates, Selected) :-
    Selector = Policy.candidate_selector,
    (   Selector == none
    ->  Candidates = [Selected|_]
    ;   catch(call(Selector, Signals, Candidates, Selected0),
              Exception,
              throw(recursion_policy_fault(candidate_selector_exception(Exception)))),
        normalize_candidate(Selected0, Selected),
        memberchk(Selected.route,
                  [direct_continuation,
                   cheap_submodel,
                   recursive_rlm,
                   delegated_subagent,
                   deterministic_context])
    ).

decision_reason(Selected, Signals, Reason) :-
    Route = Selected.route,
    reason_for_route(Route, Signals, Reason).

reason_for_route(direct_continuation, Signals, easy_direct_continuation) :-
    Signals.task_complexity =< 0.35,
    !.
reason_for_route(direct_continuation, Signals, recursion_guarded) :-
    (Signals.duplicate == true ; Signals.remaining_depth =:= 0 ; Signals.remaining_calls =:= 0),
    !.
reason_for_route(direct_continuation, _, direct_route_has_best_expected_value).
reason_for_route(deterministic_context, Signals, context_operation_dominates) :-
    Signals.context_pressure >= 0.45,
    !.
reason_for_route(deterministic_context, _, deterministic_route_has_best_expected_value).
reason_for_route(cheap_submodel, _, cheap_semantic_delegation_has_best_expected_value).
reason_for_route(recursive_rlm, Signals, long_context_recursive_decomposition) :-
    Signals.context_pressure >= 0.65,
    !.
reason_for_route(recursive_rlm, _, recursive_decomposition_has_best_expected_value).
reason_for_route(delegated_subagent, Signals, high_branch_diversity) :-
    Signals.branch_diversity >= 0.55,
    !.
reason_for_route(delegated_subagent, _, subagent_harness_has_best_expected_value).

budget_remaining(Signals,
                 recursion_budget{
                     depth:Signals.remaining_depth,
                     calls:Signals.remaining_calls,
                     tokens:Signals.remaining_tokens
                 }).

/* ---------------------------------------------------------------------- */

policy_outcome(Phase, Goal, Outcome) :-
    catch(( call(Goal, Value), Result = ok(Value) ),
          Exception,
          policy_exception(Phase, Exception, Result)),
    Outcome = Result.

policy_status(Phase, Goal, Outcome) :-
    catch(( call(Goal), Result = ok ),
          Exception,
          policy_exception(Phase, Exception, Result)),
    Outcome = Result.

policy_exception(Phase, recursion_policy_fault(Detail), error(Error)) :-
    !,
    Error = recursion_policy_error{
                phase:Phase,
                kind:policy_error,
                detail:Detail,
                message:"adaptive recursion policy rejected the request"
            }.
policy_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = recursion_policy_error{
                phase:Phase,
                kind:exception,
                exception:Safe,
                message:"adaptive recursion policy raised an exception"
            }.

/* ---------------------------------------------------------------------- */

score(Value0, Name, Value) :-
    number(Value0),
    Value0 >= 0.0,
    Value0 =< 1.0,
    !,
    Value is float(Value0).
score(Value, Name, _) :-
    throw(recursion_policy_fault(invalid_score(Name, Value))).

unit_score(Value0, Name, Value) :- score(Value0, Name, Value).

nonnegative_score(Value0, _, Value) :-
    number(Value0),
    Value0 >= 0.0,
    !,
    Value is float(Value0).
nonnegative_score(Value, Name, _) :-
    throw(recursion_policy_fault(invalid_nonnegative_score(Name, Value))).

positive_integer(Value, _) :- integer(Value), Value > 0, !.
positive_integer(Value, Name) :-
    throw(recursion_policy_fault(invalid_positive_integer(Name, Value))).

nonnegative_integer(Value, _) :- integer(Value), Value >= 0, !.
nonnegative_integer(Value, Name) :-
    throw(recursion_policy_fault(invalid_nonnegative_integer(Name, Value))).

boolean(Value, _) :- memberchk(Value, [true,false]), !.
boolean(Value, Name) :-
    throw(recursion_policy_fault(invalid_boolean(Name, Value))).

callable_or_none(none, _) :- !.
callable_or_none(Value, _) :- callable(Value), !.
callable_or_none(Value, Name) :-
    throw(recursion_policy_fault(invalid_callable(Name, Value))).

require_list(Value, _) :- is_list(Value), !.
require_list(Value, Name) :-
    throw(recursion_policy_fault(expected_list(Name, Value))).

dict_score(Dict, Key, Default, Value) :-
    ( get_dict(Key, Dict, Raw) -> true ; Raw = Default ),
    score(Raw, Key, Value).

dict_nonnegative_integer(Dict, Key, Default, Value) :-
    ( get_dict(Key, Dict, Raw) -> true ; Raw = Default ),
    nonnegative_integer(Raw, Key),
    Value = Raw.

dict_boolean(Dict, Key, Default, Value) :-
    ( get_dict(Key, Dict, Raw) -> true ; Raw = Default ),
    boolean(Raw, Key),
    Value = Raw.

clamp01(Value, Clamped) :-
    Bounded is max(0.0, min(1.0, Value)),
    round_score(Bounded, Clamped).

round_score(Value, Rounded) :-
    Rounded is round(Value*10000)/10000.

take(0, _, []) :- !.
take(_, [], []) :- !.
take(N, [X|Xs], [X|Ys]) :-
    N > 0,
    N1 is N-1,
    take(N1, Xs, Ys).
