:- module(rlm_completion,
          [ rlm_completion/4,
            llm_query/3,
            rlm_query/4,
            rlm_cancellation_token/1,
            rlm_cancel/1,
            default_completion_budget/1
          ]).

/** <module> Bounded recursive-language-model completion supervisor

The root model selects a typed symbolic plan. Prolog validates capabilities,
recursive depth, duplicate/cycle structure, model/tool/context budgets and
then executes the plan with the existing closed interpreter.

Recursive `rlm(...)` plan nodes remain symbolic plans. A depth-1 child may
contain a real `model(...)` call; the root planner and child call both use the
production provider registry in live execution. Deterministic tests may inject
trusted planner/model handlers through explicit options.
*/

:- use_module(library(lists)).
:- use_module(library(time)).
:- use_module(library(uuid)).
:- use_module(rlm_chain).
:- use_module(rlm_context).
:- use_module(rlm_plan).
:- use_module(rlm_tool).

:- dynamic cancellation_state/2.
:- dynamic cancellation_thread/2.

default_completion_budget(
    completion_budget{max_iterations:32,
                      max_recursion_depth:1,
                      max_concurrent_subcalls:2,
                      max_model_calls:4,
                      max_tool_calls:4,
                      max_context_ops:8,
                      max_total_tokens:8192,
                      max_cost_usd:0.25,
                      max_output_bytes:32768,
                      time_limit:30.0}).

/* -------------------------------------------------------------------------
 * Public API
 * ---------------------------------------------------------------------- */

rlm_completion(Query, Context, Options, Outcome) :-
    catch(rlm_completion_guarded(Query, Context, Options, Outcome),
          Exception,
          completion_exception(Exception, Outcome)).

llm_query(Prompt, Options, Outcome) :-
    catch(llm_query_guarded(Prompt, Options, Outcome),
          Exception,
          completion_exception(Exception, Outcome)).

rlm_query(Query, SubContext, Options, Outcome) :-
    catch(rlm_query_guarded(Query, SubContext, Options, Outcome),
          Exception,
          completion_exception(Exception, Outcome)).

rlm_cancellation_token(Token) :-
    uuid(Id, [version(4)]),
    atom_concat(cancel_, Id, Token),
    with_mutex(rlm_completion_cancel,
               ( retractall(cancellation_state(Token, _)),
                 assertz(cancellation_state(Token, active))
               )).

rlm_cancel(Token) :-
    with_mutex(rlm_completion_cancel,
               ( retractall(cancellation_state(Token, _)),
                 assertz(cancellation_state(Token, cancelled)),
                 findall(Thread,
                         cancellation_thread(Token, Thread),
                         Threads)
               )),
    maplist(signal_cancelled(Token), Threads).

signal_cancelled(Token, Thread) :-
    catch(thread_signal(Thread,
                        throw(error(rlm_cancelled(Token),
                                    context(rlm_completion,
                                            'completion cancelled')))),
          _,
          true).

/* -------------------------------------------------------------------------
 * Root completion
 * ---------------------------------------------------------------------- */

rlm_completion_guarded(Query0, Context, Options, Outcome) :-
    require_options(Options),
    text_string(Query0, Query),
    completion_budget(Options, Budget),
    cancellation_option(Options, Token, OwnToken),
    setup_call_cleanup(
        register_current_thread(Token),
        call_with_time_limit(Budget.time_limit,
                             completion_with_context(Query,
                                                     Context,
                                                     Options,
                                                     Budget,
                                                     Token,
                                                     Outcome)),
        cleanup_cancellation(Token, OwnToken)).

completion_with_context(Query, Context, Options, Budget, Token, Outcome) :-
    check_cancelled(Token),
    acquire_context(Context, ContextRef, ContextOwned),
    setup_call_cleanup(
        true,
        completion_with_handle(Query,
                               ContextRef,
                               Options,
                               Budget,
                               Token,
                               Outcome),
        cleanup_context(ContextRef, ContextOwned)).

completion_with_handle(Query, ContextRef, Options, Budget, Token, Outcome) :-
    context_metadata(ContextRef.handle, MetadataOutcome),
    require_context_metadata(MetadataOutcome, MetadataRef),
    provider_options(Options, ProviderName, Provider),
    capability_options(Options, ProviderName, Capabilities, ChildCapabilities),
    runtime_tools(Options, Capabilities, RuntimeTools, ToolSchemas),
    planner_prompt(Query,
                   MetadataRef.metadata,
                   Capabilities,
                   ChildCapabilities,
                   ToolSchemas,
                   Options,
                   Prompt),
    planner_attempts(Options, Attempts),
    PlannerTokenLimit is min(Budget.max_total_tokens,
                             planner_token_limit(Options)),
    planner_plan(Attempts,
                 Prompt,
                 ProviderName,
                 Provider,
                 Options,
                 PlannerTokenLimit,
                 Budget,
                 Token,
                 PlannerOutcome),
    completion_after_planner(PlannerOutcome,
                             Query,
                             ContextRef,
                             ProviderName,
                             Provider,
                             Capabilities,
                             ChildCapabilities,
                             RuntimeTools,
                             Options,
                             Budget,
                             Token,
                             Outcome).

completion_after_planner(error(Error), _, _, _, _, _, _, _, _, _, _,
                         error(Error)) :-
    !.
completion_after_planner(ok(Planner),
                         Query,
                         ContextRef,
                         ProviderName,
                         Provider,
                         Capabilities,
                         ChildCapabilities,
                         RuntimeTools,
                         Options,
                         Budget,
                         Token,
                         Outcome) :-
    check_cancelled(Token),
    validate_recursive_shape(Planner.plan, Budget, ShapeOutcome),
    validate_child_capability_plans(ShapeOutcome,
                                    ChildCapabilities,
                                    Budget,
                                    ChildOutcome),
    completion_after_shape(ChildOutcome,
                           Planner,
                           Query,
                           ContextRef,
                           ProviderName,
                           Provider,
                           Capabilities,
                           ChildCapabilities,
                           RuntimeTools,
                           Options,
                           Budget,
                           Token,
                           Outcome).

