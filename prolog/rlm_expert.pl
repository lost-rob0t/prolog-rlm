:- module(rlm_expert,
          [ rlm_expert_ready/0,
            default_expert_registry_options/1,
            expert_registry_create/2,
            expert_registry_destroy/1,
            expert_registry_generation/2,
            expert_register/3,
            expert_unregister/3,
            expert_catalog/2,
            expert_lookup/3,
            expert_applicable/4,
            expert_select/4,
            expert_invoke/5,
            expert_call/4,
            expert_explain/2,
            expert_invocations/2
          ]).

/** <module> Canonical provider-free expert registry and invocation runtime

This module implements the generic runtime contract from #377. Expert
registration is a trusted host action. Goal terms and context are inert data;
they are never called as Prolog goals. Only host-registered handlers and
applicability hooks are callable.

Pure expert invocation performs zero provider calls. Nested expert calls share
one bounded run state, preserve or narrow the parent capability ceiling, detect
cycles, and never create a second scheduler. The D6-11 plan-native operations
(sync_remote/run/index/delete) are deliberately rejected from expert contracts.
*/

:- use_module(library(gensym)).
:- use_module(library(lists), [member/2, memberchk/2]).
:- use_module(library(pairs), [pairs_keys/2]).
:- use_module(rlm_tool,
              [ capabilities_normalize/2,
                capabilities_narrow/3
              ]).

:- dynamic expert_registry_state/3.
:- dynamic expert_registry_entry/3.
:- dynamic expert_registry_sequence/2.
:- dynamic expert_invocation_event/3.
:- dynamic expert_run_state/5.

rlm_expert_ready.

default_expert_registry_options(
    expert_registry_options{max_depth:8,
                            max_invocations:128}).

/* Registry lifecycle -------------------------------------------------- */

expert_registry_create(Options0, expert_registry(Id)) :-
    normalize_registry_options(Options0, Options),
    with_mutex(rlm_expert_registry,
               ( gensym(expert_registry_, Id),
                 assertz(expert_registry_state(Id, 0, Options)),
                 assertz(expert_registry_sequence(Id, 0))
               )).

expert_registry_destroy(expert_registry(Id)) :-
    with_mutex(rlm_expert_registry,
               ( retractall(expert_registry_entry(Id, _, _)),
                 retractall(expert_invocation_event(Id, _, _)),
                 retractall(expert_registry_sequence(Id, _)),
                 retractall(expert_registry_state(Id, _, _)),
                 retractall(expert_run_state(_, Id, _, _, _))
               )).

expert_registry_generation(expert_registry(Id), Generation) :-
    expert_registry_state(Id, Generation, _).

normalize_registry_options([], Options) :-
    !,
    default_expert_registry_options(Options).
normalize_registry_options(Options0, Options) :-
    is_dict(Options0),
    !,
    default_expert_registry_options(Default),
    reject_unknown_keys(registry_options,
                        Options0,
                        [max_depth, max_invocations]),
    dict_get_default(Options0, max_depth, Default.max_depth, MaxDepth),
    dict_get_default(Options0,
                     max_invocations,
                     Default.max_invocations,
                     MaxInvocations),
    require_positive_integer(max_depth, MaxDepth),
    require_positive_integer(max_invocations, MaxInvocations),
    Options = expert_registry_options{max_depth:MaxDepth,
                                      max_invocations:MaxInvocations}.
normalize_registry_options(Options0, Options) :-
    is_list(Options0),
    !,
    default_expert_registry_options(Default),
    list_option(max_depth, Options0, Default.max_depth, MaxDepth),
    list_option(max_invocations,
                Options0,
                Default.max_invocations,
                MaxInvocations),
    require_positive_integer(max_depth, MaxDepth),
    require_positive_integer(max_invocations, MaxInvocations),
    Options = expert_registry_options{max_depth:MaxDepth,
                                      max_invocations:MaxInvocations}.
normalize_registry_options(Options, _) :-
    throw(expert_fault(invalid_registry_options(Options))).

list_option(Name, Options, Default, Value) :-
    functor(Term, Name, 1),
    (   memberchk(Term, Options)
    ->  arg(1, Term, Value)
    ;   Value = Default
    ).

/* Registration -------------------------------------------------------- */

