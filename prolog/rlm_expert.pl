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
    require_registry_generation_current(Id, Generation),
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
    expert_registry_state(Id, ExpectedGeneration, RegistryOptions),
    ( get_dict(expected_registry_generation, Context0, PinnedGeneration)
    -> ( integer(PinnedGeneration), PinnedGeneration =:= ExpectedGeneration
       -> true
       ; throw(expert_fault(stale_registry_generation(PinnedGeneration,
                                                      ExpectedGeneration))) )
    ; true ),
    new_run_token(Token),
    setup_call_cleanup(
        assertz(expert_run_state(Token,
                                 Id,
                                 run_generation(ExpectedGeneration,
                                                RegistryOptions.max_depth),
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
    require_run_generation_current(Token, Id),
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
    require_run_generation_current(Token, Id),
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
    (   memberchk(Frame, Stac…15361 tokens truncated…              Ticket),
    EditValidator = rlm_tool:tool_effect_edit_validate(Context,
                                                       Registry,
                                                       Schema,
                                                       Binding,
                                                       Limits,
                                                       Correlation,
                                                       Request,
                                                       EffectOptions),
    rlm_authority:rlm_authorize_operation(Context,
                                          Operation,
                                          Continuation,
                                          EditValidator,
                                          AuthorityOutcome),
    invoke_after_authority_effect(AuthorityOutcome,
                                  Context,
                                  Schema,
                                  Ticket,
                                  Outcome,
                                  Authorization,
                                  AuthorityMode,
                                  Status,
                                  Bytes,
                                  Fingerprint,
                                  ApprovalId).

invoke_after_authority(error(Error), _, _, _, _, _, error(ToolError),
                       denied, _AuthorityMode, authority_denied, 0, none, none) :-
    !,
    ToolError = tool_error{
                    phase:authority,
                    kind:authority_denied,
                    cause:Error,
                    message:"host authority rejected the normalized tool operation"
                }.
invoke_after_authority(approval_required(Pending), _, _, _, _, _,
                       approval_required(Pending),
                       pending,
                       _AuthorityMode,
                       approval_required,
                       0,
                       Fingerprint,
                       ApprovalId) :-
    !,
    Fingerprint = Pending.fingerprint,
    ApprovalId = Pending.id.
invoke_after_authority(replay(Replay), _, _, _, _, _,
                       Replay,
                       allowed,
                       allow_once,
                       replayed,
                       Bytes,
                       Fingerprint,
                       none) :-
    !,
    replay_metadata(Replay, Bytes, Fingerprint).
invoke_after_authority(execute(Permit),
                       Schema,
                       Binding,
                       Args,
                       Limits,
                       Context,
                       Outcome,
                       allowed,
                       _AuthorityMode,
                       Status,
                       Bytes,
                       Fingerprint,
                       none) :-
    Fingerprint = Permit.fingerprint,
    perform_tool_effect(Schema,
                        Binding,
                        Args,
                        Limits,
                        CoreOutcome,
                        Status,
                        Bytes),
    complete_allow_once(Permit,
                        Context,
                        Fingerprint,
                        CoreOutcome),
    Outcome = CoreOutcome.

complete_allow_once(Permit, Context, Fingerprint, Outcome) :-
    (   Permit.kind == allow_once
    ->  rlm_authority:rlm_authority_complete_once(Context,
                                                  Fingerprint,
                                                  Outcome)
    ;   true
    ).

replay_metadata(ok(tool_execution{trace:Trace}), Bytes, Fingerprint) :-
    !,
    dict_value_default(output_bytes, Trace, 0, Bytes),
    dict_value_default(fingerprint, Trace, none, Fingerprint).
replay_metadata(error(Error), Bytes, Fingerprint) :-
    !,
    (   is_dict(Error), get_dict(trace, Error, Trace)
    ->  dict_value_default(output_bytes, Trace, 0, Bytes),
        dict_value_default(fingerprint, Trace, none, Fingerprint)
    ;   Bytes = 0,
        Fingerprint = none
    ).
replay_metadata(_, 0, none).

tool_pending_execute(Schema, Binding, Args, Limits, _Context, Resolution) :-
    get_time(Start),
    perform_tool_effect(Schema,
                        Binding,
                        Args,
                        Limits,
                        CoreOutcome,
                        Status,
                        Bytes),
    get_time(End),
    ElapsedMs is round((End-Start)*1000),
    Resolution = tool_pending_resolution{
                     outcome:CoreOutcome,
                     status:Status,
                     output_bytes:Bytes,
                     elapsed_ms:ElapsedMs
                 }.

/* The continuation above deliberately does not call tool_invoke/7 or
   tool_invoke_async/6. Approval resumes the already-validated operation at the
   authoritative side-effect boundary exactly once. */

/* -------------------------------------------------------------------------
 * #57 effect-boundary integration for effectful tools
 *
 * Effectful tools (effect \== read) no longer jump from authority to
 * perform_tool_effect. They prepare a durable #57 ticket before authority
 * composition, preserve that exact ground ticket into the authorized
 * continuation, and validate/admit/dispatch/observe that same ticket through
 * rlm_effect_executor on approval. The tool handler itself runs as a static
 * code-owned adapter submit hook. Only a stable code-owned binding digest
 * participates in executable semantics; the ephemeral registry identity
 * remains metadata for live dispatch lookup. Read tools retain the direct
 * fresh-read path above.
 * ---------------------------------------------------------------------- */

invoke_after_authority_effect(error(Error), _Context, _Schema, _Ticket,
                              error(ToolError),
                              denied, _AuthorityMode, authority_denied,
                              0, none, none) :-
    !,
    ToolError = tool_error{
                    phase:authority,
                    kind:authority_denied,
                    cause:Error,
                    message:"host authority rejected the normalized effectful tool operation"
                }.
invoke_after_authority_effect(approval_required(Pending), _Context, _Schema,
                              _Ticket,
                              approval_required(Pending),
                              pending, _AuthorityMode, approval_required,
                              0, Fingerprint, ApprovalId) :-
    !,
    Fingerprint = Pending.fingerprint,
    ApprovalId = Pending.id.
invoke_after_authority_effect(replay(Replay), _Context, _Schema, _Ticket,
                              Replay,
                              allowed, allow_once, replayed,
                              0, Fingerprint, none) :-
    !,
    replay_metadata(Replay, _Bytes, Fingerprint).
invoke_after_authority_effect(execute(Permit),
                              Context,
                              Schema,
                              Ticket,
                              Outcome,
                              allowed,
                              _AuthorityMode,
                              Status,
                              Bytes,
                              Fingerprint,
                              none) :-
    !,
    Fingerprint = Permit.fingerprint,
    AuthorityRef = authority_ref{context:Context, permit:Permit},
    tool_effect_dispatch(Ticket, AuthorityRef, EffectOutcome),
    tool_outcome_from_effect(EffectOutcome, Schema, Outcome, Status, Bytes),
    complete_allow_once(Permit, Context, Fingerprint, Outcome).

tool_effect_pending_execute(Context, Schema, Ticket, Resolution) :-
    get_time(Start),
    AuthorityRef = authority_ref{context:Context},
    tool_effect_dispatch(Ticket, AuthorityRef, EffectOutcome),
    tool_outcome_from_effect(EffectOutcome, Schema, CoreOutcome, Status, Bytes),
    get_time(End),
    ElapsedMs is round((End-Start)*1000),
    Resolution = tool_pending_resolution{
                     outcome:CoreOutcome,
                     status:Status,
                     output_bytes:Bytes,
                     elapsed_ms:ElapsedMs
                 }.

tool_effect_dispatch(Ticket, AuthorityRef, EffectOutcome) :-
    catch(rlm_effect_executor:effect_execute_prepared(rlm_tool, Ticket,
                                                      AuthorityRef,
                                                      EffectOutcome),
          Exception,
          effect_dispatch_exception(Exception, EffectOutcome)).

effect_dispatch_exception(rlm_async_cancelled(Id), _) :-
    !,
    throw(rlm_async_cancelled(Id)).
effect_dispatch_exception(Exception,
                          effect_result{state:indeterminate,
                                        source:executor_exception,
                                        attempt:none}) :-
    safe_exception_term(Exception, _).

tool_effect_request(Schema, NormalizedArgs, Details, Request) :-
    Request = tool_effect_request{tool:Schema.name,
                                  args:NormalizedArgs,
                                  details:Details}.

tool_effect_options(RegistryId, Schema, Binding, Limits, _Correlation,
                    EffectOptions) :-
    Tool = Schema.name,
    tool_executor_identity(Binding, ExecutorIdentity),
    Semantics = tool_effect_semantics{
                    tool_executor:ExecutorIdentity,
                    effect:Schema.effect,
                    limits:Limits
                },
    EffectOptions = metadata_options{
                        metadata:tool_effect_metadata{
                            registry:RegistryId,
                            tool:Tool,
                            limits:Limits
                        },
                        semantics:Semantics
                    }.

tool_executor_identity(Binding,
                       tool_executor_identity{version:1,
                                              digest:Digest}) :-
    tool_binding_entrypoints(Binding, Descriptor),
    term_string(Descriptor, Serialized,
                [quoted(true), numbervars(true), ignore_ops(true)]),
    crypto_data_hash(Serialized, Hex,
                     [algorithm(sha256), encoding(utf8)]),
    atom_concat('sha256:', Hex, Digest).

tool_binding_entrypoints(tool_binding(Preflight, Handler),
                         tool_executor_descriptor{
                             preflight:PreflightIdentity,
                             handler:HandlerIdentity
                         }) :-
    trusted_callable_entrypoint(Preflight, 3, PreflightIdentity),
    trusted_callable_entrypoint(Handler, 2, HandlerIdentity).

trusted_callable_entrypoint(Callable, AddedArity,
                            predicate_identity{module:Module,
                                               name:Name,
                                               arity:Arity}) :-
    strip_module(Callable, Module, Plain),
    functor(Plain, Name, BoundArity),
    Arity is BoundArity+AddedArity.

tool_outcome_from_effect(EffectOutcome, Schema, Outcome, Status, Bytes) :-
    is_dict(EffectOutcome, effect_result),
    !,
    (   get_dict(state, EffectOutcome, observed),
        get_dict(observation, EffectOutcome, Observation)
    ->  tool_outcome_from_observation(Observation, Schema, Outcome, Status, Bytes)
    ;   get_dict(state, EffectOutcome, indeterminate)
    ->  Bytes = 0,
        Outcome = error(tool_error{
                            phase:effect,
                            kind:effect_indeterminate,
                            message:"effectful tool attempt is indeterminate and requires reconciliation"
                        }),
        Status = indeterminate
    ;   get_dict(state, EffectOutcome, in_progress)
    ->  Bytes = 0,
        Outcome = error(tool_error{
                            phase:effect,
                            kind:effect_in_progress,
                            message:"effectful tool attempt is still running"
                        }),
        Status = effect_in_progress
    ;   get_dict(state, EffectOutcome, terminal)
    ->  Bytes = 0,
        Outcome = error(tool_error{
                            phase:effect,
                            kind:effect_terminal,
                            message:"effectful tool attempt is in a terminal state"
                        }),
        Status = effect_terminal
    ;   Bytes = 0,
        Outcome = error(tool_error{
                            phase:effect,
                            kind:unknown_effect_result,
                            detail:EffectOutcome
                        }),
        Status = unknown_effect_result
    ).
tool_outcome_from_effect(EffectError, _Schema, error(ToolError),
                         effect_error, 0) :-
    is_dict(EffectError, error),
    !,
    ToolError = tool_error{
                    phase:effect,
                    kind:effect_dispatch_failed,
                    cause:EffectError,
                    message:"effectful tool dispatch failed"
                }.
tool_outcome_from_effect(Other, _Schema,
                         error(tool_error{phase:effect,
                                          kind:unknown_effect_result,
                                          detail:Other}),
                         unknown_effect_result, 0).

tool_outcome_from_observation(Observation, _Schema, Outcome, Status, Bytes) :-
    observation_bytes(Observation, Bytes),
    (   Observation.status == succeeded
    ->  get_dict(value, Observation, Value),
        Outcome = ok(Value),
        Status = ok
    ;   get_dict(value, Observation, Value),
        Outcome = error(Value),
        Status = failed
    ).

observation_bytes(Observation, Bytes) :-
    (   get_dict(usage, Observation, Usage),
        get_dict(output_bytes, Usage, Bytes)
    ->  true
    ;   Bytes = 0 ).

tool_observation_from_outcome(ok(Value), _Status, Bytes, Schema,
                              Observation) :-
    !,
    Observation = observation{status:succeeded,
                              value:Value,
                              usage:usage{units:1, output_bytes:Bytes},
                              provenance:rlm_tool,
                              tool:Schema.name}.
tool_observation_from_outcome(error(Error), _Status, Bytes, Schema,
                              Observation) :-
    Observation = observation{status:failed,
                              value:Error,
                              usage:usage{units:1, output_bytes:Bytes},
                              provenance:rlm_tool,
                              tool:Schema.name}.

/* Adapter submit: recover the trusted binding from the live registry, then
   invoke the canonical tool handler boundary. The callable binding is never
   persisted; the registry identity is metadata only and the stable executor
   digest lives in executable semantics. */

rlm_effect_executor:effect_adapter_submit(rlm_tool, Attempt, Request,
                                          observed(Observation)) :-
    get_dict(tool, Request, Name),
    get_dict(args, Request, Args),
    get_dict(metadata, Attempt, Metadata),
    get_dict(registry, Metadata, RegistryId),
    get_dict(limits, Metadata, Limits),
    (   tool_registry_entry(RegistryId, Name, Schema, Binding)
    ->  perform_tool_effect(Schema,
                            Binding,
                            Args,
                            Limits,
                            CoreOutcome,
                            Status,
                            Bytes),
        tool_observation_from_outcome(CoreOutcome, Status, Bytes, Schema,
                                      Observation)
    ;   Observation = observation{status:failed,
                                  value:tool_error{
                                      phase:effect,
                                      kind:tool_not_registered,
                                      tool:Name,
                                      message:"effectful tool binding is not available in this runtime"
                                  },
                                  usage:usage{units:0, output_bytes:0},
                                  provenance:rlm_tool,
                                  tool:Name}
    ).

/* Edit validator for effectful tools: re-normalize the edited payload,
   re-preflight, re-prepare a fresh #57 ticket, and build the new trusted
   continuation from that ticket. The old attempt ticket can never execute. */

tool_effect_edit_validate(Context, Registry, Schema, Binding, Limits,
                          Correlation, _OldRequest, _OldEffectOptions,
                          Edited0, Operation, Continuation) :-
    edited_args(Edited0, EditedArgs),
    validate_schema(Schema.arguments, EditedArgs, args, ok),
    preflight_tool(Binding, EditedArgs, Limits.time_limit,
                   ok(NormalizedArgs, Details)),
    registry_id(Registry, RegistryId),
    tool_effect_request(Schema, NormalizedArgs, Details, Request),
    tool_effect_options(RegistryId, Schema, Binding, Limits,
                        Correlation, EffectOptions),
    rlm_effect_executor:effect_prepare(rlm_tool, tool, Request,
                                       EffectOptions, PrepareDecision),
    (   PrepareDecision = execute(Ticket)
    ->  true
    ;   throw(tool_fault(effect_prepare_failed_for_edit(PrepareDecision)))
    ),
    BaseOperation = authority_operation{
                        name:Schema.name,
                        effect:Schema.effect,
                        capability:Schema.capability,
                        args:NormalizedArgs,
                        details:Details
                    },
    rlm_effect_authority:effect_authority_operation(Ticket, BaseOperation,
                                                     Correlation, Operation),
    Continuation = rlm_tool:tool_effect_pending_execute(Context,
                                                        Schema,
                                                        Ticket).

perform_tool_effect(Schema,
                    tool_binding(_, Handler),
                    Args,
                    Limits,
                    Outcome,
                    Status,
                    Bytes) :-
    call_tool_with_limit(Handler, Args, Limits.time_limit, CallOutcome),
    invoke_after_call(CallOutcome, Schema, Limits, Outcome, Status, Bytes).

call_tool_with_limit(Handler, Args, TimeLimit, Outcome) :-
    catch(call_with_time_limit(TimeLimit,
                               call_tool_handler(Handler, Args, Outcome)),
          Exception,
          timed_tool_exception(Exception, Outcome)).

call_tool_handler(Handler, Args, Outcome) :-
    (   call(Handler, Args, Value)
    ->  Outcome = ok(Value)
    ;   Outcome = error(tool_error{
                            phase:invoke,
                            kind:handler_failed,
                            message:"tool handler failed without returning a value"
                        })
    ).

timed_tool_exception(Exception, _) :-
    tool_control_exception(Exception),
    !,
    throw(Exception).
timed_tool_exception(time_limit_exceeded,
                     error(tool_error{
                               phase:invoke,
                               kind:timeout,
                               message:"tool invocation exceeded its wall-time limit"
                           })) :- !.
timed_tool_exception(time_limit_exceeded(_),
                     error(tool_error{
                               phase:invoke,
                               kind:timeout,
                               message:"tool invocation exceeded its wall-time limit"
                           })) :- !.
timed_tool_exception(Exception,
                     error(tool_error{
                               phase:invoke,
                               kind:handler_exception,
                               exception:Safe,
                               message:"tool handler raised an exception"
                           })) :-
    safe_exception(Exception, Safe).

invoke_after_call(error(Error), _, _, error(Error), Status, 0) :-
    !,
    error_status(Error, Status).
invoke_after_call(ok(Value), Schema, Limits, Outcome, Status, Bytes) :-
    validate_schema(Schema.result, Value, result, ResultOutcome),
    invoke_after_result(ResultOutcome,
                        Value,
                        Schema,
                        Limits,
                        Outcome,
                        Status,
                        Bytes).

invoke_after_result(error(Error), _, _, _, error(Error), invalid_result, 0) :- !.
invoke_after_result(ok, Value, Schema, Limits, Outcome, Status, Bytes) :-
    value_bytes(Value, Bytes0),
    (   Bytes0 =< Limits.max_output_bytes
    ->  Bytes = Bytes0,
        Status = ok,
        Outcome = ok(Value)
    ;   Bytes = Bytes0,
        Status = oversized_output,
        Outcome = error(tool_error{
                            phase:normalize,
                            kind:oversized_output,
                            tool:Schema.name,
                            output_bytes:Bytes0,
                            limit:Limits.max_output_bytes,
                            message:"tool output exceeds its byte limit"
                        })
    ).

error_status(Error, Status) :-
    (   is_dict(Error), get_dict(kind, Error, Kind)
    ->  Status = Kind
    ;   Status = error
    ).

attach_trace(ok(Value), Trace,
             ok(tool_execution{value:Value, trace:Trace})) :- !.
attach_trace(error(Error0), Trace, error(Error)) :-
    !,
    (   is_dict(Error0)
    ->  put_dict(trace, Error0, Trace, Error)
    ;   Error = tool_error{
                    phase:invoke,
                    kind:tool_error,
                    cause:Error0,
                    trace:Trace,
                    message:"tool invocation failed"
                }
    ).
attach_trace(approval_required(Pending0), Trace,
             approval_required(Pending)) :-
    put_dict(trace, Pending0, Trace, Pending).

/* -------------------------------------------------------------------------
 * Exact operation construction, editing and context
 * ---------------------------------------------------------------------- */

tool_edit_validate(Schema,
                   Binding,
                   Options,
                   Limits,
                   Context,
                   Correlation,
                   Edited0,
                   Operation,
                   Continuation) :-
    edited_args(Edited0, EditedArgs),
    validate_schema(Schema.arguments, EditedArgs, args, ok),
    preflight_tool(Binding, EditedArgs, Limits.time_limit,
                   ok(NormalizedArgs, Details)),
    Operation = authority_operation{
                    name:Schema.name,
                    effect:Schema.effect,
                    capability:Schema.capability,
                    args:NormalizedArgs,
                    details:Details,
                    correlation:Correlation
                },
    Continuation = rlm_tool:tool_pending_execute(Schema,
                                                 Binding,
                                                 NormalizedArgs,
                                                 Limits,
                                                 Context),
    (Options = _ -> true).

edited_args(Edited, Args) :-
    is_dict(Edited),
    get_dict(args, Edited, Args),
    !.
edited_args(Args, Args) :- is_dict(Args), !.
edited_args(Edited, _) :- throw(tool_fault(invalid_edited_operation(Edited))).

tool_authority_context(Registry, Options, Context) :-
    (   option_ground(authority_context, Options, Explicit), Explicit \== none
    ->  Context = Explicit
    ;   rlm_async:rlm_async_current_metadata(Current),
        metadata_context(Current, CurrentContext),
        CurrentContext \== none
    ->  Context = CurrentContext
    ;   option_ground(session_id, Options, Session), Session \== none
    ->  Context = session(Session)
    ;   option_ground(runtime_id, Options, Runtime), Runtime \== none
    ->  Context = runtime(Runtime)
    ;   Registry = tool_registry(Id),
        Context = tool_registry(Id)
    ).

metadata_context(Current, Context) :-
    is_dict(Current),
    get_dict(authority_context, Current, Found),
    Found \== none,
    !,
    Context = Found.
metadata_context(Current, session(Session)) :-
    is_dict(Current),
    get_dict(session_id, Current, Session),
    Session \== none,
    !.
metadata_context(Current, agent(Runtime, Agent)) :-
    is_dict(Current),
    get_dict(runtime_id, Current, Runtime),
    get_dict(agent_id, Current, Agent),
    Runtime \== none,
    Agent \== none,
    !.
metadata_context(Current, graph(Runtime, Graph, Run)) :-
    is_dict(Current),
    get_dict(runtime_id, Current, Runtime),
    get_dict(graph_id, Current, Graph),
    get_dict(run_id, Current, Run),
    Runtime \== none,
    Graph \== none,
    Run \== none,
    !.
metadata_context(Current, runtime(Runtime)) :-
    is_dict(Current),
    get_dict(runtime_id, Current, Runtime),
    Runtime \== none,
    !.
metadata_context(_, none).

tool_correlation(Options, Correlation) :-
    rlm_async:rlm_async_current_metadata(Current),
    correlation_field(trace_id, Options, Current, TraceId),
    correlation_field(session_id, Options, Current, SessionId),
    correlation_field(runtime_id, Options, Current, RuntimeId),
    correlation_field(agent_id, Options, Current, AgentId),
    correlation_field(graph_id, Options, Current, GraphId),
    correlation_field(run_id, Options, Current, RunId),
    Correlation = correlation{trace_id:TraceId,
                              session_id:SessionId,
                              runtime_id:RuntimeId,
                              agent_id:AgentId,
                              graph_id:GraphId,
                              run_id:RunId}.

correlation_field(Name, Options, Current, Value) :-
    (   option_ground(Name, Options, Found), Found \== none
    ->  Value = Found
    ;   is_dict(Current), get_dict(Name, Current, CurrentFound)
    ->  Value = CurrentFound
    ;   Value = none
    ).

option_ground(Name, Options, Value) :-
    metadata_option(Name, Options, none, Value).

/* -------------------------------------------------------------------------
 * Plan-runtime adapter
 * ---------------------------------------------------------------------- */

tool_registry_runtime_tools(Registry, Capabilities, Tools) :-
    tool_registry_runtime_tools(Registry, Capabilities, [], Tools).

tool_registry_runtime_tools(Registry, Capabilities, InvocationOptions, Tools) :-
    registry_id(Registry, Id),
    findall(tool(Name,
                 rlm_tool:registry_plan_handler(Registry,
                                                Capabilities,
                                                InvocationOptions,
                                                Name)),
            tool_registry_entry(Id, Name, _, _),
            Tools).

registry_plan_handler(Registry, Capabilities, InvocationOptions, Name, Args,
                      Envelope) :-
    tool_invoke_execute(Registry,
                        Capabilities,
                        Name,
                        Args,
                        InvocationOptions,
                        Result),
    Outcome = Result.outcome,
    Trace = Result.trace,
    plan_envelope(Outcome, Trace, Envelope).

plan_envelope(ok(Execution), Trace,
              tool_result{value:Execution.value,
                          authorization:Trace.authorization,
                          authority:Trace.authority,
                          status:Trace.status,
                          fingerprint:Trace.fingerprint,
                          approval_id:Trace.approval_id,
                          output_bytes:Trace.output_bytes,
                          elapsed_ms:Trace.elapsed_ms}) :- !.
plan_envelope(approval_required(Pending), Trace,
              tool_result{value:Pending,
                          authorization:pending,
                          authority:Trace.authority,
                          status:approval_required,
                          fingerprint:Trace.fingerprint,
                          approval_id:Trace.approval_id,
                          output_bytes:0,
                          elapsed_ms:Trace.elapsed_ms}) :- !.
plan_envelope(error(Error), _, _) :-
    throw(error(rlm_tool(Error), _)).

/* -------------------------------------------------------------------------
 * Built-in read-only project tool
 * ---------------------------------------------------------------------- */

register_project_read_tool(Registry, Root0, Options, Outcome) :-
    catch(register_project_read_tool_(Registry, Root0, Options, Outcome),
          Exception,
          tool_api_exception(register_project_read, Exception, Outcome)).

register_project_read_tool_(Registry, Root0, Options, Outcome) :-
    normalize_root(Root0, Root),
    option_value(max_file_bytes, Options, 8192, MaxFileBytes),
    option_value(time_limit, Options, 1.0, TimeLimit),
    require_positive_integer(MaxFileBytes, max_file_bytes),
    require_positive_number(TimeLimit, time_limit),
    project_read_schema(MaxFileBytes, TimeLimit, Schema),
    Preflight = rlm_tool:project_read_preflight(Root, MaxFileBytes),
    Handler = rlm_tool:project_read_handler,
    tool_register(Registry,
                  Schema,
                  tool_handler(Preflight, Handler),
                  Outcome).

project_read_schema(MaxBytes, TimeLimit, Schema) :-
    MaxOutputBytes is MaxBytes+1024,
    Schema = tool_schema{
                 name:project_read,
                 description:"Read one UTF-8 regular file beneath an explicitly registered project root",
                 capability:tool(project_read),
                 effect:read,
                 arguments:_{
                     type:object,
                     required:[path],
                     additional_properties:false,
                     properties:_{path:_{type:string}}
                 },
                 result:_{
                     type:object,
                     required:[path,content,bytes,truncated],
                     additional_properties:false,
                     properties:_{
                         path:_{type:string},
                         content:_{type:string},
                         bytes:_{type:integer},
                         truncated:_{type:boolean}
                     }
                 },
                 limits:tool_limits{
                     time_limit:TimeLimit,
                     max_output_bytes:MaxOutputBytes
                 }
             }.

project_read_preflight(Root, MaxFileBytes, Args,
                       json{path:Relative, absolute:Absolute, bytes:Size},
                       operation_details{target_path:Absolute,
                                         project_root:Root}) :-
    get_dict(path, Args, Path0),
    text_string(Path0, Relative),
    safe_relative_path(Relative, Segments),
    reject_symlink_components(Root, Segments),
    absolute_file_name(Relative,
                       Absolute,
                       [ relative_to(Root),
                         access(read),
                         file_type(regular),
                         file_errors(fail),
                         solutions(first)
                       ]),
    path_within_root(Root, Absolute),
    size_file(Absolute, Size),
    Size =< MaxFileBytes.

project_read_handler(Args, Result) :-
    Relative = Args.path,
    Absolute = Args.absolute,
    Size = Args.bytes,
    setup_call_cleanup(open(Absolute, read, Stream, [encoding(utf8)]),
                       read_string(Stream, _, Content),
                       close(Stream)),
    Result = json{path:Relative,
                  content:Content,
                  bytes:Size,
                  truncated:false}.

normalize_root(Root0, Root) :-
    absolute_file_name(Root0,
                       Root0Abs,
                       [ file_type(directory),
                         access(read),
                         file_errors(fail),
                         solutions(first)
                       ]),
    strip_trailing_slash(Root0Abs, Root).

safe_relative_path(Path, Segments) :-
    string(Path),
    Path \== "",
    \+ sub_string(Path, 0, 1, _, "/"),
    \+ sub_string(Path, _, _, _, "\\"),
    \+ sub_string(Path, _, _, _, "\u0000"),
    split_string(Path, "/", "", Segments),
    Segments \== [],
    maplist(safe_path_segment, Segments).

safe_path_segment(Segment) :-
    Segment \== "",
    Segment \== ".",
    Segment \== "..".

reject_symlink_components(Root, Segments) :-
    reject_symlink_components_(Segments, Root).

reject_symlink_components_([], _).
reject_symlink_components_([Segment|Segments], Parent) :-
    atom_string(SegmentAtom, Segment),
    directory_file_path(Parent, SegmentAtom, Candidate),
    \+ read_link(Candidate, _, _),
    reject_symlink_components_(Segments, Candidate).

path_within_root('/', Absolute) :-
    sub_atom(Absolute, 0, 1, _, '/'),
    !.
path_within_root(Root, Absolute) :-
    atom_concat(Root, '/', Prefix),
    sub_atom(Absolute, 0, _, _, Prefix).

strip_trailing_slash('/', '/') :- !.
strip_trailing_slash(Path0, Path) :-
    (   atom_concat(Path, '/', Path0), Path \== ''
    ->  true
    ;   Path = Path0
    ).

/* -------------------------------------------------------------------------
 * Schema validation
 * ---------------------------------------------------------------------- */

normalize_tool_schema(Schema0, Schema) :-
    require_schema_container(Schema0),
    require_schema_key(Schema0, name, Name),
    require_tool_name(Name),
    require_schema_key(Schema0, capability, Capability),
    must_be_capability(Capability),
    require_matching_tool_capability(Name, Capability),
    require_schema_key(Schema0, effect, Effect),
    require_effect(Effect),
    require_schema_key(Schema0, arguments, Arguments0),
    require_schema_key(Schema0, result, Result0),
    validate_schema_definition(Arguments0),
    validate_schema_definition(Result0),
    normalize_authority_value(Arguments0, Arguments),
    normalize_authority_value(Result0, Result),
    schema_description(Schema0, Description),
    schema_limits(Schema0, Limits),
    BaseSchema = tool_schema{
                 name:Name,
                 description:Description,
                 capability:Capability,
                 effect:Effect,
                 arguments:Arguments,
                 result:Result,
                 limits:Limits
             },
    ( get_dict(requires, Schema0, Requires0)
    -> capabilities_normalize(Requires0, RequiresOutcome),
       ( RequiresOutcome = ok(Requires)
       -> put_dict(requires, BaseSchema, Requires, Schema)
       ; throw(tool_fault(invalid_required_capabilities(RequiresOutcome))) )
    ; Schema = BaseSchema ).

require_effect(Effect) :-
    rlm_authority:rlm_effect_class(Effect),
    !.
require_effect(Effect) :-
    throw(tool_fault(invalid_effect_class(Effect))).

require_schema_container(Schema) :- is_dict(Schema), !.
require_schema_container(Schema) :-
    throw(tool_fault(invalid_schema_container(Schema))).

require_tool_name(Name) :- atom(Name), Name \== '', !.
require_tool_name(Name) :- throw(tool_fault(invalid_tool_name(Name))).

require_matching_tool_capability(Name, tool(Name)) :- !.
require_matching_tool_capability(Name, Capability) :-
    throw(tool_fault(tool_capability_mismatch(Name, Capability))).

schema_description(Schema, Description) :-
    (   get_dict(description, Schema, Value)
    ->  ( text_string(Value, Description)
        -> true
        ;  throw(tool_fault(invalid_description(Value)))
        )
    ;   Description = ""
    ).

schema_limits(Schema, Limits) :-
    (   get_dict(limits, Schema, Limits0)
    ->  require_limits_dict(Limits0)
    ;   Limits0 = _{}
    ),
    limit_value(time_limit, Limits0, 1.0, TimeLimit),
    limit_value(max_output_bytes, Limits0, 4096, MaxBytes),
    require_positive_number(TimeLimit, time_limit),
    require_positive_integer(MaxBytes, max_output_bytes),
    Limits = tool_limits{time_limit:TimeLimit,
                         max_output_bytes:MaxBytes}.

require_limits_dict(Limits) :- is_dict(Limits), !.
require_limits_dict(Limits) :- throw(tool_fault(invalid_limits(Limits))).

validate_schema_definition(Schema) :-
    (   is_dict(Schema),
        get_dict(type, Schema, Type),
        memberchk(Type, [any,string,integer,number,boolean,list,array,object])
    ->  validate_schema_definition_type(Type, Schema)
    ;   throw(tool_fault(invalid_schema(Schema)))
    ).

validate_schema_definition_type(integer, Schema) :-
    !,
    validate_numeric_schema_definition(Schema).
validate_schema_definition_type(number, Schema) :-
    !,
    validate_numeric_schema_definition(Schema).
validate_schema_definition_type(object, Schema) :-
    !,
    validate_object_schema_properties(Schema),
    validate_object_schema_required(Schema).
validate_schema_definition_type(list, Schema) :-
    !,
    (   get_dict(items, Schema, ItemSchema)
    ->  validate_schema_definition(ItemSchema)
    ;   true
    ).
validate_schema_definition_type(array, Schema) :-
    !,
    (   get_dict(items, Schema, ItemSchema)
    ->  validate_schema_definition(ItemSchema)
    ;   true
    ).
validate_schema_definition_type(_, _).

validate_numeric_schema_definition(Schema) :-
    numeric_bound_keys(Keys),
    maplist(validate_numeric_bound_definition(Schema), Keys),
    numeric_bounds(Schema, [minimum, exclusiveMinimum], LowerBounds),
    numeric_bounds(Schema, [maximum, exclusiveMaximum], UpperBounds),
    validate_numeric_intervals(LowerBounds, UpperBounds).

numeric_bound_keys([minimum, maximum, exclusiveMinimum, exclusiveMaximum]).

validate_numeric_bound_definition(Schema, Key) :-
    (   get_dict(Key, Schema, Bound)
    ->  ( number(Bound)
        -> true
        ;  throw(tool_fault(invalid_numeric_bound(Key, Bound)))
        )
    ;   true
    ).

numeric_bounds(_, [], []).
numeric_bounds(Schema, [Key|Keys], Bounds) :-
    (   get_dict(Key, Schema, Value)
    ->  Bounds = [bound(Key, Value)|Rest]
    ;   Bounds = Rest
    ),
    numeric_bounds(Schema, Keys, Rest).

validate_numeric_intervals([], _).
validate_numeric_intervals([Lower|Lowers], Uppers) :-
    maplist(validate_numeric_interval(Lower), Uppers),
    validate_numeric_intervals(Lowers, Uppers).

validate_numeric_interval(bound(LowerKey, Lower), bound(UpperKey, Upper)) :-
    numeric_interval_nonempty(LowerKey, Lower, UpperKey, Upper),
    !.
validate_numeric_interval(bound(LowerKey, Lower), bound(UpperKey, Upper)) :-
    throw(tool_fault(contradictory_numeric_bounds(LowerKey,
                                                  Lower,
                                                  UpperKey,
                                                  Upper))).

numeric_interval_nonempty(minimum, Lower, maximum, Upper) :- Lower =< Upper.
numeric_interval_nonempty(minimum, Lower, exclusiveMaximum, Upper) :-
    Lower < Upper.
numeric_interval_nonempty(exclusiveMinimum, Lower, maximum, Upper) :-
    Lower < Upper.
numeric_interval_nonempty(exclusiveMinimum, Lower, exclusiveMaximum, Upper) :-
    Lower < Upper.

validate_object_schema_properties(Schema) :-
    (   get_dict(properties, Schema, Properties)
    ->  ( is_dict(Properties)
        -> dict_pairs(Properties, _, Pairs),
           maplist(validate_property_schema, Pairs)
        ;  throw(tool_fault(invalid_properties(Properties)))
        )
    ;   true
    ).

validate_object_schema_required(Schema) :-
    (   get_dict(required, Schema, Required)
    ->  ( is_list(Required), maplist(atom, Required)
        -> true
        ;  throw(tool_fault(invalid_required_fields(Required)))
        )
    ;   true
    ).

validate_property_schema(_-Schema) :- validate_schema_definition(Schema).

validate_schema(Schema, Value, Path, Outcome) :-
    catch(( validate_schema_value(Schema, Value, Path), Outcome = ok ),
          tool_fault(Fault),
          schema_fault(Path, Fault, Outcome)).

validate_schema_value(Schema, Value, Path) :-
    get_dict(type, Schema, Type),
    validate_type(Type, Schema, Value, Path).

validate_type(any, _, _, _) :- !.
validate_type(string, _, Value, _) :- text_string(Value, _), !.
validate_type(integer, Schema, Value, Path) :-
    integer(Value),
    !,
    validate_numeric_value_bounds(Schema, Value, Path).
validate_type(number, Schema, Value, Path) :-
    number(Value),
    !,
    validate_numeric_value_bounds(Schema, Value, Path).
validate_type(boolean, _, Value, _) :- memberchk(Value, [true,false]), !.
validate_type(list, Schema, Value, Path) :-
    is_list(Value),
    !,
    (   get_dict(items, Schema, ItemSchema)
    ->  validate_list_items(Value, ItemSchema, Path, 0)
    ;   true
    ).
validate_type(array, Schema, Value, Path) :-
    is_list(Value),
    !,
    (   get_dict(items, Schema, ItemSchema)
    ->  validate_list_items(Value, ItemSchema, Path, 0)
    ;   true
    ).
validate_type(object, Schema, Value, Path) :-
    is_dict(Value),
    !,
    validate_object(Schema, Value, Path).
validate_type(Type, _, Value, Path) :-
    throw(tool_fault(schema_type_mismatch(Path, Type, Value))).

validate_numeric_value_bounds(Schema, Value, Path) :-
    validate_numeric_value_bound(Schema, minimum, Value, Path),
    validate_numeric_value_bound(Schema, maximum, Value, Path),
    validate_numeric_value_bound(Schema, exclusiveMinimum, Value, Path),
    validate_numeric_value_bound(Schema, exclusiveMaximum, Value, Path).

validate_numeric_value_bound(Schema, Key, Value, Path) :-
    (   get_dict(Key, Schema, Bound)
    ->  validate_numeric_bound(Key, Value, Bound, Path)
    ;   true
    ).

validate_numeric_bound(minimum, Value, Bound, _) :- Value >= Bound, !.
validate_numeric_bound(maximum, Value, Bound, _) :- Value =< Bound, !.
validate_numeric_bound(exclusiveMinimum, Value, Bound, _) :- Value > Bound, !.
validate_numeric_bound(exclusiveMaximum, Value, Bound, _) :- Value < Bound, !.
validate_numeric_bound(Key, Value, Bound, Path) :-
    throw(tool_fault(numeric_bound_violation(Path, Key, Bound, Value))).

validate_list_items([], _, _, _).
validate_list_items([Value|Values], Schema, Path, Index) :-
    validate_schema_value(Schema, Value, Path-Index),
    Next is Index+1,
    validate_list_items(Values, Schema, Path, Next).

validate_object(Schema, Value, Path) :-
    (   get_dict(required, Schema, Required)
    ->  maplist(require_object_key(Value, Path), Required)
    ;   true
    ),
    (   get_dict(properties, Schema, Properties)
    ->  validate_object_properties(Properties, Value, Path),
        validate_additional_properties(Schema, Properties, Value, Path)
    ;   true
    ).

require_object_key(Value, Path, Key) :-
    (   get_dict(Key, Value, _)
    ->  true
    ;   throw(tool_fault(missing_required_field(Path, Key)))
    ).

validate_object_properties(Properties, Value, Path) :-
    dict_pairs(Properties, _, Pairs),
    maplist(validate_present_property(Value, Path), Pairs).

validate_present_property(Value, Path, Key-Schema) :-
    (   get_dict(Key, Value, FieldValue)
    ->  validate_schema_value(Schema, FieldValue, Path-Key)
    ;   true
    ).

validate_additional_properties(Schema, Properties, Value, Path) :-
    (   get_dict(additional_properties, Schema, false)
    ->  dict_keys(Properties, Allowed),
        dict_keys(Value, Actual),
        subtract(Actual, Allowed, Extra),
        ( Extra == []
        -> true
        ;  throw(tool_fault(unexpected_fields(Path, Extra)))
        )
    ;   true
    ).

schema_fault(Path, Fault,
             error(tool_error{
                       phase:schema,
                       kind:schema_validation_failed,
                       path:Path,
                       detail:Fault,
                       message:"tool value does not match its declared schema"
                   })).

/* -------------------------------------------------------------------------
 * Authority-value normalization and helpers
 * ---------------------------------------------------------------------- */

normalize_authority_value(Value, _) :-
    var(Value),
    !,
    throw(tool_fault(nonground_authority_value)).
normalize_authority_value(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, Tag0, Pairs0),
    normalize_dict_tag(Tag0, Tag),
    maplist(normalize_authority_pair, Pairs0, Pairs),
    dict_pairs(Value, Tag, Pairs).
normalize_authority_value(Value0, Value) :-
    is_list(Value0),
    !,
    maplist(normalize_authority_value, Value0, Value).
normalize_authority_value(Value0, Value) :-
    compound(Value0),
    !,
    Value0 =.. [Functor|Args0],
    maplist(normalize_authority_value, Args0, Args),
    Value =.. [Functor|Args].
normalize_authority_value(Value, Value) :- atomic(Value), !.
normalize_authority_value(Value, _) :-
    throw(tool_fault(invalid_authority_value(Value))).

normalize_dict_tag(Tag0, json) :- var(Tag0), !.
normalize_dict_tag(Tag, Tag) :- atom(Tag), !.
normalize_dict_tag(Tag, _) :- throw(tool_fault(invalid_dict_tag(Tag))).

normalize_authority_pair(Key-Value0, Key-Value) :-
    normalize_authority_value(Value0, Value).

registry_id(tool_registry(Id), Id) :- tool_registry_alive(Id), !.
registry_id(Registry, _) :-
    throw(tool_fault(invalid_or_stale_registry(Registry))).

require_schema_key(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(tool_fault(missing_schema_field(Key)))
    ).

effective_limits(Spec, Options,
                 tool_limits{time_limit:TimeLimit,
                             max_output_bytes:MaxBytes}) :-
    option_value(time_limit, Options, Spec.time_limit, RequestedTime),
    option_value(max_output_bytes, Options, Spec.max_output_bytes,
                 RequestedBytes),
    require_positive_number(RequestedTime, time_limit),
    require_positive_integer(RequestedBytes, max_output_bytes),
    TimeLimit is min(Spec.time_limit, RequestedTime),
    MaxBytes is min(Spec.max_output_bytes, RequestedBytes).

limit_value(Key, Dict, Default, Value) :-
    (   is_dict(Dict), get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

option_value(Name, Options, Default, Value) :-
    (   is_list(Options),
        member(Option, Options),
        nonvar(Option),
        Option =.. [Name, Found]
    ->  Value = Found
    ;   Value = Default
    ).

require_positive_integer(Value, _) :- integer(Value), Value > 0, !.
require_positive_integer(Value, Field) :-
    throw(tool_fault(invalid_positive_integer(Field, Value))).

require_positive_number(Value, _) :- number(Value), Value > 0, !.
require_positive_number(Value, Field) :-
    throw(tool_fault(invalid_positive_number(Field, Value))).

text_string(Value, String) :- string(Value), !, String = Value.
text_string(Value, String) :- atom(Value), !, atom_string(Value, String).

value_bytes(Value, Bytes) :-
    term_string(Value, Text, [quoted(true), numbervars(true)]),
    string_bytes(Text, Octets, utf8),
    length(Octets, Bytes).

value_shape(Value, Shape) :-
    (   var(Value) -> Shape = variable
    ;   is_dict(Value) -> Shape = dict
    ;   is_list(Value) -> Shape = list
    ;   compound(Value) -> functor(Value, Name, Arity), Shape = Name/Arity
    ;   atom(Value) -> Shape = atom
    ;   string(Value) -> Shape = string
    ;   number(Value) -> Shape = number
    ;   Shape = other
    ).

dict_value_default(Key, Dict, Default, Value) :-
    (   is_dict(Dict), get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

tool_api_exception(Phase, tool_fault(Fault), error(Error)) :-
    !,
    Error = tool_error{
                phase:Phase,
                kind:invalid_tool_operation,
                detail:Fault,
                message:"tool operation is invalid"
            }.
tool_api_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = tool_error{
                phase:Phase,
                kind:tool_runtime_error,
                exception:Safe,
                message:"tool operation failed"
            }.

invoke_exception(Exception, _, _, _, _, _, _, _) :-
    tool_control_exception(Exception),
    !,
    throw(Exception).
invoke_exception(tool_fault(Fault), error(Error), denied, unknown,
                 invalid_tool, 0, none, none) :-
    !,
    Error = tool_error{
                phase:invoke,
                kind:invalid_tool_operation,
                detail:Fault,
                message:"tool invocation is invalid"
            }.
invoke_exception(capability_fault(Fault), error(Error), denied, unknown,
                 invalid_capabilities, 0, none, none) :-
    !,
    Error = tool_error{
                phase:authorize,
                kind:invalid_capabilities,
                detail:Fault,
                message:"tool capability set is invalid"
            }.
invoke_exception(Exception, error(Error), denied, unknown,
                 runtime_error, 0, none, none) :-
    safe_exception(Exception, Safe),
    Error = tool_error{
                phase:invoke,
                kind:tool_runtime_error,
                exception:Safe,
                message:"tool invocation failed"
            }.

tool_control_exception(rlm_async_cancelled(_)).
tool_control_exception(rlm_cancelled(_)).
tool_control_exception(chain_cancelled(_)).
tool_control_exception(graph_cancelled(_)).
tool_control_exception(cancelled(_)).
tool_control_exception('$aborted').
tool_control_exception(abort).
tool_control_exception(error(Inner, _)) :-
    tool_control_exception(Inner).

safe_exception(Exception, Safe) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).
