:- module(rlm_spec_plan,
          [ rlm_spec_plan_ready/0,
            plan_seed_from_spec/3,
            plan_refine/4,
            plan_validate_against_spec/5,
            plan_replan/5,
            plan_prepare_from_spec/6
          ]).

/** <module> Spec-seeded typed plan API

This module makes the Frozen Spec -> seed -> refine -> whole-plan validation
boundary explicit without introducing another scheduler or plan language.

The Frozen Spec remains authoritative for desired state. Seeds and replans are
non-executable planning artifacts until a trusted refiner produces a candidate
plan and the existing rlm_plan validator accepts it.
*/

:- use_module(rlm_plan, []).
:- use_module(rlm_spec).
:- use_module(rlm_spec_workflow, [spec_plan_bind/4]).

rlm_spec_plan_ready.

plan_seed_from_spec(Frozen0, PlanningContext0, Outcome) :-
    catch(( validate_frozen(Frozen0, Frozen),
            require_closed(PlanningContext0, planning_context),
            planning_goals(Frozen.requirements, Goals),
            Seed = plan_seed{
                       schema_version:1,
                       spec_ref:Frozen.ref,
                       subject:Frozen.subject,
                       goals:Goals,
                       requirements:Frozen.requirements,
                       invariants:Frozen.invariants,
                       output_contract:Frozen.output_contract,
                       planning_context:PlanningContext0
                   },
            Outcome = ok(Seed)
          ),
          Exception,
          api_exception(seed, Exception, Outcome)).

plan_refine(Frozen0, Seed0, Refiner, Outcome) :-
    catch(( validate_frozen(Frozen0, Frozen),
            normalize_seed(Seed0, Seed),
            require_same_spec_ref(Frozen.ref, Seed.spec_ref),
            require_refiner(Refiner),
            call(Refiner, Frozen, Seed, Candidate0),
            normalize_candidate(Candidate0, Candidate),
            spec_plan_bind(Frozen,
                           Candidate.plan,
                           Candidate.project_state,
                           BindOutcome),
            require_ok(BindOutcome, SpecPlan),
            Outcome = ok(SpecPlan)
          ),
          Exception,
          api_exception(refine, Exception, Outcome)).

plan_validate_against_spec(Frozen0,
                           SpecPlan0,
                           Capabilities,
                           Budget,
                           Outcome) :-
    catch(( validate_frozen(Frozen0, Frozen),
            normalize_bound_spec_plan(Frozen, SpecPlan0, SpecPlan),
            rlm_plan:plan_validate(SpecPlan.plan,
                                   Capabilities,
                                   Budget,
                                   ValidationOutcome),
            require_ok(ValidationOutcome, Validation),
            Validated = validated_spec_plan{
                            spec_ref:Frozen.ref,
                            project_state:SpecPlan.project_state,
                            validation:Validation
                        },
            Outcome = ok(Validated)
          ),
          Exception,
          api_exception(validate, Exception, Outcome)).

plan_replan(Frozen0, ExecutionState0, PlannerInput0, Refiner, Outcome) :-
    catch(( validate_frozen(Frozen0, Frozen),
            require_closed(ExecutionState0, execution_state),
            execution_spec_ref(ExecutionState0, ExecutionRef),
            require_same_spec_ref(Frozen.ref, ExecutionRef),
            require_closed(PlannerInput0, planner_input),
            require_refiner(Refiner),
            Context = replan_context{
                          schema_version:1,
                          spec_ref:Frozen.ref,
                          execution_state:ExecutionState0,
                          planner_input:PlannerInput0
                      },
            call(Refiner, Frozen, Context, Candidate0),
            normalize_candidate(Candidate0, Candidate),
            spec_plan_bind(Frozen,
                           Candidate.plan,
                           Candidate.project_state,
                           BindOutcome),
            require_ok(BindOutcome, SpecPlan),
            Outcome = ok(SpecPlan)
          ),
          Exception,
          api_exception(replan, Exception, Outcome)).

plan_prepare_from_spec(Frozen,
                       PlanningContext,
                       Refiner,
                       Capabilities,
                       Budget,
                       Outcome) :-
    plan_seed_from_spec(Frozen, PlanningContext, SeedOutcome),
    (   SeedOutcome = ok(Seed)
    ->  plan_refine(Frozen, Seed, Refiner, RefineOutcome),
        continue_prepare_validation(Frozen,
                                    Seed,
                                    RefineOutcome,
                                    Capabilities,
                                    Budget,
                                    Outcome)
    ;   Outcome = SeedOutcome
    ).