expert_register(expert_registry(Id), Contract0, Outcome) :-
    catch(expert_register_(Id, Contract0, Outcome),
          Exception,
          expert_exception(register, Exception, Outcome)).

expert_register_(Id, Contract0, ok(Descriptor)) :-
    require_registry_id(Id),
    normalize_contract(Contract0, Contract),
    ExpertId = Contract.id,
    (   expert_registry_entry(Id, ExpertId, _)
    ->  throw(expert_fault(already_registered(ExpertId)))
    ;   true
    ),
    with_mutex(rlm_expert_registry,
               ( assertz(expert_registry_entry(Id, ExpertId, Contract)),
                 bump_registry_generation(Id, Generation)
               )),
    public_descriptor(Contract, Generation, Descriptor).

expert_unregister(expert_registry(Id), ExpertId, Outcome) :-
    catch(expert_unregister_(Id, ExpertId, Outcome),
          Exception,
          expert_exception(unregister, Exception, Outcome)).

expert_unregister_(Id, ExpertId, ok(removed(ExpertId))) :-
    require_registry_id(Id),
    require_nonempty_atom(expert_id, ExpertId),
    with_mutex(rlm_expert_registry,
               (   retract(expert_registry_entry(Id, ExpertId, _))
               ->  bump_registry_generation(Id, _)
               ;   throw(expert_fault(not_registered(ExpertId)))
               )).

bump_registry_generation(Id, Generation) :-
    retract(expert_registry_state(Id, Current, Options)),
    Generation is Current+1,
    assertz(expert_registry_state(Id, Generation, Options)).

normalize_contract(Contract0, Contract) :-
    require_dict(expert_contract, Contract0),
    Allowed = [id, version, accepts, produces, specialties,
               applicability, priority, requires, observations,
               effects, fallback, child_policy, limits, handler],
    reject_unknown_keys(expert_contract, Contract0, Allowed),
    require_key(expert_contract, Contract0, id, ExpertId),
    require_key(expert_contract, Contract0, version, Version),
    require_key(expert_contract, Contract0, accepts, Accepts0),
    require_key(expert_contract, Contract0, produces, Produces),
    require_key(expert_contract, Contract0, specialties, Specialties),
    require_key(expert_contract, Contract0, requires, Requires0),
    require_key(expert_contract, Contract0, observations, Observations),
    require_key(expert_contract, Contract0, effects, Effects),
    require_key(expert_contract, Contract0, fallback, Fallback),
    require_key(expert_contract, Contract0, child_policy, ChildPolicy),
    require_key(expert_contract, Contract0, limits, Limits0),
    require_key(expert_contract, Contract0, handler, Handler),
    dict_get_default(Contract0, applicability, none, Applicability),
    dict_get_default(Contract0, priority, 0, Priority),
    require_nonempty_atom(expert_id, ExpertId),
    require_version(Version),
    normalize_accepts(Accepts0, Accepts),
    reject_plan_native_accepts(Accepts),
    require_safe_data(produces, Produces),
    require_atom_list(specialties, Specialties),
    normalize_capabilities(Requires0, Requires),
    require_safe_list(observations, Observations),
    require_safe_list(effects, Effects),
    require_fallback(Fallback),
    require_child_policy(ChildPolicy),
    normalize_limits(Limits0, Limits),
    require_integer(priority, Priority),
    require_applicability(Applicability),
    require_callable(handler, Handler),
    Contract = expert_contract{
                   id:ExpertId,
                   version:Version,
                   accepts:Accepts,
                   produces:Produces,
                   specialties:Specialties,
                   applicability:Applicability,
                   priority:Priority,
                   requires:Requires,
                   observations:Observations,
                   effects:Effects,
                   fallback:Fallback,
                   child_policy:ChildPolicy,
                   limits:Limits,
                   handler:Handler
               }.

normalize_accepts(Accepts0, Accepts) :-
    is_list(Accepts0),
    Accepts0 \== [],
    maplist(require_predicate_indicator, Accepts0),
    sort(Accepts0, Accepts),
    !.
normalize_accepts(Accepts, _) :-
    throw(expert_fault(invalid_accepts(Accepts))).

require_predicate_indicator(Name/Arity) :-
    atom(Name),
    Name \== '',
    integer(Arity),
    Arity >= 0,
    !.
require_predicate_indicator(Indicator) :-
    throw(expert_fault(invalid_goal_schema(Indicator))).

