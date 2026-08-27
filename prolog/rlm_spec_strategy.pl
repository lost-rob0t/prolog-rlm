:- module(rlm_spec_strategy,
          [ spec_strategy_bind/5,
            rlm_spec_strategy_ready/0,
            spec_strategy_execute/5,
            spec_strategy_workflow_compile/5,
            spec_strategy_workflow_run_async/3,
            spec_strategy_workflow_run/3,
            spec_strategy_workflow_resume_async/6,
            spec_strategy_workflow_resume/6
          ]).

/** <module> Optional Spec composition over direct and typed strategies

This module selects an existing executor and reuses rlm_graph for bounded
Observe/Verify/Repair. It is not a scheduler, verifier, or plan interpreter.
*/

:- use_module(rlm_assertion).
:- use_module(rlm_graph, []).
:- use_module(rlm_spec).
:- use_module(rlm_spec_workflow, [spec_plan_bind/4,spec_plan_execute/5]).
:- use_module(rlm_verify).

rlm_spec_strategy_ready.

spec_strategy_bind(Frozen0, Mode, Payload0, ProjectState0, Outcome) :-
    catch(( validate_frozen(Frozen0, Frozen),
            normalize_mode(Mode),
            closed_data(Payload0, Payload),
            closed_data(ProjectState0, ProjectState),
            normalize_strategy_payload(Mode, Frozen, Payload, ProjectState,
                                       NormalizedPayload),
            Outcome = ok(spec_strategy{spec_ref:Frozen.ref,
                                       mode:Mode,
                                       payload:NormalizedPayload,
                                       project_state:ProjectState})
          ),
          Exception,
          strategy_exception(bind, Exception, Outcome)).

spec_strategy_execute(Frozen0, Strategy0, Config0, Context, Outcome) :-
    catch(( validate_frozen(Frozen0, Frozen),
            normalize_strategy(Strategy0, Strategy),
            Strategy.spec_ref == Frozen.ref,
            normalize_execution_config(Config0, Config),
            execute_strategy(Frozen, Strategy, Config, Context, Raw),
            Outcome = ok(strategy_execution{spec_ref:Frozen.ref,
                                             strategy:Strategy,
                                             mode:Strategy.mode,
                                             outcome:Raw})
          ),
          Exception,
          strategy_exception(execute, Exception, Outcome)).

execute_strategy(Frozen, Strategy, Config, _Context, Raw) :-
    Strategy.mode == typed_plan,
    !,
    spec_plan_bind(Frozen,
                   Strategy.payload,
                   Strategy.project_state,
                   PlanOutcome),
    require_ok(PlanOutcome, SpecPlan),
    spec_plan_execute(SpecPlan,
                      Config.capabilities,
                      Config.plan_options,
                      Config.inputs,
                      ExecuteOutcome),
    require_ok(ExecuteOutcome, Raw).
execute_strategy(Frozen, Strategy, Config, Context, Raw) :-
    Strategy.mode == direct,
    Runner = Config.direct_runner,
    ( Runner == none
    -> throw(strategy_fault(missing_direct_runner))
    ; call(Runner,
           Frozen,
           Strategy.payload,
           Strategy.project_state,
           Context,
           Raw0),
      closed_data(Raw0, Raw)
    ).

spec_strategy_workflow_compile(Frozen0, AssertionRegistry, Config0, Options,
                               Outcome) :-
    catch(( validate_frozen(Frozen0, Frozen),
            require_list(Options, options),
            normalize_workflow_config(Config0, Config),
            assertion_registry_validate(AssertionRegistry, RegistryOutcome),
            require_ok(RegistryOutcome, _),
            strategy_graph(Frozen, AssertionRegistry, Config,
                           GraphSpec, GraphRegistry),
            rlm_graph:graph_compile(GraphSpec, GraphRegistry, Options,
                                    GraphOutcome),
            require_ok(GraphOutcome, Graph),
            Outcome = ok(compiled_spec_strategy_workflow{
                             spec_ref:Frozen.ref,
                             graph:Graph})
          ),
          Exception,
          strategy_exception(compile, Exception, Outcome)).

spec_strategy_workflow_run_async(Workflow0, Options, Future) :-
    normalize_compiled(Workflow0, Workflow),
    rlm_graph:graph_run_async(Workflow.graph, strategy_input{}, Options, Future).

spec_strategy_workflow_run(Workflow0, Options, Outcome) :-
    normalize_compiled(Workflow0, Workflow),
    rlm_graph:graph_run(Workflow.graph, strategy_input{}, Options, Outcome).