completion_after_shape(error(Error), _, _, _, _, _, _, _, _, _, _, _,
                       error(Error)) :-
    !.
completion_after_shape(ok(Shape),
                       Planner,
                       Query,
                       ContextRef,
                       ProviderName,
                       Provider,
                       Capabilities,
                       ChildCapabilities,
                       RuntimeTools,
                       Options,
                       Budget,
                       Token,
                       Outcome) :-
    RemainingCalls0 is Budget.max_model_calls-Planner.model_calls,
    (   RemainingCalls0 >= 0
    ->  true
    ;   throw(completion_fault(model_call_budget_exhausted))
    ),
    remaining_tokens(Budget.max_total_tokens,
                     Planner.usage.total_tokens,
                     RemainingTokens),
    count_model_steps(Planner.plan, PlanModelCalls),
    (   PlanModelCalls =< RemainingCalls0
    ->  true
    ;   throw(completion_fault(model_call_budget_exceeded(PlanModelCalls,
                                                          RemainingCalls0)))
    ),
    bound_plan_model_tokens(Planner.plan,
                            PlanModelCalls,
                            RemainingTokens,
                            BoundedPlan),
    plan_budget(Budget, RemainingCalls0, PlanBudget),
    context_runtime_options(Options, ContextOptions),
    RuntimeOptions = [ providers([provider_ref(ProviderName, Provider)]),
                       tools(RuntimeTools),
                       context_options(ContextOptions),
                       budget(PlanBudget)
                     ],
    check_cancelled(Token),
    plan_run(BoundedPlan,
             Capabilities,
             RuntimeOptions,
             _{context:ContextRef.handle, query:Query},
             PlanOutcome),
    completion_after_execution(PlanOutcome,
                               Planner,
                               BoundedPlan,
                               Shape,
                               ChildCapabilities,
                               Budget,
                               Token,
                               Outcome).

completion_after_execution(error(Error), _, _, _, _, _, _, error(Error)) :-
    !.
completion_after_execution(ok(Result),
                           Planner,
                           Plan,
                           Shape,
                           ChildCapabilities,
                           Budget,
                           Token,
                           Outcome) :-
    check_cancelled(Token),
    plan_usage(Result, UsageEvents, PlanUsage),
    usage_add(Planner.usage, PlanUsage, TotalUsage),
    budget_usage_check(Budget, TotalUsage, UsageBudgetOutcome),
    completion_finish(UsageBudgetOutcome,
                      Planner,
                      Plan,
                      Result,
                      Shape,
                      ChildCapabilities,
                      TotalUsage,
                      UsageEvents,
                      Outcome).

completion_finish(error(Error), _, _, _, _, _, _, _, error(Error)) :- !.
completion_finish(ok,
                  Planner,
                  Plan,
                  Result,
                  Shape,
                  ChildCapabilities,
                  TotalUsage,
                  UsageEvents,
                  ok(Completion)) :-
    planner_event(Planner, RootEvent),
    recursive_events(Plan, Result.vars, 0, RecursiveEvents),
    append([RootEvent|RecursiveEvents], UsageEvents, Events0),
    sort_events(Events0, Events),
    Completion = completion_result{
                     value:Result.value,
                     plan:Plan,
                     vars:Result.vars,
                     transitions:Result.transitions,
                     recursion:Shape,
                     child_capabilities:ChildCapabilities,
                     usage:TotalUsage,
                     trajectory:completion_trajectory{
                                    root_event:RootEvent,
                                    events:Events,
                                    reason:"root model selected validated symbolic plan"
                                }
                 }.

/* -------------------------------------------------------------------------
 * Direct model and recursive query primitives
 * ---------------------------------------------------------------------- */

llm_query_guarded(Prompt0, Options, Outcome) :-
    require_options(Options),
    text_string(Prompt0, Prompt),
    completion_budget(Options, Budget),
    cancellation_option(Options, Token, OwnToken),
    setup_call_cleanup(
        register_current_thread(Token),
        call_with_time_limit(Budget.time_limit,
                             llm_query_call(Prompt,
                                            Options,
                                            Budget,
                                            Token,
                                            Outcome)),
        cleanup_cancellation(Token, OwnToken)).

llm_query_call(Prompt, Options, Budget, Token, Outcome) :-
    check_cancelled(Token),
    provider_options(Options, ProviderName, Provider),
    TokenLimit is min(Budget.max_total_tokens,
                      planner_token_limit(Options)),
    model_request_options(Options, TokenLimit, RequestOptions),
    Request = model_request{messages:[message{role:user, content:Prompt}],
                            options:RequestOptions},
    call_model(Options, Provider, Request, ModelOutcome),
    direct_model_result(ModelOutcome,
                        ProviderName,
                        Budget,
                        Token,
                        Outcome).

direct_model_result(error(Error), _, _, _, error(Error)) :- !.
direct_model_result(ok(Response), ProviderName, Budget, Token, Outcome) :-
    check_cancelled(Token),
    response_usage(Response, Usage),
    budget_usage_check(Budget, Usage, BudgetOutcome),
    (   BudgetOutcome = error(Error)
    ->  Outcome = error(Error)
    ;   response_event(Response, 0, direct, ProviderName, Event),
        Outcome = ok(llm_result{response:Response,
                                usage:Usage,
                                trajectory:[Event]})
    ).

rlm_query_guarded(Query0, SubContext, Options, Outcome) :-
    require_options(Options),
    text_string(Query0, Query),
    completion_budget(Options, Budget),
    option_value(depth, Options, 1, Depth),
    require_nonnegative_integer(Depth, depth),
    (   Depth =< Budget.max_recursion_depth
    ->  true
    ;   throw(completion_fault(recursion_depth_exceeded(Depth,
                                                         Budget.max_recursion_depth)))
    ),
    acquire_context(SubContext, ContextRef, ContextOwned),
    setup_call_cleanup(
        true,
        rlm_query_with_context(Query,
                               ContextRef,
                               Depth,
                               Options,
                               Outcome),
        cleanup_context(ContextRef, ContextOwned)).