native_expert_indicator(sync_remote/1).
native_expert_indicator(run/1).
native_expert_indicator(index/1).
native_expert_indicator(delete/1).

reject_plan_native_accepts(Accepts) :-
    (   member(Indicator, Accepts),
        native_expert_indicator(Indicator)
    ->  throw(expert_fault(plan_native_excluded(Indicator)))
    ;   true
    ).

normalize_capabilities(Caps0, Caps) :-
    (   capabilities_normalize(Caps0, ok(Caps))
    ->  true
    ;   capabilities_normalize(Caps0, error(Error)),
        throw(expert_fault(invalid_capabilities(Error)))
    ).

normalize_limits(Limits0, Limits) :-
    require_dict(expert_limits, Limits0),
    reject_unknown_keys(expert_limits,
                        Limits0,
                        [max_depth, max_invocations]),
    dict_get_default(Limits0, max_depth, 8, MaxDepth),
    dict_get_default(Limits0, max_invocations, 128, MaxInvocations),
    require_positive_integer(max_depth, MaxDepth),
    require_positive_integer(max_invocations, MaxInvocations),
    Limits = expert_limits{max_depth:MaxDepth,
                           max_invocations:MaxInvocations}.

require_fallback(none) :- !.
require_fallback(no_fallback) :- !.
require_fallback(nl_normalization_fallback) :- !.
require_fallback(semantic_generation_fallback) :- !.
require_fallback(review_fallback) :- !.
require_fallback(conversation_render_fallback) :- !.
require_fallback(Value) :-
    throw(expert_fault(invalid_fallback(Value))).

require_child_policy(never) :- !.
require_child_policy(children) :- !.
require_child_policy(any) :- !.
require_child_policy(Value) :-
    throw(expert_fault(invalid_child_policy(Value))).

require_applicability(none) :- !.
require_applicability(Handler) :-
    require_callable(applicability, Handler).

/* Catalog ------------------------------------------------------------- */

expert_catalog(expert_registry(Id), Catalog) :-
    require_registry_id(Id),
    expert_registry_state(Id, Generation, _),
    findall(ExpertId-Descriptor,
            ( expert_registry_entry(Id, ExpertId, Contract),
              public_descriptor(Contract, Generation, Descriptor)
            ),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Catalog).

expert_lookup(expert_registry(Id), ExpertId, Outcome) :-
    catch(expert_lookup_(Id, ExpertId, Outcome),
          Exception,
          expert_exception(lookup, Exception, Outcome)).

expert_lookup_(Id, ExpertId, ok(Descriptor)) :-
    require_registry_id(Id),
    require_nonempty_atom(expert_id, ExpertId),
    (   expert_registry_entry(Id, ExpertId, Contract)
    ->  expert_registry_state(Id, Generation, _),
        public_descriptor(Contract, Generation, Descriptor)
    ;   throw(expert_fault(not_registered(ExpertId)))
    ).

public_descriptor(Contract, Generation, Descriptor) :-
    Descriptor = expert_descriptor{
                     id:Contract.id,
                     version:Contract.version,
                     accepts:Contract.accepts,
                     produces:Contract.produces,
                     specialties:Contract.specialties,
                     priority:Contract.priority,
                     requires:Contract.requires,
                     observations:Contract.observations,
                     effects:Contract.effects,
                     fallback:Contract.fallback,
                     child_policy:Contract.child_policy,
                     limits:Contract.limits,
                     applicability:trusted_host,
                     handler:trusted_host,
                     registry_generation:Generation,
                     usage:expert_usage{model_calls:0, cost:0}
                 }.

/* Applicability and selection ---------------------------------------- */

expert_applicable(expert_registry(Id), Goal, Context0, Candidates) :-
    require_registry_id(Id),
    require_goal_data(Goal),
    normalize_public_context(Context0, Context, Capabilities, _Preferred),
    expert_registry_state(Id, Generation, _),
    findall(Candidate,
            applicable_candidate(Id,
                                 Goal,
                                 Context,
                                 Capabilities,
                                 Generation,
                                 Candidate),
            Candidates0),
    sort_candidates(Candidates0, Candidates).