spec_strategy_workflow_resume_async(Workflow0, Backend, RunId, Resume,
                                    Options, Future) :-
    normalize_compiled(Workflow0, Workflow),
    rlm_graph:graph_resume_async(Workflow.graph, Backend, RunId, Resume,
                                 Options, Future).

spec_strategy_workflow_resume(Workflow0, Backend, RunId, Resume,
                              Options, Outcome) :-
    normalize_compiled(Workflow0, Workflow),
    rlm_graph:graph_resume(Workflow.graph, Backend, RunId, Resume,
                           Options, Outcome).

strategy_graph(Frozen, AssertionRegistry, Config, Spec, Registry) :-
    atom_concat(spec_strategy_, Frozen.ref.fingerprint, GraphId),
    Schema = [field(frozen_spec,any,Frozen,replace),
              field(spec_ref,any,Frozen.ref,replace),
              field(strategy,any,none,replace),
              field(execution,any,none,replace),
              field(observation_sources,any,Config.observation_sources,replace),
              field(observations,list,[],replace),
              field(observation_error,any,none,replace),
              field(verification,any,none,replace),
              field(repairs,integer,0,replace),
              field(status,atom,pending,replace)],
    Nodes = [node(prepare,prepare_handler),
             node(execute,execute_handler),
             node(observe,observe_handler),
             node(verify,verify_handler),
             node(repair,repair_handler),
             node(finish,finish_handler)],
    Edges = [edge(start,prepare),
             edge(prepare,execute),
             edge(execute,observe),
             edge(observe,verify),
             conditional(verify,verification_router,
                         [route(pass,finish),route(repair,repair),
                          route(reject,finish)]),
             edge(repair,execute),
             edge(finish,end)],
    Spec = graph(GraphId, Schema, Nodes, Edges),
    Registry = [handler(prepare_handler,
                        rlm_spec_strategy:workflow_prepare(Config)),
                handler(execute_handler,
                        rlm_spec_strategy:workflow_execute(Config)),
                handler(observe_handler,
                        rlm_spec_strategy:workflow_observe(AssertionRegistry,
                                                           Config)),
                handler(verify_handler,
                        rlm_spec_strategy:workflow_verify(AssertionRegistry)),
                handler(repair_handler,
                        rlm_spec_strategy:workflow_repair(Config)),
                handler(finish_handler,rlm_spec_strategy:workflow_finish),
                router(verification_router,
                       rlm_spec_strategy:workflow_route(Config))].

workflow_prepare(Config, State, _, update(_{strategy:Strategy,status:prepared})) :-
    Candidate = Config.strategy,
    spec_strategy_bind(State.frozen_spec,
                       Candidate.mode,
                       Candidate.payload,
                       Config.project_state,
                       BindOutcome),
    require_ok(BindOutcome, Strategy).

workflow_execute(Config, State, Context, update(Patch)) :-
    ExecutionConfig = _{direct_runner:Config.direct_runner,
                        capabilities:Config.capabilities,
                        plan_options:Config.plan_options,
                        inputs:Config.inputs},
    spec_strategy_execute(State.frozen_spec,
                          State.strategy,
                          ExecutionConfig,
                          Context,
                          ExecuteOutcome),
    require_ok(ExecuteOutcome, Execution),
    refresh_sources(Config,
                    State.frozen_spec,
                    State.strategy,
                    Execution,
                    State.observation_sources,
                    Sources),
    Patch = _{execution:Execution,
              observation_sources:Sources,
              observations:[],
              observation_error:none,
              verification:none,
              status:executed}.

refresh_sources(Config, _, _, _, Sources, Sources) :-
    Config.source_refresher == none,
    !.
refresh_sources(Config, Frozen, Strategy, Execution, Sources0, Sources) :-
    Refresher = Config.source_refresher,
    call(Refresher,
         Frozen, Strategy, Execution, Sources0, Raw),
    closed_data(Raw, Sources).

workflow_observe(Registry, Config, State, _, update(Patch)) :-
    spec_observe_execute(State.frozen_spec,
                         State.observation_sources,
                         Registry,
                         Config.observe_options,
                         ObserveOutcome),
    ( ObserveOutcome = ok(Observations)
    -> Patch = _{observations:Observations,
                 observation_error:none,status:observed}
    ; ObserveOutcome = error(Error),
      Patch = _{observations:[],observation_error:Error,
                status:observation_failed}
    ).

