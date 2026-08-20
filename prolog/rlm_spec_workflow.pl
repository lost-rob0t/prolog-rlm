:- module(rlm_spec_workflow,
          [ rlm_spec_workflow_ready/0,
            spec_plan_bind/4,
            spec_plan_execute/5,
            spec_workflow_compile/5,
            spec_workflow_run_async/3,
            spec_workflow_run/3,
            spec_workflow_resume_async/6,
            spec_workflow_resume/6
          ]).

/** <module> Optional graph composition for Spec/Plan/Execute/Verify

This module is deliberately thin. It does not schedule work or interpret a new
plan language. Existing rlm_plan/rlm_outcome execute plans; rlm_verify observes
and reconciles evidence; rlm_graph supplies the bounded repair loop and durable
resume semantics. The graph id includes the frozen Spec fingerprint so a
checkpoint cannot be resumed under a different goal merely because a newer Spec
exists.
*/

:- use_module(library(option)).
:- use_module(rlm_assertion).
:- use_module(rlm_graph, []).
:- use_module(rlm_outcome, []).
:- use_module(rlm_plan, []).
:- use_module(rlm_spec).
:- use_module(rlm_verify).

rlm_spec_workflow_ready.

/* Independent Plan composition ---------------------------------------- */

spec_plan_bind(Frozen0, Plan0, ProjectState0, Outcome) :-
    catch(( validate_frozen(Frozen0, Frozen),
            require_acyclic(Plan0, plan),
            require_acyclic(ProjectState0, project_state),
            canonical_workflow_data(ProjectState0, ProjectState),
            canonical_workflow_data(Plan0, PlanInput),
            rlm_plan:plan_normalize(PlanInput, PlanOutcome),
            require_plan_outcome(PlanOutcome, Plan),
            SpecPlan = spec_plan{spec_ref:Frozen.ref,
                                 project_state:ProjectState,
                                 plan:Plan},
            Outcome = ok(SpecPlan)
          ),
          Exception,
          workflow_exception(plan_bind, Exception, Outcome)).

spec_plan_execute(SpecPlan0, Capabilities, Options, Inputs, Outcome) :-
    catch(( normalize_spec_plan(SpecPlan0, SpecPlan),
            rlm_outcome:plan_outcome(SpecPlan.plan,
                                     Capabilities,
                                     Options,
                                     Inputs,
                                     Execution),
            Outcome = ok(spec_execution{
                             spec_ref:SpecPlan.spec_ref,
                             plan:SpecPlan,
                             outcome:Execution
                         })
          ),
          Exception,
          workflow_exception(execute, Exception, Outcome)).

/* Full optional composition over rlm_graph ---------------------------- */

spec_workflow_compile(Frozen0, AssertionRegistry, Config0, Options, Outcome) :-
    catch(( validate_frozen(Frozen0, Frozen),
            require_options(Options),
            require_acyclic(Config0, workflow_config),
            normalize_workflow_config(Config0, Config),
            validate_workflow_plan_source(Config),
            assertion_registry_validate(AssertionRegistry, RegistryOutcome),
            require_assertion_registry_outcome(RegistryOutcome, NormalizedRegistry),
            workflow_graph(Frozen,
                           NormalizedRegistry,
                           Config,
                           GraphSpec,
                           GraphRegistry),
            rlm_graph:graph_compile(GraphSpec,
                                    GraphRegistry,
                                    Options,
                                    GraphOutcome),
            require_graph_outcome(GraphOutcome, CompiledGraph),
            Outcome = ok(compiled_spec_workflow{
                             spec_ref:Frozen.ref,
                             graph:CompiledGraph
                         })
          ),
          Exception,
          workflow_exception(compile, Exception, Outcome)).

spec_workflow_run_async(Workflow0, Options, Future) :-
    normalize_compiled_workflow(Workflow0, Workflow),
    rlm_graph:graph_run_async(Workflow.graph, _{}, Options, Future).

spec_workflow_run(Workflow0, Options, Outcome) :-
    normalize_compiled_workflow(Workflow0, Workflow),
    rlm_graph:graph_run(Workflow.graph, _{}, Options, Outcome).