applicable_candidate(Id,
                     Goal,
                     Context,
                     Capabilities,
                     Generation,
                     Candidate) :-
    expert_registry_entry(Id, ExpertId, Contract),
    goal_matches_contract(Goal, Contract),
    capabilities_satisfy(Capabilities, Contract.requires),
    applicability_result(Contract.applicability,
                         Goal,
                         Context,
                         LocalScore,
                         Reason),
    Score is Contract.priority+LocalScore,
    Candidate = expert_candidate{
                    expert_id:ExpertId,
                    expert_version:Contract.version,
                    score:Score,
                    priority:Contract.priority,
                    reason:Reason,
                    registry_generation:Generation
                }.

sort_candidates(Candidates0, Candidates) :-
    findall(Key-Candidate,
            ( member(Candidate, Candidates0),
              Score is -Candidate.score,
              Key = Score-Candidate.expert_id
            ),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Candidates).

applicability_result(none, _, _, 0, static_goal_match) :- !.
applicability_result(Handler, Goal, Context, Score, Reason) :-
    catch(( call(Handler, Goal, Context, Raw)
          -> normalize_applicability(Raw, Score, Reason)
          ;  fail
          ),
          Exception,
          throw(expert_fault(applicability_error(Exception)))).

normalize_applicability(applicable(Score, Reason), Score, Reason) :-
    number(Score),
    require_safe_data(applicability_reason, Reason),
    !.
normalize_applicability(applicable(Reason), 0, Reason) :-
    require_safe_data(applicability_reason, Reason),
    !.
normalize_applicability(not_applicable(_), _, _) :-
    !,
    fail.
normalize_applicability(Value, _, _) :-
    throw(expert_fault(invalid_applicability_result(Value))).

expert_select(Registry, Goal, Context0, Decision) :-
    expert_applicable(Registry, Goal, Context0, Candidates),
    normalize_public_context(Context0, _Context, _Caps, Preferred),
    expert_registry_generation(Registry, Generation),
    select_candidates(Candidates, Preferred, Generation, Decision).

select_candidates([], _, Generation,
                  expert_selection{status:unsupported,
                                   reason:no_applicable_expert,
                                   candidates:[],
                                   registry_generation:Generation}) :-
    !.
select_candidates(Candidates, Preferred, Generation, Decision) :-
    Candidates = [First|_],
    TopScore = First.score,
    include(has_score(TopScore), Candidates, Top),
    select_top(Top, Preferred, Generation, Candidates, Decision).

has_score(Score, Candidate) :-
    Candidate.score =:= Score.

select_top([Winner], _, Generation, Candidates,
           expert_selection{status:selected,
                            expert_id:Winner.expert_id,
                            expert_version:Winner.expert_version,
                            score:Winner.score,
                            reason:Winner.reason,
                            candidates:Candidates,
                            registry_generation:Generation}) :-
    !.
select_top(Top, Preferred, Generation, Candidates, Decision) :-
    Preferred \== none,
    member(Winner, Top),
    Winner.expert_id == Preferred,
    !,
    Decision = expert_selection{status:selected,
                                expert_id:Winner.expert_id,
                                expert_version:Winner.expert_version,
                                score:Winner.score,
                                reason:preferred_expert,
                                candidates:Candidates,
                                registry_generation:Generation}.
select_top(Top, _, Generation, Candidates,
           expert_selection{status:ambiguous,
                            reason:equal_score,
                            candidates:Candidates,
                            tied:Tied,
                            registry_generation:Generation}) :-
    findall(Id, (member(C, Top), Id=C.expert_id), Tied).

/* Invocation ---------------------------------------------------------- */

expert_call(Registry, Goal, Context, Outcome) :-
    catch(expert_call_(Registry, Goal, Context, Outcome),
          Exception,
          expert_exception(call, Exception, Outcome)).

expert_call_(Registry, Goal, Context, Outcome) :-
    expert_select(Registry, Goal, Context, Decision),
    (   Decision.status == selected
    ->  expert_invoke(Registry,
                      Decision.expert_id,
                      Goal,
                      Context,
                      Outcome)
    ;   Decision.status == ambiguous
    ->  Outcome = expert_outcome{
                      status:blocked,
                      reason:ambiguous_expert_selection(Decision.tied),
                      evidence:[],
                      selection:Decision,
                      usage:expert_usage{model_calls:0, cost:0}
                  }
    ;   Outcome = expert_outcome{
                      status:unsupported,
                      reason:no_applicable_expert,
                      evidence:[],
                      selection:Decision,
                      usage:expert_usage{model_calls:0, cost:0}
                  }
    ).