workflow_verify(Registry, State, _, update(_{verification:Verification,
                                             status:verified})) :-
    spec_verify(State.frozen_spec, State.observations, Registry, VerifyOutcome),
    ( VerifyOutcome = ok(Verification)
    -> true
    ; VerifyOutcome = error(Error),
      Verification = verification_report{
                         spec_ref:State.spec_ref,status:rejected,
                         requirements:[],observations:State.observations,
                         evidence_refs:[],
                         provenance:verification_provenance{
                                        verifier:rlm_verify,version:1,
                                        mode:pure,error:Error}}
    ).

workflow_route(_, State, pass) :-
    State.verification.status == passed,
    !.
workflow_route(Config, State, repair) :-
    Config.repair \== none,
    State.repairs < Config.max_repairs,
    !.
workflow_route(_, _, reject).

workflow_repair(Config, State, Context,
                update(_{strategy:Strategy,repairs:Repairs,status:repaired})) :-
    Repair = Config.repair,
    call(Repair,
         State.frozen_spec,
         State.verification,
         State.execution,
         State.strategy,
         Context,
         Candidate0),
    normalize_candidate(Candidate0, Candidate),
    spec_strategy_bind(State.frozen_spec,
                       Candidate.mode,
                       Candidate.payload,
                       State.strategy.project_state,
                       BindOutcome),
    require_ok(BindOutcome, Strategy),
    Strategy.spec_ref == State.spec_ref,
    Repairs is State.repairs+1.

workflow_finish(State, _, update(_{status:Status})) :-
    ( State.verification.status == passed -> Status=passed ; Status=rejected ).

normalize_workflow_config(Input, Config) :-
    is_dict(Input),
    allowed_keys(Input,
                 [strategy,project_state,direct_runner,capabilities,
                  plan_options,inputs,observation_sources,source_refresher,
                  observe_options,repair,max_repairs],
                 workflow_config),
    require_key(Input, strategy, Candidate0),
    normalize_candidate(Candidate0, Candidate),
    dict_default(Input, project_state, none, ProjectState0),
    closed_data(ProjectState0, ProjectState),
    dict_default(Input, direct_runner, none, DirectRunner),
    callable_or_none(DirectRunner, direct_runner),
    dict_default(Input, capabilities, [], Capabilities0),
    closed_data(Capabilities0, Capabilities),
    dict_default(Input, plan_options, [], PlanOptions),
    require_list(PlanOptions, plan_options),
    dict_default(Input, inputs, strategy_input{}, Inputs0),
    closed_data(Inputs0, Inputs),
    dict_default(Input, observation_sources, [], Sources0),
    closed_data(Sources0, Sources),
    dict_default(Input, source_refresher, none, Refresher),
    callable_or_none(Refresher, source_refresher),
    dict_default(Input, observe_options, [], ObserveOptions),
    require_list(ObserveOptions, observe_options),
    dict_default(Input, repair, none, Repair),
    callable_or_none(Repair, repair),
    dict_default(Input, max_repairs, 2, MaxRepairs),
    ( integer(MaxRepairs), MaxRepairs >= 0 -> true
    ; throw(strategy_fault(invalid_max_repairs(MaxRepairs)))
    ),
    Config = strategy_workflow_config{
                 strategy:Candidate,project_state:ProjectState,
                 direct_runner:DirectRunner,capabilities:Capabilities,
                 plan_options:PlanOptions,inputs:Inputs,
                 observation_sources:Sources,source_refresher:Refresher,
                 observe_options:ObserveOptions,repair:Repair,
                 max_repairs:MaxRepairs}.
normalize_workflow_config(Input, _) :-
    throw(strategy_fault(invalid_config(Input))).

normalize_execution_config(Input, Config) :-
    is_dict(Input),
    allowed_keys(Input,[direct_runner,capabilities,plan_options,inputs],
                 execution_config),
    dict_default(Input,direct_runner,none,Runner),
    callable_or_none(Runner,direct_runner),
    dict_default(Input,capabilities,[],Caps0), closed_data(Caps0,Caps),
    dict_default(Input,plan_options,[],PlanOptions),
    require_list(PlanOptions,plan_options),
    dict_default(Input,inputs,strategy_input{},Inputs0),
    closed_data(Inputs0,Inputs),
    Config = strategy_execution_config{direct_runner:Runner,
                                       capabilities:Caps,
                                       plan_options:PlanOptions,
                                       inputs:Inputs}.

normalize_candidate(strategy(Mode, Payload0), Candidate) :-
    !,
    normalize_mode(Mode), closed_data(Payload0, Payload),
    Candidate = strategy_candidate{mode:Mode,payload:Payload}.