rlm_query_with_context(Query, ContextRef, Depth, Options, Outcome) :-
    context_metadata(ContextRef.handle, MetadataOutcome),
    require_context_metadata(MetadataOutcome, MetadataRef),
    format(string(Prompt),
           "Recursive subquery at depth ~d.\nGoal: ~s\nOpaque context metadata: ~q\nAnswer the goal without claiming access to context bytes not supplied in the prompt.",
           [Depth, Query, MetadataRef.metadata]),
    llm_query(Prompt, Options, ModelOutcome),
    rlm_query_result(ModelOutcome, Depth, Outcome).

rlm_query_result(error(Error), _, error(Error)) :- !.
rlm_query_result(ok(ModelResult), Depth, ok(Result)) :-
    Result = rlm_query_result{depth:Depth,
                              response:ModelResult.response,
                              usage:ModelResult.usage,
                              trajectory:ModelResult.trajectory}.

/* -------------------------------------------------------------------------
 * Planner
 * ---------------------------------------------------------------------- */

planner_plan(Attempts,
             Prompt,
             ProviderName,
             Provider,
             Options,
             TokenLimit,
             Budget,
             Token,
             Outcome) :-
    planner_plan_attempt(1,
                         Attempts,
                         Prompt,
                         ProviderName,
                         Provider,
                         Options,
                         TokenLimit,
                         Budget,
                         Token,
                         usage_summary{model_calls:0,
                                       prompt_tokens:0,
                                       completion_tokens:0,
                                       total_tokens:0,
                                       cost_usd:0.0,
                                       cost_known:true,
                                       tokens_known:true},
                         Outcome).

planner_plan_attempt(Attempt,
                     MaxAttempts,
                     Prompt,
                     ProviderName,
                     Provider,
                     Options,
                     TokenLimit,
                     Budget,
                     Token,
                     Usage0,
                     Outcome) :-
    check_cancelled(Token),
    (   Usage0.model_calls < Budget.max_model_calls
    ->  true
    ;   Outcome = error(completion_error{phase:planner,
                                         kind:model_call_budget_exhausted,
                                         message:"planner exhausted model-call budget"}),
        !
    ),
    remaining_tokens(Budget.max_total_tokens,
                     Usage0.total_tokens,
                     RemainingTokens),
    EffectiveLimit is max(1, min(TokenLimit, RemainingTokens)),
    planner_request_options(Options, EffectiveLimit, RequestOptions),
    Request = model_request{messages:[message{role:user, content:Prompt}],
                            options:RequestOptions},
    call_planner(Options, Provider, Request, PlannerCall),
    planner_call_result(PlannerCall,
                        ProviderName,
                        Attempt,
                        MaxAttempts,
                        Prompt,
                        Provider,
                        Options,
                        TokenLimit,
                        Budget,
                        Token,
                        Usage0,
                        Outcome).

planner_call_result(error(Error), _, _, _, _, _, _, _, _, _, _,
                    error(Error)) :-
    !.
planner_call_result(ok(Output),
                    ProviderName,
                    Attempt,
                    MaxAttempts,
                    Prompt,
                    Provider,
                    Options,
                    TokenLimit,
                    Budget,
                    Token,
                    Usage0,
                    Outcome) :-
    planner_output(Output, ProviderName, PlanInput, CallUsage, Summary),
    usage_add(Usage0, CallUsage, Usage1),
    (   budget_usage_check(Budget, Usage1, error(Error))
    ->  Outcome = error(Error)
    ;   plan_parse(PlanInput, ParseOutcome),
        planner_parse_result(ParseOutcome,
                             Summary,
                             Usage1,
                             Attempt,
                             MaxAttempts,
                             Prompt,
                             ProviderName,
                             Provider,
                             Options,
                             TokenLimit,
                             Budget,
                             Token,
                             Outcome)
    ).

planner_parse_result(ok(Plan), Summary, Usage, Attempt, _, _, _, _, _, _, _, _,
                     ok(Planner)) :-
    !,
    Planner = planner_result{plan:Plan,
                             attempt:Attempt,
                             model_calls:Usage.model_calls,
                             usage:Usage,
                             provider_summary:Summary}.
planner_parse_result(error(_),
                     _,
                     Usage,
                     Attempt,
                     MaxAttempts,
                     Prompt,
                     ProviderName,
                     Provider,
                     Options,
                     TokenLimit,
                     Budget,
                     Token,
                     Outcome) :-
    Attempt < MaxAttempts,
    !,
    Next is Attempt+1,
    planner_plan_attempt(Next,
                         MaxAttempts,
                         Prompt,
                         ProviderName,
                         Provider,
                         Options,
                         TokenLimit,
                         Budget,
                         Token,
                         Usage,
                         Outcome).
planner_parse_result(error(ParseError), _, Usage, Attempt, _, _, _, _, _, _, _, _,
                     error(Error)) :-
    Error = completion_error{phase:planner,
                             kind:plan_parse_failed,
                             attempts:Attempt,
                             usage:Usage,
                             cause:ParseError,
                             message:"real planner responses did not contain a valid typed plan"}.

call_planner(Options, Provider, Request, Outcome) :-
    (   option_value(planner_handler, Options, none, Handler),
        Handler \== none
    ->  require_callable(Handler, planner_handler),
        catch(call(Handler, Request, Outcome0),
              Exception,
              handler_exception(planner, Exception, Outcome0)),
        normalize_handler_outcome(Outcome0, Outcome)
    ;   model_complete(Provider, Request, Outcome)
    ).

call_model(Options, Provider, Request, Outcome) :-
    (   option_value(model_handler, Options, none, Handler),
        Handler \== none
    ->  require_callable(Handler, model_handler),
        catch(call(Handler, Request, Outcome0),
              Exception,
              handler_exception(model, Exception, Outcome0)),
        normalize_handler_outcome(Outcome0, Outcome)
    ;   model_complete(Provider, Request, Outcome)
    ).