spec_workflow_resume_async(Workflow0, Backend, RunId, Resume, Options, Future) :-
    normalize_compiled_workflow(Workflow0, Workflow),
    rlm_graph:graph_resume_async(Workflow.graph,
                                 Backend,
                                 RunId,
                                 Resume,
                                 Options,
                                 Future).

spec_workflow_resume(Workflow0, Backend, RunId, Resume, Options, Outcome) :-
    normalize_compiled_workflow(Workflow0, Workflow),
    rlm_graph:graph_resume(Workflow.graph,
                           Backend,
                           RunId,
                           Resume,
                           Options,
                           Outcome).

workflow_graph(Frozen, AssertionRegistry, Config, Spec, Registry) :-
    atom_concat(spec_workflow_, Frozen.ref.fingerprint, GraphId),
    Schema = [ field(frozen_spec, any, Frozen, replace),
               field(spec_ref, any, Frozen.ref, replace),
               field(plan, any, none, replace),
               field(execution, any, none, replace),
               field(observation_sources, any, Config.observation_sources, replace),
               field(observations, list, [], replace),
               field(observation_error, any, none, replace),
               field(verification, any, none, replace),
               field(repairs, integer, 0, replace),
               field(status, atom, pending, replace)
             ],
    Nodes = [ node(prepare, prepare_handler),
              node(execute, execute_handler),
              node(observe, observe_handler),
              node(verify, verify_handler),
              node(repair, repair_handler),
              node(finish, finish_handler)
            ],
    Edges = [ edge(start, prepare),
              edge(prepare, execute),
              edge(execute, observe),
              edge(observe, verify),
              conditional(verify,
                          verification_router,
                          [ route(pass, finish),
                            route(repair, repair),
                            route(reject, finish)
                          ]),
              edge(repair, execute),
              edge(finish, end)
            ],
    Spec = graph(GraphId, Schema, Nodes, Edges),
    Registry = [ handler(prepare_handler,
                         rlm_spec_workflow:workflow_prepare(Config)),
                 handler(execute_handler,
                         rlm_spec_workflow:workflow_execute(Config)),
                 handler(observe_handler,
                         rlm_spec_workflow:workflow_observe(AssertionRegistry,
                                                            Config)),
                 handler(verify_handler,
                         rlm_spec_workflow:workflow_verify(AssertionRegistry)),
                 handler(repair_handler,
                         rlm_spec_workflow:workflow_repair(Config)),
                 handler(finish_handler,
                         rlm_spec_workflow:workflow_finish),
                 router(verification_router,
                        rlm_spec_workflow:workflow_route(Config))
               ].

workflow_prepare(Config, State, _, update(_{plan:SpecPlan,
                                           status:planned})) :-
    Frozen = State.frozen_spec,
    workflow_plan(Config, Frozen, Plan0, ProjectState),
    spec_plan_bind(Frozen, Plan0, ProjectState, PlanOutcome),
    require_spec_plan_outcome(PlanOutcome, SpecPlan).

workflow_plan(Config, _, Plan, ProjectState) :-
    Config.plan \== none,
    !,
    Plan = Config.plan,
    ProjectState = Config.planning_context.
workflow_plan(Config, Frozen, Plan, ProjectState) :-
    Planner = Config.planner,
    Planner \== none,
    call(Planner, Frozen, Config.planning_context, Plan0, ProjectState0),
    canonical_workflow_data(Plan0, Plan),
    canonical_workflow_data(ProjectState0, ProjectState).

workflow_execute(Config, State, Context, update(Patch)) :-
    SpecPlan = State.plan,
    workflow_execution(Config, State.frozen_spec, SpecPlan, Context, Execution),
    refresh_observation_sources(Config,
                                State.frozen_spec,
                                SpecPlan,
                                Execution,
                                State.observation_sources,
                                Sources),
    Patch = _{execution:Execution,
              observation_sources:Sources,
              observation_error:none,
              observations:[],
              verification:none,
              status:executed}.