expert_invoke(expert_registry(Id), ExpertId, Goal, Context0, Outcome) :-
    catch(expert_invoke_entry(Id, ExpertId, Goal, Context0, Outcome),
          Exception,
          expert_exception(invoke, Exception, Outcome)).

expert_invoke_entry(Id, ExpertId, Goal, Context0, Outcome) :-
    require_registry_id(Id),
    require_nonempty_atom(expert_id, ExpertId),
    require_goal_data(Goal),
    require_dict(expert_context, Context0),
    (   get_dict(expert_runtime, Context0, Runtime)
    ->  invoke_nested(Id, ExpertId, Goal, Context0, Runtime, Outcome)
    ;   invoke_root(Id, ExpertId, Goal, Context0, Outcome)
    ).

invoke_root(Id, ExpertId, Goal, Context0, Outcome) :-
    normalize_public_context(Context0, Context, Capabilities, _),
    expert_registry_state(Id, _, RegistryOptions),
    new_run_token(Token),
    setup_call_cleanup(
        assertz(expert_run_state(Token,
                                 Id,
                                 RegistryOptions.max_depth,
                                 RegistryOptions.max_invocations,
                                 0)),
        invoke_frame(Id,
                     ExpertId,
                     Goal,
                     Context,
                     Token,
                     0,
                     [],
                     Capabilities,
                     any,
                     RegistryOptions.max_depth,
                     RegistryOptions.max_invocations,
                     Outcome),
        retractall(expert_run_state(Token, Id, _, _, _))).

invoke_nested(Id,
              ExpertId,
              Goal,
              Context0,
              expert_runtime(Token,
                             ParentDepth,
                             Stack,
                             ParentCapabilities,
                             ParentPolicy,
                             ParentMaxDepth,
                             ParentMaxInvocations),
              Outcome) :-
    (   expert_run_state(Token, Id, _, _, _)
    ->  true
    ;   throw(expert_fault(stale_runtime(Token)))
    ),
    (   ParentPolicy == never
    ->  Outcome = expert_outcome{
                      status:blocked,
                      reason:child_policy_denied,
                      evidence:[],
                      usage:expert_usage{model_calls:0, cost:0}
                  }
    ;   normalize_public_context(Context0, Context, RequestedCapabilities, _),
        require_narrowing(ParentCapabilities,
                          RequestedCapabilities,
                          ChildCapabilities),
        invoke_frame(Id,
                     ExpertId,
                     Goal,
                     Context,
                     Token,
                     ParentDepth,
                     Stack,
                     ChildCapabilities,
                     ParentPolicy,
                     ParentMaxDepth,
                     ParentMaxInvocations,
                     Outcome)
    ).

invoke_frame(Id,
             ExpertId,
             Goal,
             Context,
             Token,
             ParentDepth,
             Stack,
             Capabilities,
             _ParentPolicy,
             InheritedMaxDepth,
             InheritedMaxInvocations,
             Outcome) :-
    (   expert_registry_entry(Id, ExpertId, Contract)
    ->  true
    ;   throw(expert_fault(not_registered(ExpertId)))
    ),
    goal_matches_contract_or_throw(Goal, Contract),
    capabilities_satisfy_or_throw(Capabilities, Contract.requires),
    run_budget_admit(Token,
                     Contract,
                     ParentDepth,
                     InheritedMaxDepth,
                     InheritedMaxInvocations,
                     Depth,
                     MaxDepth,
                     MaxInvocations),
    term_hash(Goal, GoalHash),
    Frame = ExpertId-GoalHash,
    (   memberchk(Frame, Stack)
    ->  Outcome = expert_outcome{
                      status:blocked,
                      expert_id:ExpertId,
                      expert_version:Contract.version,
                      reason:recursion_cycle(Frame),
                      evidence:[],
                      usage:expert_usage{model_calls:0, cost:0}
                  }
    ;   new_invocation_id(InvocationId),
        expert_registry_state(Id, Generation, _),
        record_event(Id,
                     expert_invocation{
                         event:started,
                         invocation_id:InvocationId,
                         expert_id:ExpertId,
                         expert_version:Contract.version,
                         registry_generation:Generation,
                         depth:Depth
                     }),
        put_dict(expert_runtime,
                 Context,
                 expert_runtime(Token,
                                Depth,
                                [Frame|Stack],
                                Capabilities,
                                Contract.child_policy,
                                MaxDepth,
                                MaxInvocations),
                 Context1),
        put_dict(_{expert_registry:expert_registry(Id),
                   expert_invocation_id:InvocationId,
                   capabilities:Capabilities},
                 Context1,
                 HandlerContext),
        invoke_handler(Contract,
                       Goal,
                       HandlerContext,
                       RawOutcome),
        normalize_handler_outcome(Contract,
                                  InvocationId,
                                  Generation,
                                  RawOutcome,
                                  Outcome),
        record_event(Id,
                     expert_invocation{
                         event:finished,
                         invocation_id:InvocationId,
                         expert_id:ExpertId,
                         expert_version:Contract.version,
                         registry_generation:Generation,
                         depth:Depth,
                         status:Outcome.status
                     })
    ).