normalize_handler_outcome(ok(Value), ok(Value)) :- !.
normalize_handler_outcome(error(Error), error(Error)) :- !.
normalize_handler_outcome(Value, ok(Value)).

handler_exception(Kind, Exception,
                  error(completion_error{phase:Kind,
                                         kind:handler_exception,
                                         exception:Safe,
                                         message:"trusted test handler raised an exception"})) :-
    safe_exception(Exception, Safe).

planner_output(Output, ProviderName, PlanInput, Usage, Summary) :-
    (   is_dict(Output), get_dict(plan, Output, ExplicitPlan)
    ->  PlanInput = ExplicitPlan,
        output_usage(Output, Usage),
        Summary = provider_event{provider:ProviderName,
                                 selected_model:fake,
                                 http_status:200,
                                 response_received:true,
                                 output_channel:handler}
    ;   PlanInput = planner_response_plan_input(Output, Channel),
        response_usage(Output, Usage),
        response_summary(Output, ProviderName, Channel, Summary)
    ).

planner_response_plan_input(Response, text) :-
    is_dict(Response),
    get_dict(text, Response, Text),
    nonempty_text(Text),
    !,
    Response = Response,
    fail.
planner_response_plan_input(Response, PlanInput, text) :-
    is_dict(Response),
    get_dict(text, Response, PlanInput),
    nonempty_text(PlanInput),
    !.
planner_response_plan_input(Response, PlanInput, reasoning) :-
    is_dict(Response),
    get_dict(reasoning, Response, PlanInput),
    nonempty_text(PlanInput),
    !.
planner_response_plan_input(Response, Response, structured).

/* -------------------------------------------------------------------------
 * Plan validation, recursion and budget shaping
 * ---------------------------------------------------------------------- */

validate_recursive_shape(Plan, Budget, Outcome) :-
    catch(( recursive_shape(Plan, 0, [], Shape),
            (   Shape.max_depth =< Budget.max_recursion_depth
            ->  Outcome = ok(Shape)
            ;   Outcome = error(completion_error{
                                     phase:validate,
                                     kind:recursion_depth_exceeded,
                                     requested:Shape.max_depth,
                                     limit:Budget.max_recursion_depth,
                                     message:"model-selected recursive plan exceeds hard depth ceiling"
                                 })
            )
          ),
          completion_fault(Fault),
          recursive_fault(Fault, Outcome)).

recursive_shape(plan(Steps), Depth, Ancestors, Shape) :-
    term_hash(plan(Steps), Hash),
    (   memberchk(Hash, Ancestors)
    ->  throw(completion_fault(recursive_cycle(Hash)))
    ;   true
    ),
    child_shapes(Steps, Depth, [Hash|Ancestors], ChildShapes),
    shape_from_children(Depth, ChildShapes, Shape),
    reject_duplicate_child_hashes(ChildShapes).

child_shapes([], _, _, []).
child_shapes([rlm(Child, Bind)|Steps], Depth, Ancestors,
             [child_shape{bind:Bind, hash:Hash, shape:ChildShape}|Shapes]) :-
    !,
    term_hash(Child, Hash),
    ChildDepth is Depth+1,
    recursive_shape(Child, ChildDepth, Ancestors, ChildShape),
    child_shapes(Steps, Depth, Ancestors, Shapes).
child_shapes([parallel(Plans, _)|Steps], Depth, Ancestors, Shapes) :-
    !,
    parallel_shapes(Plans, Depth, Ancestors, ParallelShapes),
    child_shapes(Steps, Depth, Ancestors, Rest),
    append(ParallelShapes, Rest, Shapes).
child_shapes([retry(_, Child, Bind)|Steps], Depth, Ancestors,
             [child_shape{bind:Bind, hash:Hash, shape:ChildShape}|Shapes]) :-
    !,
    term_hash(Child, Hash),
    ChildDepth is Depth+1,
    recursive_shape(Child, ChildDepth, Ancestors, ChildShape),
    child_shapes(Steps, Depth, Ancestors, Shapes).
child_shapes([_|Steps], Depth, Ancestors, Shapes) :-
    child_shapes(Steps, Depth, Ancestors, Shapes).

parallel_shapes([], _, _, []).
parallel_shapes([Plan|Plans], Depth, Ancestors,
                [child_shape{bind:parallel, hash:Hash, shape:Shape}|Shapes]) :-
    term_hash(Plan, Hash),
    ChildDepth is Depth+1,
    recursive_shape(Plan, ChildDepth, Ancestors, Shape),
    parallel_shapes(Plans, Depth, Ancestors, Shapes).

shape_from_children(Depth, [],
                    recursion_shape{max_depth:Depth,
                                    recursive_calls:0,
                                    child_hashes:[]}).
shape_from_children(Depth, Children, Shape) :-
    Children \== [],
    findall(Max, (member(C, Children), Max=C.shape.max_depth), Maxima),
    max_list([Depth|Maxima], MaxDepth),
    findall(Count, (member(C, Children), Count=C.shape.recursive_calls), Counts),
    sum_list(Counts, NestedCount),
    length(Children, DirectCount),
    Calls is DirectCount+NestedCount,
    findall(Hash, member(child_shape{hash:Hash}, Children), Hashes),
    Shape = recursion_shape{max_depth:MaxDepth,
                            recursive_calls:Calls,
                            child_hashes:Hashes}.

reject_duplicate_child_hashes(Children) :-
    findall(Hash, member(child_shape{hash:Hash}, Children), Hashes),
    sort(Hashes, Unique),
    length(Hashes, Count),
    length(Unique, UniqueCount),
    (   Count =:= UniqueCount
    ->  true
    ;   throw(completion_fault(duplicate_recursive_call))
    ).