workflow_execution(Config, _, SpecPlan, _, Execution) :-
    Config.executor == plan,
    !,
    spec_plan_execute(SpecPlan,
                      Config.capabilities,
                      Config.plan_options,
                      Config.inputs,
                      ExecutionOutcome),
    require_spec_execution_outcome(ExecutionOutcome, Execution).
workflow_execution(Config, Frozen, SpecPlan, Context, Execution) :-
    Executor = Config.executor,
    Executor \== plan,
    call(Executor, Frozen, SpecPlan, Context, Execution0),
    canonical_workflow_data(Execution0, Execution).

refresh_observation_sources(Config, _, _, _, Sources, Sources) :-
    Config.source_refresher == none,
    !.
refresh_observation_sources(Config,
                            Frozen,
                            SpecPlan,
                            Execution,
                            Sources0,
                            Sources) :-
    SourceRefresher = Config.source_refresher,
    call(SourceRefresher,
         Frozen,
         SpecPlan,
         Execution,
         Sources0,
         Sources0Raw),
    canonical_workflow_data(Sources0Raw, Sources).

workflow_observe(AssertionRegistry, Config, State, _, update(Patch)) :-
    spec_observe_execute(State.frozen_spec,
                         State.observation_sources,
                         AssertionRegistry,
                         Config.observe_options,
                         ObserveOutcome),
    (   ObserveOutcome = ok(Observations)
    ->  Patch = _{observations:Observations,
                  observation_error:none,
                  status:observed}
    ;   ObserveOutcome = error(Error),
        Patch = _{observations:[],
                  observation_error:Error,
                  status:observation_failed}
    ).

workflow_verify(AssertionRegistry, State, _, update(Patch)) :-
    spec_verify(State.frozen_spec,
                State.observations,
                AssertionRegistry,
                VerifyOutcome),
    (   VerifyOutcome = ok(Report)
    ->  Verification = Report
    ;   VerifyOutcome = error(Error),
        Verification = verification_report{
                           spec_ref:State.spec_ref,
                           status:rejected,
                           requirements:[],
                           observations:State.observations,
                           evidence_refs:[],
                           provenance:verification_provenance{
                                          verifier:rlm_verify,
                                          version:1,
                                          mode:pure,
                                          error:Error
                                      }
                       }
    ),
    Patch = _{verification:Verification,
              status:verified}.

workflow_route(_, State, pass) :-
    State.verification.status == passed,
    !.
workflow_route(Config, State, repair) :-
    Config.repair \== none,
    State.repairs < Config.max_repairs,
    !.
workflow_route(_, _, reject).

workflow_repair(Config, State, Context,
                update(_{plan:SpecPlan,
                         repairs:NextRepairs,
                         status:replanned})) :-
    Repair = Config.repair,
    Repair \== none,
    call(Repair,
         State.frozen_spec,
         State.verification,
         State.execution,
         State.plan,
         Context,
         NewPlanRaw),
    canonical_workflow_data(NewPlanRaw, NewPlan0),
    ProjectState = State.plan.project_state,
    spec_plan_bind(State.frozen_spec,
                   NewPlan0,
                   ProjectState,
                   PlanOutcome),
    require_spec_plan_outcome(PlanOutcome, SpecPlan),
    SpecPlan.spec_ref == State.spec_ref,
    NextRepairs is State.repairs+1.

workflow_finish(State, _, update(_{status:Status})) :-
    (   State.verification.status == passed
    ->  Status = passed
    ;   Status = rejected
    ).

/* Config --------------------------------------------------------------- */