invoke_handler(Contract, Goal, Context, RawOutcome) :-
    Handler = Contract.handler,
    catch(( call(Handler, Goal, Context, RawOutcome)
          ->  true
          ;   RawOutcome = error(handler_failed)
          ),
          Exception,
          RawOutcome = error(handler_exception(Exception))).

normalize_handler_outcome(Contract,
                          InvocationId,
                          Generation,
                          succeeded(Result, Evidence),
                          Outcome) :-
    !,
    require_safe_data(result, Result),
    require_safe_list(evidence, Evidence),
    base_outcome(Contract,
                 InvocationId,
                 Generation,
                 succeeded,
                 Outcome0),
    put_dict(_{result:Result, evidence:Evidence}, Outcome0, Outcome).
normalize_handler_outcome(Contract,
                          InvocationId,
                          Generation,
                          failed(Reason, Evidence),
                          Outcome) :-
    !,
    require_safe_data(reason, Reason),
    require_safe_list(evidence, Evidence),
    base_outcome(Contract, InvocationId, Generation, failed, Outcome0),
    put_dict(_{reason:Reason, evidence:Evidence}, Outcome0, Outcome).
normalize_handler_outcome(Contract,
                          InvocationId,
                          Generation,
                          unknown(Reason, Evidence),
                          Outcome) :-
    !,
    require_safe_data(reason, Reason),
    require_safe_list(evidence, Evidence),
    base_outcome(Contract, InvocationId, Generation, unknown, Outcome0),
    put_dict(_{reason:Reason, evidence:Evidence}, Outcome0, Outcome).
normalize_handler_outcome(Contract,
                          InvocationId,
                          Generation,
                          blocked(Reason, Evidence),
                          Outcome) :-
    !,
    require_safe_data(reason, Reason),
    require_safe_list(evidence, Evidence),
    base_outcome(Contract, InvocationId, Generation, blocked, Outcome0),
    put_dict(_{reason:Reason, evidence:Evidence}, Outcome0, Outcome).
normalize_handler_outcome(Contract,
                          InvocationId,
                          Generation,
                          unsupported(Reason),
                          Outcome) :-
    !,
    require_safe_data(reason, Reason),
    base_outcome(Contract, InvocationId, Generation, unsupported, Outcome0),
    put_dict(_{reason:Reason, evidence:[]}, Outcome0, Outcome).
normalize_handler_outcome(Contract,
                          InvocationId,
                          Generation,
                          cancelled(Token),
                          Outcome) :-
    !,
    require_safe_data(cancellation_token, Token),
    base_outcome(Contract, InvocationId, Generation, cancelled, Outcome0),
    put_dict(_{cancellation_token:Token, evidence:[]}, Outcome0, Outcome).
normalize_handler_outcome(Contract,
                          InvocationId,
                          Generation,
                          error(Error),
                          Outcome) :-
    !,
    safe_exception(Error, Safe),
    base_outcome(Contract, InvocationId, Generation, error, Outcome0),
    put_dict(_{error:Safe, evidence:[]}, Outcome0, Outcome).
normalize_handler_outcome(Contract,
                          InvocationId,
                          Generation,
                          Raw,
                          Outcome) :-
    base_outcome(Contract, InvocationId, Generation, error, Outcome0),
    put_dict(_{error:invalid_expert_outcome(Raw), evidence:[]},
             Outcome0,
             Outcome).