recursive_fault(Fault,
                error(completion_error{phase:validate,
                                       kind:recursive_plan_rejected,
                                       detail:Fault,
                                       message:"recursive plan failed duplicate/cycle validation"})).

validate_child_capability_plans(error(Error), _, _, error(Error)) :- !.
validate_child_capability_plans(ok(Shape), ChildCapabilities, Budget, Outcome) :-
    (   Shape.recursive_calls =:= 0
    ->  Outcome = ok(Shape)
    ;   Outcome = ok(Shape),
        require_nonempty_list(ChildCapabilities, child_capabilities),
        Budget = Budget
    ).

validate_child_plans_in_plan(plan(Steps), ChildCapabilities, ChildBudget) :-
    maplist(validate_child_step(ChildCapabilities, ChildBudget), Steps).

validate_child_step(ChildCapabilities, ChildBudget, rlm(Child, _)) :-
    !,
    plan_validate(Child, ChildCapabilities, ChildBudget, Validation),
    require_plan_validation(Validation),
    validate_child_plans_in_plan(Child, ChildCapabilities, ChildBudget).
validate_child_step(ChildCapabilities, ChildBudget, parallel(Plans, _)) :-
    !,
    maplist(validate_child_plan(ChildCapabilities, ChildBudget), Plans).
validate_child_step(ChildCapabilities, ChildBudget, retry(_, Plan, _)) :-
    !,
    validate_child_plan(ChildCapabilities, ChildBudget, Plan).
validate_child_step(_, _, _).

validate_child_plan(ChildCapabilities, ChildBudget, Plan) :-
    plan_validate(Plan, ChildCapabilities, ChildBudget, Validation),
    require_plan_validation(Validation),
    validate_child_plans_in_plan(Plan, ChildCapabilities, ChildBudget).

require_plan_validation(ok(_)) :- !.
require_plan_validation(error(Error)) :-
    throw(completion_fault(child_capability_validation_failed(Error))).

count_model_steps(plan(Steps), Count) :-
    maplist(step_model_count, Steps, Counts),
    sum_list(Counts, Count).

step_model_count(model(_, _, _, _), 1) :- !.
step_model_count(rlm(Plan, _), Count) :- !, count_model_steps(Plan, Count).
step_model_count(parallel(Plans, _), Count) :-
    !,
    maplist(count_model_steps, Plans, Counts),
    sum_list(Counts, Count).
step_model_count(retry(Attempts, Plan, _), Count) :-
    !,
    count_model_steps(Plan, Base),
    Count is Attempts*Base.
step_model_count(_, 0).