normalize_workflow_config(Input, Config) :-
    is_dict(Input),
    !,
    allowed_keys(Input,
                 [plan,planner,planning_context,executor,capabilities,
                  plan_options,inputs,observation_sources,source_refresher,
                  observe_options,repair,max_repairs],
                 workflow_config),
    dict_default(Input, plan, none, Plan0),
    canonical_workflow_data(Plan0, Plan),
    dict_default(Input, planner, none, Planner),
    require_callable_or_none(Planner, planner),
    dict_default(Input, planning_context, none, PlanningContext0),
    canonical_workflow_data(PlanningContext0, PlanningContext),
    dict_default(Input, executor, plan, Executor),
    require_executor(Executor),
    dict_default(Input, capabilities, [], Capabilities0),
    canonical_workflow_data(Capabilities0, Capabilities),
    dict_default(Input, plan_options, [], PlanOptions),
    require_options(PlanOptions),
    dict_default(Input, inputs, _{}, Inputs0),
    canonical_workflow_data(Inputs0, Inputs),
    dict_default(Input, observation_sources, [], Sources0),
    canonical_workflow_data(Sources0, Sources),
    dict_default(Input, source_refresher, none, SourceRefresher),
    require_callable_or_none(SourceRefresher, source_refresher),
    dict_default(Input, observe_options, [], ObserveOptions),
    require_options(ObserveOptions),
    dict_default(Input, repair, none, Repair),
    require_callable_or_none(Repair, repair),
    dict_default(Input, max_repairs, 2, MaxRepairs),
    require_nonnegative_integer(MaxRepairs, max_repairs),
    Config = spec_workflow_config{
                 plan:Plan,
                 planner:Planner,
                 planning_context:PlanningContext,
                 executor:Executor,
                 capabilities:Capabilities,
                 plan_options:PlanOptions,
                 inputs:Inputs,
                 observation_sources:Sources,
                 source_refresher:SourceRefresher,
                 observe_options:ObserveOptions,
                 repair:Repair,
                 max_repairs:MaxRepairs
             }.
normalize_workflow_config(Input, _) :-
    throw(workflow_fault(invalid_config(Input))).

validate_workflow_plan_source(Config) :-
    (   Config.plan \== none, Config.planner == none
    ->  true
    ;   Config.plan == none, Config.planner \== none
    ->  true
    ;   Config.plan \== none, Config.planner \== none
    ->  throw(workflow_fault(ambiguous_plan_source))
    ;   throw(workflow_fault(missing_plan_source))
    ).

require_executor(plan) :- !.
require_executor(Executor) :- require_callable(Executor, executor).

/* Shapes --------------------------------------------------------------- */

normalize_spec_plan(Input, SpecPlan) :-
    is_dict(Input),
    allowed_keys(Input, [spec_ref,project_state,plan], spec_plan),
    require_dict_key(Input, spec_ref, SpecRef),
    require_ground(SpecRef, spec_ref),
    require_dict_key(Input, project_state, ProjectState0),
    canonical_workflow_data(ProjectState0, ProjectState),
    require_dict_key(Input, plan, Plan0),
    canonical_workflow_data(Plan0, PlanInput),
    rlm_plan:plan_normalize(PlanInput, PlanOutcome),
    require_plan_outcome(PlanOutcome, Plan),
    SpecPlan = spec_plan{spec_ref:SpecRef,
                         project_state:ProjectState,
                         plan:Plan}.

normalize_compiled_workflow(Input, Workflow) :-
    is_dict(Input),
    allowed_keys(Input, [spec_ref,graph], compiled_spec_workflow),
    require_dict_key(Input, spec_ref, SpecRef),
    normalize_spec_ref(SpecRef, NormalizedSpecRef),
    require_dict_key(Input, graph, Graph),
    require_compiled_graph_identity(Graph, NormalizedSpecRef),
    Workflow = compiled_spec_workflow{spec_ref:NormalizedSpecRef, graph:Graph}.

normalize_spec_ref(SpecRef, Normalized) :-
    is_dict(SpecRef),
    allowed_keys(SpecRef, [series,version,fingerprint], spec_ref),
    require_dict_key(SpecRef, series, Series),
    atom(Series),
    Series \== '',
    require_dict_key(SpecRef, version, Version),
    integer(Version),
    Version > 0,
    require_dict_key(SpecRef, fingerprint, Fingerprint),
    atom(Fingerprint),
    Fingerprint \== '',
    Normalized = spec_ref{series:Series,
                          version:Version,
                          fingerprint:Fingerprint}.

require_compiled_graph_identity(Graph, SpecRef) :-
    is_dict(Graph),
    get_dict(kind, Graph, rlm_graph),
    get_dict(id, Graph, GraphId),
    atom_concat(spec_workflow_, SpecRef.fingerprint, ExpectedGraphId),
    (   GraphId == ExpectedGraphId
    ->  true
    ;   throw(workflow_fault(graph_spec_mismatch(GraphId, ExpectedGraphId)))
    ).