normalize_candidate(Input, Candidate) :-
    is_dict(Input),
    allowed_keys(Input,[mode,payload],strategy_candidate),
    require_key(Input,mode,Mode), normalize_mode(Mode),
    require_key(Input,payload,Payload0), closed_data(Payload0,Payload),
    Candidate = strategy_candidate{mode:Mode,payload:Payload}.

normalize_strategy(Input, Strategy) :-
    is_dict(Input),
    allowed_keys(Input,[spec_ref,mode,payload,project_state],spec_strategy),
    require_key(Input,spec_ref,SpecRef), closed_data(SpecRef,NormalizedRef),
    require_key(Input,mode,Mode), normalize_mode(Mode),
    require_key(Input,payload,Payload0), closed_data(Payload0,Payload),
    require_key(Input,project_state,Project0), closed_data(Project0,Project),
    Strategy = spec_strategy{spec_ref:NormalizedRef,mode:Mode,
                             payload:Payload,project_state:Project}.

normalize_strategy_payload(direct, _, Payload, _, Payload).
normalize_strategy_payload(typed_plan, Frozen, Payload, Project, Plan) :-
    spec_plan_bind(Frozen, Payload, Project, Outcome),
    require_ok(Outcome, SpecPlan),
    Plan = SpecPlan.plan.

normalize_mode(direct) :- !.
normalize_mode(typed_plan) :- !.
normalize_mode(Mode) :- throw(strategy_fault(invalid_strategy_mode(Mode))).

normalize_compiled(Input, Workflow) :-
    is_dict(Input),
    allowed_keys(Input,[spec_ref,graph],compiled_workflow),
    require_key(Input,spec_ref,SpecRef),
    require_key(Input,graph,Graph),
    is_dict(Graph), Graph.kind == rlm_graph,
    atom_concat(spec_strategy_, SpecRef.fingerprint, Expected),
    ( Graph.id == Expected -> true
    ; throw(strategy_fault(graph_spec_mismatch(Graph.id,Expected)))
    ),
    Workflow = compiled_spec_strategy_workflow{spec_ref:SpecRef,graph:Graph}.

validate_frozen(Frozen, Frozen) :- spec_fingerprint(Frozen, _).

closed_data(Value0, _) :- var(Value0), !,
    throw(strategy_fault(non_ground_data)).
closed_data(Value0, Value) :-
    is_dict(Value0), !,
    dict_pairs(Value0, Tag0, Pairs0),
    ( var(Tag0) -> Tag=rlm_anonymous_dict ; Tag=Tag0 ),
    maplist(closed_pair, Pairs0, Pairs),
    dict_pairs(Value, Tag, Pairs).
closed_data(Values0, Values) :- is_list(Values0), !,
    maplist(closed_data, Values0, Values).
closed_data(Value0, Value) :- compound(Value0), !,
    Value0 =.. [F|Args0], maplist(closed_data,Args0,Args), Value=..[F|Args].
closed_data(Value, Value) :- atomic(Value), !.

closed_pair(Key-Value0, Key-Value) :- atom(Key), closed_data(Value0,Value).

allowed_keys(Dict, Allowed, Kind) :-
    dict_keys(Dict, Keys), subtract(Keys,Allowed,Extra),
    ( Extra == [] -> true ; throw(strategy_fault(unexpected_fields(Kind,Extra))) ).
require_key(Dict, Key, Value) :-
    ( get_dict(Key,Dict,Value) -> true ; throw(strategy_fault(missing_field(Key))) ).
dict_default(Dict, Key, Default, Value) :-
    ( get_dict(Key,Dict,Found) -> Value=Found ; Value=Default ).
require_list(Value, _) :- is_list(Value), !.
require_list(Value, Field) :- throw(strategy_fault(invalid_list(Field,Value))).
callable_or_none(none, _) :- !.
callable_or_none(Value, _) :- callable(Value), ground(Value), !.
callable_or_none(Value, Field) :-
    throw(strategy_fault(invalid_callable(Field,Value))).

require_ok(ok(Value), Value) :- !.
require_ok(error(Error), _) :- throw(strategy_fault(dependency_failed(Error))).

strategy_exception(Phase, strategy_fault(Fault), error(Error)) :-
    !,
    Error = spec_strategy_error{phase:Phase,kind:strategy_rejected,
                                detail:Fault,
                                message:"Spec strategy composition was rejected"}.
strategy_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true),numbervars(true)]),
    Error = spec_strategy_error{phase:Phase,kind:exception,exception:Safe,
                                message:"Spec strategy composition raised an exception"}.