base_outcome(Contract, InvocationId, Generation, Status,
             expert_outcome{
                 status:Status,
                 expert_id:Contract.id,
                 expert_version:Contract.version,
                 invocation_id:InvocationId,
                 registry_generation:Generation,
                 usage:expert_usage{model_calls:0, cost:0}
             }).

run_budget_admit(Token,
                 Contract,
                 ParentDepth,
                 InheritedMaxDepth,
                 InheritedMaxInvocations,
                 Depth,
                 MaxDepth,
                 MaxInvocations) :-
    expert_run_state(Token,
                     RegistryId,
                     RegistryMaxDepth,
                     RegistryMaxInvocations,
                     Count0),
    Depth is ParentDepth+1,
    ContractMaxDepth is min(RegistryMaxDepth, Contract.limits.max_depth),
    MaxDepth is min(InheritedMaxDepth, ContractMaxDepth),
    (   Depth =< MaxDepth
    ->  true
    ;   throw(expert_fault(depth_exceeded(Depth, MaxDepth)))
    ),
    ContractMaxInvocations is min(RegistryMaxInvocations,
                                  Contract.limits.max_invocations),
    MaxInvocations is min(InheritedMaxInvocations,
                          ContractMaxInvocations),
    Count is Count0+1,
    (   Count =< MaxInvocations
    ->  with_mutex(rlm_expert_run,
                   ( retract(expert_run_state(Token,
                                              RegistryId,
                                              RegistryMaxDepth,
                                              RegistryMaxInvocations,
                                              Count0)),
                     assertz(expert_run_state(Token,
                                             RegistryId,
                                             RegistryMaxDepth,
                                             RegistryMaxInvocations,
                                             Count))
                   ))
    ;   throw(expert_fault(invocation_budget_exceeded(Count,
                                                      MaxInvocations)))
    ).

require_narrowing(Parent, Requested, Child) :-
    (   capabilities_narrow(Parent, Requested, ok(Child))
    ->  true
    ;   capabilities_narrow(Parent, Requested, error(Error)),
        throw(expert_fault(capability_widening(Error)))
    ).

capabilities_satisfy(Capabilities, Requires) :-
    forall(member(Required, Requires), memberchk(Required, Capabilities)).

capabilities_satisfy_or_throw(Capabilities, Requires) :-
    findall(Missing,
            ( member(Missing, Requires),
              \+ memberchk(Missing, Capabilities)
            ),
            Missing),
    (   Missing == []
    ->  true
    ;   throw(expert_fault(required_capabilities_missing(Missing)))
    ).

goal_matches_contract(Goal, Contract) :-
    goal_indicator(Goal, Indicator),
    memberchk(Indicator, Contract.accepts).

goal_matches_contract_or_throw(Goal, Contract) :-
    (   goal_matches_contract(Goal, Contract)
    ->  true
    ;   goal_indicator(Goal, Indicator),
        throw(expert_fault(goal_not_accepted(Contract.id, Indicator)))
    ).

goal_indicator(Goal, Name/Arity) :-
    callable(Goal),
    functor(Goal, Name, Arity).

normalize_public_context(Context0, Context, Capabilities, Preferred) :-
    require_dict(expert_context, Context0),
    dict_get_default(Context0, capabilities, [], Caps0),
    normalize_capabilities(Caps0, Capabilities),
    dict_get_default(Context0, preferred_expert, none, Preferred),
    (   Preferred == none
    ->  true
    ;   require_nonempty_atom(preferred_expert, Preferred)
    ),
    Context = Context0.

/* Inspection ---------------------------------------------------------- */

expert_explain(Value, Explanation) :-
    require_safe_data(explain_value, Value),
    (   is_dict(Value),
        get_dict(registry_generation, Value, Generation)
    ->  Explanation = expert_explanation{
                              value:Value,
                              registry_generation:Generation,
                              chain_of_thought:false,
                              usage:expert_usage{model_calls:0, cost:0}
                          }
    ;   Explanation = expert_explanation{
                              value:Value,
                              chain_of_thought:false,
                              usage:expert_usage{model_calls:0, cost:0}
                          }
    ).

expert_invocations(expert_registry(Id), Events) :-
    require_registry_id(Id),
    findall(Seq-Event,
            expert_invocation_event(Id, Seq, Event),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Events).