validate_frozen(Frozen0, Frozen) :-
    spec_fingerprint(Frozen0, _),
    Frozen = Frozen0.

/* Canonical host data -------------------------------------------------- */

canonical_workflow_data(Value0, _) :-
    var(Value0),
    !,
    throw(workflow_fault(non_ground_workflow_data)).
canonical_workflow_data(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_workflow_pair, Pairs0, Pairs),
    dict_pairs(Value, workflow_data, Pairs).
canonical_workflow_data(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_workflow_data, Values0, Values).
canonical_workflow_data(Value0, Value) :-
    compound(Value0),
    !,
    Value0 =.. [Functor|Args0],
    maplist(canonical_workflow_data, Args0, Args),
    Value =.. [Functor|Args].
canonical_workflow_data(Value, Value) :-
    atomic(Value),
    !.
canonical_workflow_data(Value, _) :-
    throw(workflow_fault(unsupported_workflow_data(Value))).

canonical_workflow_pair(Key-Value0, Key-Value) :-
    atom(Key),
    !,
    canonical_workflow_data(Value0, Value).
canonical_workflow_pair(Key-_, _) :-
    throw(workflow_fault(invalid_workflow_dict_key(Key))).

/* Helpers -------------------------------------------------------------- */

allowed_keys(Dict, Allowed, Name) :-
    dict_pairs(Dict, _, Pairs),
    forall(member(Key-_, Pairs),
           ( memberchk(Key, Allowed)
           -> true
           ; throw(workflow_fault(unknown_key(Name, Key)))
           )).

require_dict_key(Dict, Key, Value) :-
    ( get_dict(Key, Dict, Value) -> true ; throw(workflow_fault(missing_key(Key))) ).

dict_default(Dict, Key, Default, Value) :-
    ( get_dict(Key, Dict, Found) -> Value = Found ; Value = Default ).

require_options(Options) :- is_list(Options), !.
require_options(Options) :- throw(workflow_fault(invalid_options(Options))).

require_acyclic(Value, _) :- acyclic_term(Value), !.
require_acyclic(_, Name) :- throw(workflow_fault(cyclic(Name))).

require_ground(Value, _) :- ground(Value), !.
require_ground(Value, Name) :- throw(workflow_fault(non_ground(Name, Value))).

require_callable(Value, _) :- callable(Value), !.
require_callable(Value, Name) :- throw(workflow_fault(invalid_callable(Name, Value))).

require_callable_or_none(none, _) :- !.
require_callable_or_none(Value, Name) :- require_callable(Value, Name).

require_nonnegative_integer(Value, _) :- integer(Value), Value >= 0, !.
require_nonnegative_integer(Value, Name) :-
    throw(workflow_fault(invalid_nonnegative_integer(Name, Value))).

require_assertion_registry_outcome(ok(Registry), Registry) :- !.
require_assertion_registry_outcome(error(Error), _) :-
    throw(workflow_fault(assertion_registry(Error))).

require_plan_outcome(ok(Plan), Plan) :- !.
require_plan_outcome(error(Error), _) :- throw(workflow_fault(plan(Error))).

require_graph_outcome(ok(Graph), Graph) :- !.
require_graph_outcome(error(Error), _) :- throw(workflow_fault(graph(Error))).

require_spec_plan_outcome(ok(Plan), Plan) :- !.
require_spec_plan_outcome(error(Error), _) :- throw(workflow_fault(spec_plan(Error))).

require_spec_execution_outcome(ok(Execution), Execution) :- !.
require_spec_execution_outcome(error(Error), _) :- throw(workflow_fault(spec_execution(Error))).

workflow_exception(Phase, workflow_fault(Detail), error(Error)) :-
    !,
    Error = spec_workflow_error{phase:Phase,
                                kind:spec_workflow_error,
                                detail:Detail,
                                message:"spec workflow rejected input"}.
workflow_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = spec_workflow_error{phase:Phase,
                                kind:exception,
                                exception:Safe,
                                message:"spec workflow raised an exception"}.