bound_plan_model_tokens(Plan, 0, _, Plan) :- !.
bound_plan_model_tokens(Plan, Calls, RemainingTokens, Bounded) :-
    (   RemainingTokens > 0
    ->  PerCall is max(1, RemainingTokens // Calls),
        bound_plan_tokens(Plan, PerCall, Bounded)
    ;   throw(completion_fault(token_budget_exhausted))
    ).

bound_plan_tokens(plan(Steps0), PerCall, plan(Steps)) :-
    maplist(bound_step_tokens(PerCall), Steps0, Steps).

bound_step_tokens(PerCall,
                  model(Provider, Prompt, Options0, Bind),
                  model(Provider, Prompt, Options, Bind)) :-
    !,
    dict_token_limit(Options0, PerCall, Limit),
    put_dict(max_tokens, Options0, Limit, Options).
bound_step_tokens(PerCall, rlm(Plan0, Bind), rlm(Plan, Bind)) :-
    !,
    bound_plan_tokens(Plan0, PerCall, Plan).
bound_step_tokens(PerCall, parallel(Plans0, Bind), parallel(Plans, Bind)) :-
    !,
    maplist(bound_plan_tokens_with(PerCall), Plans0, Plans).
bound_step_tokens(PerCall, retry(Attempts, Plan0, Bind),
                  retry(Attempts, Plan, Bind)) :-
    !,
    bound_plan_tokens(Plan0, PerCall, Plan).
bound_step_tokens(_, Step, Step).

bound_plan_tokens_with(PerCall, Plan0, Plan) :-
    bound_plan_tokens(Plan0, PerCall, Plan).

dict_token_limit(Options, Ceiling, Limit) :-
    (   get_dict(max_tokens, Options, Requested), integer(Requested), Requested > 0
    ->  Limit is min(Requested, Ceiling)
    ;   get_dict(max_completion_tokens, Options, Requested2),
        integer(Requested2), Requested2 > 0
    ->  Limit is min(Requested2, Ceiling)
    ;   Limit = Ceiling
    ).

plan_budget(Budget, RemainingModelCalls,
            _{max_steps:Budget.max_iterations,
              max_depth:PlanDepth,
              max_parallel:Budget.max_concurrent_subcalls,
              max_model_calls:RemainingModelCalls,
              max_tool_calls:Budget.max_tool_calls,
              max_context_ops:Budget.max_context_ops,
              max_output_bytes:Budget.max_output_bytes,
              time_limit:Budget.time_limit}) :-
    PlanDepth is Budget.max_recursion_depth+1.

child_plan_budget(Budget,
                  _{max_steps:Budget.max_iterations,
                    max_depth:1,
                    max_parallel:Budget.max_concurrent_subcalls,
                    max_model_calls:Budget.max_model_calls,
                    max_tool_calls:Budget.max_tool_calls,
                    max_context_ops:Budget.max_context_ops,
                    max_output_bytes:Budget.max_output_bytes,
                    time_limit:Budget.time_limit}).

/* -------------------------------------------------------------------------
 * Usage and trajectory
 * ---------------------------------------------------------------------- */

plan_usage(Result, Events, Usage) :-
    dict_pairs(Result.vars, _, Pairs),
    findall(Event-EventUsage,
            ( member(Bind-Value, Pairs),
              is_model_response(Value),
              response_usage(Value, EventUsage),
              response_event(Value, unknown, plan_binding(Bind), unknown, Event)
            ),
            EventPairs),
    pairs_events_usage(EventPairs, Events, Usages),
    usage_sum(Usages, Usage).

pairs_events_usage([], [], []).
pairs_events_usage([Event-Usage|Pairs], [Event|Events], [Usage|Usages]) :-
    pairs_events_usage(Pairs, Events, Usages).

is_model_response(Value) :-
    is_dict(Value),
    get_dict(metadata, Value, Metadata),
    is_dict(Metadata),
    get_dict(http_status, Metadata, _),
    get_dict(usage, Value, _).

response_usage(Response, Usage) :-
    (   is_dict(Response), get_dict(usage, Response, Raw), is_dict(Raw)
    ->  usage_number(Raw, prompt_tokens, Prompt, PromptKnown),
        usage_number(Raw, completion_tokens, Completion, CompletionKnown),
        usage_number(Raw, total_tokens, Total0, TotalKnown0),
        (   TotalKnown0 == true
        ->  Total = Total0, TokensKnown = true
        ;   PromptKnown == true, CompletionKnown == true
        ->  Total is Prompt+Completion, TokensKnown = true
        ;   Total = 0, TokensKnown = false
        ),
        usage_cost(Raw, Cost, CostKnown),
        Usage = usage_summary{model_calls:1,
                              prompt_tokens:Prompt,
                              completion_tokens:Completion,
                              total_tokens:Total,
                              cost_usd:Cost,
                              cost_known:CostKnown,
                              tokens_known:TokensKnown}
    ;   Usage = usage_summary{model_calls:1,
                              prompt_tokens:0,
                              completion_tokens:0,
                              total_tokens:0,
                              cost_usd:0.0,
                              cost_known:false,
                              tokens_known:false}
    ).

output_usage(Output, Usage) :-
    (   get_dict(usage, Output, Raw), is_dict(Raw)
    ->  fake_usage_summary(Raw, Usage)
    ;   Usage = usage_summary{model_calls:1,
                              prompt_tokens:0,
                              completion_tokens:0,
                              total_tokens:0,
                              cost_usd:0.0,
                              cost_known:true,
                              tokens_known:true}
    ).

fake_usage_summary(Raw, Usage) :-
    dict_default(prompt_tokens, Raw, 0, Prompt),
    dict_default(completion_tokens, Raw, 0, Completion),
    dict_default(total_tokens, Raw, 0, Total),
    dict_default(cost, Raw, 0.0, Cost),
    Usage = usage_summary{model_calls:1,
                          prompt_tokens:Prompt,
                          completion_tokens:Completion,
                          total_tokens:Total,
                          cost_usd:Cost,
                          cost_known:true,
                          tokens_known:true}.

usage_number(Dict, Key, Value, Known) :-
    (   get_dict(Key, Dict, Found), number(Found)
    ->  Value = Found, Known = true
    ;   Value = 0, Known = false
    ).

usage_cost(Dict, Cost, Known) :-
    (   get_dict(cost, Dict, Found), number(Found)
    ->  Cost = Found, Known = true
    ;   Cost = 0.0, Known = false
    ).

usage_add(A, B, C) :-
    Calls is A.model_calls+B.model_calls,
    Prompt is A.prompt_tokens+B.prompt_tokens,
    Completion is A.completion_tokens+B.completion_tokens,
    Total is A.total_tokens+B.total_tokens,
    Cost is A.cost_usd+B.cost_usd,
    bool_and(A.cost_known, B.cost_known, CostKnown),
    bool_and(A.tokens_known, B.tokens_known, TokensKnown),
    C = usage_summary{model_calls:Calls,
                      prompt_tokens:Prompt,
                      completion_tokens:Completion,
                      total_tokens:Total,
                      cost_usd:Cost,
                      cost_known:CostKnown,
                      tokens_known:TokensKnown}.

usage_sum([], usage_summary{model_calls:0,
                            prompt_tokens:0,
                            completion_tokens:0,
                            total_tokens:0,
                            cost_usd:0.0,
                            cost_known:true,
                            tokens_known:true}).
usage_sum([Usage|Usages], Total) :-
    usage_sum(Usages, Rest),
    usage_add(Usage, Rest, Total).

budget_usage_check(Budget, Usage, Outcome) :-
    (   Usage.model_calls > Budget.max_model_calls
    ->  Outcome = error(completion_error{phase:budget,
                                         kind:model_calls_exceeded,
                                         used:Usage.model_calls,
                                         limit:Budget.max_model_calls,
                                         message:"model-call budget exceeded"})
    ;   Usage.tokens_known == true,
        Usage.total_tokens > Budget.max_total_tokens
    ->  Outcome = error(completion_error{phase:budget,
                                         kind:token_budget_exceeded,
                                         used:Usage.total_tokens,
                                         limit:Budget.max_total_tokens,
                                         message:"token budget exceeded"})
    ;   Usage.cost_known == true,
        Usage.cost_usd > Budget.max_cost_usd
    ->  Outcome = error(completion_error{phase:budget,
                                         kind:cost_budget_exceeded,
                                         used:Usage.cost_usd,
                                         limit:Budget.max_cost_usd,
                                         message:"cost budget exceeded"})
    ;   Outcome = ok
    ).

remaining_tokens(Max, Used, Remaining) :-
    (   number(Used)
    ->  Remaining is max(0, Max-Used)
    ;   Remaining = Max
    ).

planner_event(Planner,
              model_event{id:root_planner,
                          parent:none,
                          depth:0,
                          reason:"select symbolic execution plan",
                          provider:Planner.provider_summary.provider,
                          selected_model:Planner.provider_summary.selected_model,
                          http_status:Planner.provider_summary.http_status,
                          usage:Planner.usage}).

response_event(Response, Depth, Reason, ProviderFallback,
               model_event{id:Id,
                           parent:root_planner,
                           depth:Depth,
                           reason:Reason,
                           provider:Provider,
                           selected_model:Selected,
                           http_status:Status,
                           usage:Usage}) :-
    term_hash(Response, Hash),
    format(atom(Id), 'model_~16r', [Hash]),
    dict_default(provider, Response, ProviderFallback, Provider),
    dict_default(selected_model, Response, unknown, Selected),
    (   get_dict(metadata, Response, Metadata), is_dict(Metadata)
    ->  dict_default(http_status, Metadata, 0, Status)
    ;   Status = 0
    ),
    response_usage(Response, Usage).

response_summary(Response, ProviderFallback, Channel,
                 provider_event{provider:Provider,
                                selected_model:Selected,
                                http_status:Status,
                                response_received:true,
                                output_channel:Channel}) :-
    dict_default(provider, Response, ProviderFallback, Provider),
    dict_default(selected_model, Response, unknown, Selected),
    (   get_dict(metadata, Response, Metadata), is_dict(Metadata)
    ->  dict_default(http_status, Metadata, 0, Status)
    ;   Status = 0
    ).

recursive_events(plan(Steps), Vars, Depth, Events) :-
    findall(Event,
            ( member(rlm(_, Bind), Steps),
              get_dict(Bind, Vars, Value),
              is_model_response(Value),
              ChildDepth is Depth+1,
              response_event(Value,
                             ChildDepth,
                             "model-selected recursive rlm step",
                             unknown,
                             Event)
            ),
            Events).

sort_events(Events, Events).

/* -------------------------------------------------------------------------
 * Prompt construction and options
 * ---------------------------------------------------------------------- */

planner_prompt(Query,
               Metadata,
               Capabilities,
               ChildCapabilities,
               ToolSchemas,
               Options,
               Prompt) :-
    option_value(planner_instruction, Options, "", Instruction0),
    text_string(Instruction0, Instruction),
    format(string(Prompt),
           "You are the root planner for a bounded Recursive Language Model runtime.\n\
Return ONLY one JSON object accepted by the typed plan interpreter; no markdown.\n\
The opaque context is available only through input name context. Do not invent context bytes from metadata.\n\
Goal: ~s\n\
Context metadata: ~q\n\
Root capabilities: ~q\n\
Child capabilities: ~q\n\
Registered tool schemas: ~q\n\
Recursive decomposition is optional. Use an rlm step only when useful; every rlm step contains a nested typed plan.\n\
~s",
           [Query,
            Metadata,
            Capabilities,
            ChildCapabilities,
            ToolSchemas,
            Instruction]).

provider_options(Options, ProviderName, Provider) :-
    (   option_value(provider, Options, none, Explicit), Explicit \== none
    ->  Provider = Explicit,
        provider_name_from_term(Explicit, ProviderName0),
        option_value(provider_name, Options, ProviderName0, ProviderName)
    ;   default_openrouter_model(Model),
        openrouter_provider(Model, Provider),
        option_value(provider_name, Options, openrouter, ProviderName)
    ).

provider_name_from_term(provider(Name, _), Name) :- atom(Name), !.
provider_name_from_term(_, openrouter).

capability_options(Options, ProviderName, Capabilities, ChildCapabilities) :-
    option_value(capabilities,
                 Options,
                 [rlm, model(ProviderName)],
                 Requested),
    capabilities_normalize(Requested, NormalizedOutcome),
    require_capabilities(NormalizedOutcome, Capabilities),
    option_value(child_capabilities,
                 Options,
                 [model(ProviderName)],
                 ChildRequested),
    capabilities_narrow(Capabilities, ChildRequested, ChildOutcome),
    require_capabilities(ChildOutcome, ChildCapabilities).

require_capabilities(ok(Capabilities), Capabilities) :- !.
require_capabilities(error(Error), _) :-
    throw(completion_fault(capability_error(Error))).

runtime_tools(Options, Capabilities, Tools, Schemas) :-
    option_value(tools, Options, [], DirectTools),
    (   is_list(DirectTools)
    ->  true
    ;   throw(completion_fault(invalid_tools(DirectTools)))
    ),
    option_value(tool_registry, Options, none, Registry),
    (   Registry == none
    ->  RegistryTools = [], Schemas = []
    ;   tool_registry_runtime_tools(Registry, Capabilities, RegistryTools),
        tool_discover(Registry, Schemas)
    ),
    append(RegistryTools, DirectTools, Tools).

context_runtime_options(Options, ContextOptions) :-
    option_value(context_options,
                 Options,
                 [max_results(16), max_bytes(4096), time_limit(1.0)],
                 ContextOptions),
    (   is_list(ContextOptions)
    ->  true
    ;   throw(completion_fault(invalid_context_options(ContextOptions)))
    ).

planner_attempts(Options, Attempts) :-
    option_value(planner_attempts, Options, 2, Attempts),
    require_positive_integer(Attempts, planner_attempts).

planner_token_limit(Options, Limit) :-
    option_value(planner_max_tokens, Options, 1024, Limit),
    require_positive_integer(Limit, planner_max_tokens).

planner_request_options(Options, TokenLimit, RequestOptions) :-
    option_value(planner_temperature, Options, 0, Temperature),
    RequestOptions = _{max_tokens:TokenLimit, temperature:Temperature}.

model_request_options(Options, TokenLimit, RequestOptions) :-
    option_value(temperature, Options, 0, Temperature),
    RequestOptions = _{max_tokens:TokenLimit, temperature:Temperature}.

completion_budget(Options, Budget) :-
    default_completion_budget(Default),
    option_value(budget, Options, _{}, Updates),
    (   is_dict(Updates)
    ->  put_dict(Updates, Default, Budget0)
    ;   throw(completion_fault(invalid_budget(Updates)))
    ),
    validate_completion_budget(Budget0),
    Budget = Budget0.

validate_completion_budget(Budget) :-
    require_positive_integer(Budget.max_iterations, max_iterations),
    require_nonnegative_integer(Budget.max_recursion_depth, max_recursion_depth),
    require_positive_integer(Budget.max_concurrent_subcalls,
                             max_concurrent_subcalls),
    require_positive_integer(Budget.max_model_calls, max_model_calls),
    require_nonnegative_integer(Budget.max_tool_calls, max_tool_calls),
    require_nonnegative_integer(Budget.max_context_ops, max_context_ops),
    require_positive_integer(Budget.max_total_tokens, max_total_tokens),
    require_nonnegative_number(Budget.max_cost_usd, max_cost_usd),
    require_positive_integer(Budget.max_output_bytes, max_output_bytes),
    require_positive_number(Budget.time_limit, time_limit).

/* -------------------------------------------------------------------------
 * Context and cancellation helpers
 * ---------------------------------------------------------------------- */

acquire_context(ContextRef, ContextRef, false) :-
    is_dict(ContextRef),
    get_dict(handle, ContextRef, context_handle(_, _)),
    !.
acquire_context(Handle, ContextRef, false) :-
    nonvar(Handle),
    Handle = context_handle(_, _),
    !,
    context_metadata(Handle, MetadataOutcome),
    require_context_metadata(MetadataOutcome, ContextRef).
acquire_context(Source, ContextRef, true) :-
    context_register(Source, [], RegisterOutcome),
    (   RegisterOutcome = ok(ContextRef)
    ->  true
    ;   RegisterOutcome = error(Error),
        throw(completion_fault(context_registration_failed(Error)))
    ).

cleanup_context(_, false) :- !.
cleanup_context(ContextRef, true) :-
    catch(context_delete(ContextRef.handle, _), _, true).

require_context_metadata(ok(ContextRef), ContextRef) :- !.
require_context_metadata(error(Error), _) :-
    throw(completion_fault(context_metadata_failed(Error))).

cancellation_option(Options, Token, OwnToken) :-
    option_value(cancel_token, Options, none, Requested),
    (   Requested == none
    ->  rlm_cancellation_token(Token), OwnToken = true
    ;   Token = Requested, OwnToken = false,
        ensure_cancellation_token(Token)
    ).

ensure_cancellation_token(Token) :-
    (   cancellation_state(Token, _)
    ->  true
    ;   with_mutex(rlm_completion_cancel,
                   assertz(cancellation_state(Token, active)))
    ).

register_current_thread(Token) :-
    thread_self(Thread),
    with_mutex(rlm_completion_cancel,
               ( retractall(cancellation_thread(Token, Thread)),
                 assertz(cancellation_thread(Token, Thread))
               )),
    check_cancelled(Token).

cleanup_cancellation(Token, OwnToken) :-
    thread_self(Thread),
    with_mutex(rlm_completion_cancel,
               retractall(cancellation_thread(Token, Thread))),
    (   OwnToken == true
    ->  with_mutex(rlm_completion_cancel,
                   retractall(cancellation_state(Token, _)))
    ;   true
    ).

check_cancelled(Token) :-
    (   cancellation_state(Token, cancelled)
    ->  throw(error(rlm_cancelled(Token),
                    context(rlm_completion, 'completion cancelled')))
    ;   true
    ).

/* -------------------------------------------------------------------------
 * Generic helpers
 * ---------------------------------------------------------------------- */

option_value(Name, Options, Default, Value) :-
    (   member(Option, Options),
        Option =.. [Name, Found]
    ->  Value = Found
    ;   Value = Default
    ).

require_options(Options) :-
    (   is_list(Options)
    ->  true
    ;   throw(completion_fault(invalid_options(Options)))
    ).

require_callable(Handler, _) :- callable(Handler), !.
require_callable(Handler, Field) :-
    throw(completion_fault(invalid_callable(Field, Handler))).

require_positive_integer(Value, _) :- integer(Value), Value > 0, !.
require_positive_integer(Value, Field) :-
    throw(completion_fault(invalid_positive_integer(Field, Value))).

require_nonnegative_integer(Value, _) :- integer(Value), Value >= 0, !.
require_nonnegative_integer(Value, Field) :-
    throw(completion_fault(invalid_nonnegative_integer(Field, Value))).

require_positive_number(Value, _) :- number(Value), Value > 0, !.
require_positive_number(Value, Field) :-
    throw(completion_fault(invalid_positive_number(Field, Value))).

require_nonnegative_number(Value, _) :- number(Value), Value >= 0, !.
require_nonnegative_number(Value, Field) :-
    throw(completion_fault(invalid_nonnegative_number(Field, Value))).

require_nonempty_list(Value, _) :- is_list(Value), Value \== [], !.
require_nonempty_list(Value, Field) :-
    throw(completion_fault(invalid_nonempty_list(Field, Value))).

text_string(Value, String) :- string(Value), !, String = Value.
text_string(Value, String) :- atom(Value), !, atom_string(Value, String).
text_string(Value, _) :-
    throw(completion_fault(expected_text(Value))).

nonempty_text(Value) :- string(Value), Value \== "", !.
nonempty_text(Value) :- atom(Value), Value \== ''.

bool_and(true, true, true) :- !.
bool_and(_, _, false).

dict_default(Key, Dict, Default, Value) :-
    (   is_dict(Dict), get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

safe_exception(Exception, Safe) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).

completion_exception(time_limit_exceeded,
                     error(completion_error{phase:runtime,
                                            kind:timeout,
                                            message:"completion exceeded wall-time budget"})) :-
    !.
completion_exception(time_limit_exceeded(_),
                     error(completion_error{phase:runtime,
                                            kind:timeout,
                                            message:"completion exceeded wall-time budget"})) :-
    !.
completion_exception(error(rlm_cancelled(Token), _),
                     error(completion_error{phase:runtime,
                                            kind:cancelled,
                                            token:Token,
                                            message:"completion cancelled"})) :-
    !.
completion_exception(completion_fault(Fault),
                     error(completion_error{phase:runtime,
                                            kind:completion_fault,
                                            detail:Fault,
                                            message:"completion runtime rejected the operation"})) :-
    !.
completion_exception(Exception,
                     error(completion_error{phase:runtime,
                                            kind:exception,
                                            exception:Safe,
                                            message:"completion runtime raised an exception"})) :-
    safe_exception(Exception, Safe).