record_event(Id, Event) :-
    with_mutex(rlm_expert_events,
               ( retract(expert_registry_sequence(Id, Seq0)),
                 Seq is Seq0+1,
                 assertz(expert_registry_sequence(Id, Seq)),
                 assertz(expert_invocation_event(Id, Seq, Event))
               )).

new_run_token(expert_run(Id)) :-
    with_mutex(rlm_expert_run, gensym(run_, Id)).

new_invocation_id(expert_invocation(Id)) :-
    with_mutex(rlm_expert_run, gensym(invocation_, Id)).

/* Validation helpers -------------------------------------------------- */

require_registry_id(Id) :-
    (   expert_registry_state(Id, _, _)
    ->  true
    ;   throw(expert_fault(unknown_registry(Id)))
    ).

require_goal_data(Goal) :-
    (   ground(Goal),
        acyclic_term(Goal),
        callable(Goal)
    ->  true
    ;   throw(expert_fault(invalid_goal_data(Goal)))
    ).

require_dict(_, Value) :-
    is_dict(Value),
    !.
require_dict(Label, Value) :-
    throw(expert_fault(expected_dict(Label, Value))).

require_key(Label, Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(expert_fault(missing_key(Label, Key)))
    ).

dict_get_default(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   Value = Default
    ).

reject_unknown_keys(Label, Dict, Allowed) :-
    dict_pairs(Dict, _, Pairs),
    pairs_keys(Pairs, Keys),
    (   member(Key, Keys),
        \+ memberchk(Key, Allowed)
    ->  throw(expert_fault(unknown_key(Label, Key)))
    ;   true
    ).

require_nonempty_atom(_, Value) :-
    atom(Value),
    Value \== '',
    !.
require_nonempty_atom(Label, Value) :-
    throw(expert_fault(invalid_atom(Label, Value))).

require_version(Value) :-
    atomic(Value),
    Value \== '',
    !.
require_version(Value) :-
    throw(expert_fault(invalid_version(Value))).

require_integer(_, Value) :-
    integer(Value),
    !.
require_integer(Label, Value) :-
    throw(expert_fault(invalid_integer(Label, Value))).

require_positive_integer(_, Value) :-
    integer(Value),
    Value > 0,
    !.
require_positive_integer(Label, Value) :-
    throw(expert_fault(invalid_positive_integer(Label, Value))).

require_callable(_, Value) :-
    callable(Value),
    !.
require_callable(Label, Value) :-
    throw(expert_fault(invalid_callable(Label, Value))).

require_atom_list(_, Values) :-
    is_list(Values),
    forall(member(Value, Values), atom(Value)),
    !.
require_atom_list(Label, Values) :-
    throw(expert_fault(invalid_atom_list(Label, Values))).

require_safe_list(_, Values) :-
    is_list(Values),
    forall(member(Value, Values), safe_data(Value)),
    !.
require_safe_list(Label, Values) :-
    throw(expert_fault(unsafe_list(Label, Values))).

require_safe_data(_, Value) :-
    safe_data(Value),
    !.
require_safe_data(Label, Value) :-
    throw(expert_fault(unsafe_data(Label, Value))).

safe_data(Value) :-
    ground(Value),
    acyclic_term(Value),
    (   atomic(Value)
    ->  true
    ;   is_list(Value)
    ->  forall(member(Item, Value), safe_data(Item))
    ;   is_dict(Value)
    ->  dict_pairs(Value, _, Pairs),
        forall(member(Key-Item, Pairs),
               (atom(Key), safe_data(Item)))
    ;   compound(Value),
        Value =.. [_|Args],
        forall(member(Arg, Args), safe_data(Arg))
    ).

safe_exception(Exception, Safe) :-
    (   safe_data(Exception)
    ->  Safe = Exception
    ;   term_string(Exception, Safe,
                    [quoted(true), max_depth(8)])
    ).

expert_exception(_Phase, expert_fault(Fault),
                 expert_outcome{
                     status:error,
                     error:Fault,
                     evidence:[],
                     usage:expert_usage{model_calls:0, cost:0}
                 }) :-
    !.
expert_exception(Phase, Exception,
                 expert_outcome{
                     status:error,
                     error:expert_exception(Phase, Safe),
                     evidence:[],
                     usage:expert_usage{model_calls:0, cost:0}
                 }) :-
    safe_exception(Exception, Safe).