continue_prepare_validation(Frozen,
                            Seed,
                            ok(SpecPlan),
                            Capabilities,
                            Budget,
                            Outcome) :-
    !,
    plan_validate_against_spec(Frozen,
                               SpecPlan,
                               Capabilities,
                               Budget,
                               ValidationOutcome),
    (   ValidationOutcome = ok(Validation)
    ->  Outcome = ok(spec_plan_preparation{
                         spec_ref:Seed.spec_ref,
                         seed:Seed,
                         spec_plan:SpecPlan,
                         validation:Validation
                     })
    ;   Outcome = ValidationOutcome
    ).
continue_prepare_validation(_, _, error(Error), _, _, error(Error)).

planning_goals(Requirements, Goals) :-
    maplist(requirement_goal, Requirements, Goals).

requirement_goal(Requirement,
                 plan_goal{requirement_id:Requirement.id,
                           severity:Requirement.severity,
                           evidence_policy:Requirement.evidence_policy}).

normalize_seed(Input, Seed) :-
    is_dict(Input),
    require_exact_keys(Input,
                       [schema_version,spec_ref,subject,goals,requirements,
                        invariants,output_contract,planning_context],
                       plan_seed),
    Input.schema_version == 1,
    require_closed(Input, plan_seed),
    Seed = Input.

normalize_candidate(Input, Candidate) :-
    is_dict(Input),
    require_exact_keys(Input, [plan,project_state], plan_candidate),
    require_closed(Input.plan, plan),
    require_closed(Input.project_state, project_state),
    Candidate = plan_candidate{plan:Input.plan,
                               project_state:Input.project_state}.

normalize_bound_spec_plan(Frozen, Input, SpecPlan) :-
    is_dict(Input),
    require_exact_keys(Input, [spec_ref,project_state,plan], spec_plan),
    require_same_spec_ref(Frozen.ref, Input.spec_ref),
    require_closed(Input.project_state, project_state),
    require_closed(Input.plan, plan),
    spec_plan_bind(Frozen,
                   Input.plan,
                   Input.project_state,
                   BindOutcome),
    require_ok(BindOutcome, SpecPlan).

execution_spec_ref(State, Ref) :-
    is_dict(State),
    get_dict(spec_ref, State, Ref),
    !.
execution_spec_ref(State, Ref) :-
    is_dict(State),
    get_dict(plan, State, Plan),
    is_dict(Plan),
    get_dict(spec_ref, Plan, Ref),
    !.
execution_spec_ref(_, _) :-
    throw(spec_plan_api_fault(missing_execution_spec_ref)).

validate_frozen(Frozen, Frozen) :-
    spec_fingerprint(Frozen, _).

require_refiner(Refiner) :-
    callable(Refiner),
    ground(Refiner),
    !.
require_refiner(Refiner) :-
    throw(spec_plan_api_fault(invalid_refiner(Refiner))).

require_same_spec_ref(Expected, Actual) :-
    (   Expected == Actual
    ->  true
    ;   throw(spec_plan_api_fault(spec_ref_mismatch(Expected, Actual)))
    ).

require_closed(Value, _) :-
    ground(Value),
    acyclic_term(Value),
    !.
require_closed(Value, Field) :-
    throw(spec_plan_api_fault(non_closed_data(Field, Value))).

require_exact_keys(Dict, Expected0, Kind) :-
    dict_keys(Dict, Keys0),
    msort(Keys0, Keys),
    msort(Expected0, Expected),
    (   Keys == Expected
    ->  true
    ;   throw(spec_plan_api_fault(invalid_shape(Kind, Keys)))
    ).

require_ok(ok(Value), Value) :- !.
require_ok(error(Error), _) :-
    throw(spec_plan_api_fault(dependency_failed(Error))).

api_exception(Phase,
              spec_plan_api_fault(Fault),
              error(spec_plan_api_error{
                        phase:Phase,
                        kind:rejected,
                        detail:Fault,
                        message:"Spec-seeded plan API rejected the request"
                    })) :-
    !.
api_exception(Phase,
              Exception,
              error(spec_plan_api_error{
                        phase:Phase,
                        kind:exception,
                        exception:Safe,
                        message:"Spec-seeded plan API raised an exception"
                    })) :-
    term_string(Exception, Safe, [quoted(true),numbervars(true)]).
