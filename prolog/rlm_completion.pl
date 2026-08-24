:- module(rlm_completion,
          [ rlm_completion/4,
            rlm_completion_async/4,
            llm_query/3,
            llm_query_async/3,
            rlm_query/4,
            rlm_query_async/4,
            rlm_cancellation_token/1,
            rlm_cancel/1,
            default_completion_budget/1
          ]).

/** <module> Bounded Recursive Language Model supervisor

The root model selects a typed symbolic plan. Prolog owns validation,
capabilities, recursion ceilings, budgets, cancellation and trajectory data.
Recursive `rlm(...)` nodes remain closed symbolic plans; a child model call is
still executed by the production provider registry, never by model-generated
Prolog code.

Completion execution follows one direction: the async predicate schedules the
canonical guarded operation; the sync predicate starts that same operation and
awaits its Future. Internal recursive/model steps call canonical execution
predicates directly and never re-enter a synchronous public facade.
*/

:- use_module(library(lists)).
:- use_module(library(time)).
:- use_module(library(uuid)).
:- use_module(rlm_async).
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
 * Public API and canonical task entrypoints
 * ---------------------------------------------------------------------- */

rlm_completion_async(Query, Context, Options, Future) :-
    completion_task_metadata(completion, Options, Metadata),
    rlm_async_submit(rlm_completion:rlm_completion_execute(Query,
                                                           Context,
                                                           Options),
                     Metadata,
                     Future).

rlm_completion(Query, Context, Options, Outcome) :-
    rlm_completion_async(Query, Context, Options, Future),
    await_owned_future(Future, Outcome).

rlm_completion_execute(Query, Context, Options, Outcome) :-
    catch(rlm_completion_guarded(Query, Context, Options, Outcome),
          Exception,
          completion_exception(Exception, Outcome)).

llm_query_async(Prompt, Options, Future) :-
    completion_task_metadata(llm_query, Options, Metadata),
    rlm_async_submit(rlm_completion:llm_query_execute(Prompt, Options),
                     Metadata,
                     Future).

llm_query(Prompt, Options, Outcome) :-
    llm_query_async(Prompt, Options, Future),
    await_owned_future(Future, Outcome).

llm_query_execute(Prompt, Options, Outcome) :-
    catch(llm_query_guarded(Prompt, Options, Outcome),
          Exception,
          completion_exception(Exception, Outcome)).

rlm_query_async(Query, SubContext, Options, Future) :-
    completion_task_metadata(rlm_query, Options, Metadata),
    rlm_async_submit(rlm_completion:rlm_query_execute(Query,
                                                       SubContext,
                                                       Options),
                     Metadata,
                     Future).

rlm_query(Query, SubContext, Options, Outcome) :-
    rlm_query_async(Query, SubContext, Options, Future),
    await_owned_future(Future, Outcome).

rlm_query_execute(Query, SubContext, Options, Outcome) :-
    catch(rlm_query_guarded(Query, SubContext, Options, Outcome),
          Exception,
          completion_exception(Exception, Outcome)).

await_owned_future(Future, Outcome) :-
    setup_call_cleanup(
        true,
        rlm_future_await(Future, Outcome),
        rlm_future_destroy(Future)).

completion_task_metadata(Operation, Options, Metadata) :-
    completion_metadata_fields(Options, TraceId, SessionId),
    Metadata = async_metadata{operation:Operation,
                              trace_id:TraceId,
                              session_id:SessionId}.

completion_metadata_fields(Options, TraceId, SessionId) :-
    (   is_list(Options)
    ->  metadata_option(trace_id, Options, none, TraceId),
        metadata_option(session_id, Options, none, SessionId)
    ;   TraceId = none,
        SessionId = none
    ).

metadata_option(Name, Options, Default, Value) :-
    (   member(Option, Options),
        Option =.. [Name, Found],
        ground(Found)
    ->  Value = Found
    ;   Value = Default
    ).

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
    capability_options(Options,
                       ProviderName,
                       Capabilities,
                       ChildCapabilities),
    runtime_tools(Options,
                  Capabilities,
                  RuntimeTools,
                  ToolSchemas),
    planner_prompt(Query,
                   MetadataRef.metadata,
                   Capabilities,
                   ChildCapabilities,
                   ToolSchemas,
                   Options,
                   Prompt),
    planner_attempts(Options, Attempts),
    planner_token_limit(Options, RequestedPlannerTokens),
    PlannerTokenLimit is min(Budget.max_total_tokens,
                             RequestedPlannerTokens),
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
    validate_recursive_plan(Planner.plan,
                            ChildCapabilities,
                            Budget,
                            RecursiveOutcome),
    completion_after_recursive_validation(RecursiveOutcome,
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

completion_after_recursive_validation(error(Error), _, _, _, _, _, _, _, _,
                                      _, _, _, error(Error)) :-
    !.
completion_after_recursive_validation(ok(Stats),
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
    RemainingCalls is Budget.max_model_calls-Planner.usage.model_calls,
    (   RemainingCalls >= 0
    ->  true
    ;   throw(completion_fault(model_call_budget_exhausted))
    ),
    count_model_steps(Planner.plan, PlanModelCalls),
    (   PlanModelCalls =< RemainingCalls
    ->  true
    ;   throw(completion_fault(model_call_budget_exceeded(PlanModelCalls,
                                                          RemainingCalls)))
    ),
    remaining_tokens(Budget.max_total_tokens,
                     Planner.usage.total_tokens,
                     RemainingTokens),
    bound_plan_model_tokens(Planner.plan,
                            PlanModelCalls,
                            RemainingTokens,
                            BoundedPlan),
    plan_budget(Budget, RemainingCalls, PlanBudget),
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
                               Stats,
                               ChildCapabilities,
                               Budget,
                               Token,
                               Outcome).

completion_after_execution(error(Error0),
                           Planner,
                           _,
                           _,
                           _,
                           Budget,
                           Token,
                           error(Error)) :-
    !,
    check_cancelled(Token),
    execution_error_usage(Error0, PlanUsage),
    usage_add(Planner.usage, PlanUsage, TotalUsage),
    budget_usage_check(Budget, TotalUsage, BudgetOutcome),
    execution_error_with_accounting(Error0,
                                    TotalUsage,
                                    BudgetOutcome,
                                    Error).
completion_after_execution(ok(Result),
                           Planner,
                           Plan,
                           Stats,
                           ChildCapabilities,
                           Budget,
                           Token,
                           Outcome) :-
    check_cancelled(Token),
    plan_usage(Result, PlanUsage),
    usage_add(Planner.usage, PlanUsage, TotalUsage),
    budget_usage_check(Budget, TotalUsage, BudgetOutcome),
    completion_finish(BudgetOutcome,
                      Planner,
                      Plan,
                      Result,
                      Stats,
                      ChildCapabilities,
                      TotalUsage,
                      Outcome).

execution_error_usage(Error, Usage) :-
    (   is_dict(Error),
        get_dict(model_responses, Error, Responses),
        is_list(Responses)
    ->  model_responses_usage(Responses, Usage)
    ;   zero_usage(Usage)
    ).

model_responses_usage(Responses, Usage) :-
    findall(ResponseUsage,
            ( member(Response, Responses),
              response_usage(Response, ResponseUsage)
            ),
            Usages),
    usage_sum(Usages, Usage).

execution_error_with_accounting(Error0, Usage, BudgetOutcome, Error) :-
    (   is_dict(Error0)
    ->  put_dict(usage, Error0, Usage, Error1)
    ;   Error1 = completion_error{phase:execute,
                                  kind:execution_failed,
                                  cause:Error0,
                                  usage:Usage,
                                  message:"plan execution failed"}
    ),
    (   BudgetOutcome = error(BudgetError)
    ->  put_dict(budget_violation, Error1, BudgetError, Error)
    ;   Error = Error1
    ).

completion_finish(error(Error), _, _, _, _, _, _, error(Error)) :- !.
completion_finish(ok,
                  Planner,
                  Plan,
                  Result,
                  Stats,
                  ChildCapabilities,
                  TotalUsage,
                  ok(Completion)) :-
    planner_event(Planner, RootEvent),
    completion_model_events(Plan, Result, ModelEvents),
    Completion = completion_result{
                     value:Result.value,
                     plan:Plan,
                     vars:Result.vars,
                     transitions:Result.transitions,
                     recursion:Stats,
                     child_capabilities:ChildCapabilities,
                     usage:TotalUsage,
                     trajectory:completion_trajectory{
                                    root_event:RootEvent,
                                    events:[RootEvent|ModelEvents],
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
    planner_token_limit(Options, RequestedLimit),
    TokenLimit is min(Budget.max_total_tokens, RequestedLimit),
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
           "Recursive subquery at depth ~d.\nGoal: ~s\nOpaque context metadata: ~q\nAnswer only from information actually supplied to you; metadata is not context content.",
           [Depth, Query, MetadataRef.metadata]),
    llm_query_execute(Prompt, Options, ModelOutcome),
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

planner_plan(MaxAttempts,
             Prompt,
             ProviderName,
             Provider,
             Options,
             TokenLimit,
             Budget,
             Token,
             Outcome) :-
    zero_usage(Zero),
    planner_loop(1,
                 MaxAttempts,
                 Prompt,
                 ProviderName,
                 Provider,
                 Options,
                 TokenLimit,
                 Budget,
                 Token,
                 Zero,
                 Outcome).

planner_loop(Attempt,
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
    (   Usage0.model_calls >= Budget.max_model_calls
    ->  Outcome = error(completion_error{phase:planner,
                                         kind:model_call_budget_exhausted,
                                         message:"planner exhausted model-call budget"})
    ;   remaining_tokens(Budget.max_total_tokens,
                         Usage0.total_tokens,
                         RemainingTokens),
        (   RemainingTokens =< 0
        ->  Outcome = error(completion_error{phase:planner,
                                             kind:token_budget_exhausted,
                                             message:"planner exhausted token budget"})
        ;   EffectiveLimit is max(1,
                                  min(TokenLimit, RemainingTokens)),
            planner_request_options(Options,
                                    EffectiveLimit,
                                    RequestOptions),
            Request = model_request{
                          messages:[message{role:user, content:Prompt}],
                          options:RequestOptions
                      },
            call_planner(Options, Provider, Request, PlannerCall),
            planner_call_result(PlannerCall,
                                Attempt,
                                MaxAttempts,
                                Prompt,
                                ProviderName,
                                Provider,
                                Options,
                                TokenLimit,
                                Budget,
                                Token,
                                Usage0,
                                Outcome)
        )
    ).

planner_call_result(error(Error), _, _, _, _, _, _, _, _, _, _, error(Error)) :-
    !.
planner_call_result(ok(Output),
                    Attempt,
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
    planner_output(Output,
                   ProviderName,
                   PlanInput,
                   CallUsage,
                   Summary),
    usage_add(Usage0, CallUsage, Usage1),
    budget_usage_check(Budget, Usage1, UsageBudgetOutcome),
    (   UsageBudgetOutcome = error(Error)
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
    planner_loop(Next,
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
                             message:"planner responses did not contain a valid typed plan"}.

call_planner(Options, Provider, Request, Outcome) :-
    option_value(planner_handler, Options, none, Handler),
    (   Handler == none
    ->  rlm_chain:model_complete_execute(Provider, Request, Outcome)
    ;   require_callable(Handler, planner_handler),
        catch(call(Handler, Request, RawOutcome),
              Exception,
              handler_exception(planner, Exception, RawOutcome)),
        normalize_handler_outcome(RawOutcome, Outcome)
    ).

call_model(Options, Provider, Request, Outcome) :-
    option_value(model_handler, Options, none, Handler),
    (   Handler == none
    ->  rlm_chain:model_complete_execute(Provider, Request, Outcome)
    ;   require_callable(Handler, model_handler),
        catch(call(Handler, Request, RawOutcome),
              Exception,
              handler_exception(model, Exception, RawOutcome)),
        normalize_handler_outcome(RawOutcome, Outcome)
    ).

normalize_handler_outcome(ok(Value), ok(Value)) :- !.
normalize_handler_outcome(error(Error), error(Error)) :- !.
normalize_handler_outcome(Value, ok(Value)).

handler_exception(_, error(rlm_cancelled(Token), Context), _) :-
    !,
    throw(error(rlm_cancelled(Token), Context)).
handler_exception(_, rlm_cancelled(Token), _) :-
    !,
    throw(rlm_cancelled(Token)).
handler_exception(_, time_limit_exceeded, _) :-
    !,
    throw(time_limit_exceeded).
handler_exception(_, time_limit_exceeded(Context), _) :-
    !,
    throw(time_limit_exceeded(Context)).
handler_exception(Kind, Exception,
                  error(completion_error{phase:Kind,
                                         kind:handler_exception,
                                         exception:Safe,
                                         message:"trusted injected handler raised an exception"})) :-
    safe_exception(Exception, Safe).

planner_output(Output, ProviderName, PlanInput, Usage, Summary) :-
    is_dict(Output),
    get_dict(plan, Output, ExplicitPlan),
    !,
    PlanInput = ExplicitPlan,
    output_usage(Output, Usage),
    Summary = provider_event{provider:ProviderName,
                             selected_model:injected,
                             http_status:200,
                             response_received:true,
                             output_channel:handler}.
planner_output(Output, ProviderName, PlanInput, Usage, Summary) :-
    real_response_plan_input(Output, PlanInput, Channel),
    response_usage(Output, Usage),
    response_summary(Output, ProviderName, Channel, Summary).

real_response_plan_input(Response, PlanInput, text) :-
    is_dict(Response),
    get_dict(text, Response, PlanInput),
    nonempty_text(PlanInput),
    !.
real_response_plan_input(Response, PlanInput, reasoning) :-
    is_dict(Response),
    get_dict(reasoning, Response, PlanInput),
    nonempty_text(PlanInput),
    !.
real_response_plan_input(Response, Response, structured).

/* -------------------------------------------------------------------------
 * Recursive validation and plan budget shaping
 * ---------------------------------------------------------------------- */

validate_recursive_plan(Plan, ChildCapabilities, Budget, Outcome) :-
    catch(( recursive_plan_stats(Plan, Stats),
            validate_recursive_depth(Stats, Budget),
            validate_child_capabilities(Plan, ChildCapabilities),
            Outcome = ok(Stats)
          ),
          completion_fault(Fault),
          recursive_fault(Fault, Outcome)).

recursive_plan_stats(Plan, Stats) :-
    canonical_recursive_plan(Plan, _),
    collect_recursive_plan(Plan, 0, [], Entries, Depths),
    findall(Hash,
            ( member(Entry, Entries),
              get_dict(hash, Entry, Hash)
            ),
            Hashes),
    sort(Hashes, UniqueHashes),
    length(Hashes, Calls),
    length(UniqueHashes, UniqueCalls),
    (   Calls =:= UniqueCalls
    ->  true
    ;   throw(completion_fault(duplicate_recursive_call))
    ),
    max_list([0|Depths], MaxDepth),
    Stats = recursion_stats{recursive_calls:Calls,
                            max_depth:MaxDepth,
                            fingerprints:Hashes}.

canonical_recursive_plan(Plan, Canonical) :-
    (   acyclic_term(Plan)
    ->  canonical_recursive_term(Plan, Canonical)
    ;   throw(completion_fault(recursive_cycle(cyclic_term)))
    ).

canonical_recursive_term(Term, _) :-
    var(Term),
    !,
    throw(completion_fault(non_ground_recursive_plan)).
canonical_recursive_term(Dict0, Dict) :-
    is_dict(Dict0),
    !,
    dict_pairs(Dict0, Tag0, Pairs0),
    canonical_recursive_dict_tag(Tag0, Tag),
    maplist(canonical_recursive_pair, Pairs0, Pairs),
    dict_pairs(Dict, Tag, Pairs).
canonical_recursive_term(Term, Term) :-
    atomic(Term),
    !.
canonical_recursive_term(Term0, Term) :-
    Term0 =.. [Functor|Args0],
    maplist(canonical_recursive_term, Args0, Args),
    Term =.. [Functor|Args].

canonical_recursive_dict_tag(Tag0, rlm_anonymous_dict) :-
    var(Tag0),
    !.
canonical_recursive_dict_tag(Tag, Tag).

canonical_recursive_pair(Key-Value0, Key-Value) :-
    canonical_recursive_term(Value0, Value).

recursive_plan_fingerprint(Plan, Hash) :-
    canonical_recursive_plan(Plan, Canonical),
    term_hash(Canonical, Hash),
    (   integer(Hash)
    ->  true
    ;   throw(completion_fault(non_ground_recursive_plan))
    ).

collect_recursive_plan(plan(Steps), Depth, Ancestors, Entries, Depths) :-
    collect_recursive_steps(Steps,
                            Depth,
                            Ancestors,
                            Entries,
                            Depths).

collect_recursive_steps([], _, _, [], []).
collect_recursive_steps([rlm(Child, Bind)|Steps],
                        Depth,
                        Ancestors,
                        Entries,
                        Depths) :-
    !,
    recursive_plan_fingerprint(Child, Hash),
    (   memberchk(Hash, Ancestors)
    ->  throw(completion_fault(recursive_cycle(Hash)))
    ;   true
    ),
    ChildDepth is Depth+1,
    collect_recursive_plan(Child,
                           ChildDepth,
                           [Hash|Ancestors],
                           ChildEntries,
                           ChildDepths),
    collect_recursive_steps(Steps,
                            Depth,
                            Ancestors,
                            RestEntries,
                            RestDepths),
    append([recursive_entry{bind:Bind, hash:Hash, depth:ChildDepth}|ChildEntries],
           RestEntries,
           Entries),
    append([ChildDepth|ChildDepths], RestDepths, Depths).
collect_recursive_steps([parallel(Plans, _)|Steps],
                        Depth,
                        Ancestors,
                        Entries,
                        Depths) :-
    !,
    collect_parallel_plans(Plans,
                           Depth,
                           Ancestors,
                           ParallelEntries,
                           ParallelDepths),
    collect_recursive_steps(Steps,
                            Depth,
                            Ancestors,
                            RestEntries,
                            RestDepths),
    append(ParallelEntries, RestEntries, Entries),
    append(ParallelDepths, RestDepths, Depths).
collect_recursive_steps([retry(Attempts, RetryPlan, _)|Steps],
                        Depth,
                        Ancestors,
                        Entries,
                        Depths) :-
    !,
    collect_recursive_plan(RetryPlan,
                           Depth,
                           Ancestors,
                           RetryEntries,
                           RetryDepths),
    (   Attempts > 1, RetryEntries \== []
    ->  throw(completion_fault(repeated_recursive_retry(Attempts)))
    ;   true
    ),
    collect_recursive_steps(Steps,
                            Depth,
                            Ancestors,
                            RestEntries,
                            RestDepths),
    append(RetryEntries, RestEntries, Entries),
    append(RetryDepths, RestDepths, Depths).
collect_recursive_steps([_|Steps], Depth, Ancestors, Entries, Depths) :-
    collect_recursive_steps(Steps,
                            Depth,
                            Ancestors,
                            Entries,
                            Depths).

collect_parallel_plans([], _, _, [], []).
collect_parallel_plans([Plan|Plans], Depth, Ancestors, Entries, Depths) :-
    collect_recursive_plan(Plan,
                           Depth,
                           Ancestors,
                           PlanEntries,
                           PlanDepths),
    collect_parallel_plans(Plans,
                           Depth,
                           Ancestors,
                           RestEntries,
                           RestDepths),
    append(PlanEntries, RestEntries, Entries),
    append(PlanDepths, RestDepths, Depths).

validate_recursive_depth(Stats, Budget) :-
    (   Stats.max_depth =< Budget.max_recursion_depth
    ->  true
    ;   throw(completion_fault(recursion_depth_exceeded(Stats.max_depth,
                                                         Budget.max_recursion_depth)))
    ).

validate_child_capabilities(plan(Steps), ChildCapabilities) :-
    maplist(validate_child_step_capabilities(ChildCapabilities), Steps).

validate_child_step_capabilities(ChildCapabilities, rlm(Child, _)) :-
    !,
    validate_plan_capabilities_only(Child, ChildCapabilities).
validate_child_step_capabilities(ChildCapabilities, parallel(Plans, _)) :-
    !,
    maplist(scan_child_capability_plan(ChildCapabilities), Plans).
validate_child_step_capabilities(ChildCapabilities, retry(_, Plan, _)) :-
    !,
    scan_child_capability_plan(ChildCapabilities, Plan).
validate_child_step_capabilities(_, _).

scan_child_capability_plan(ChildCapabilities, plan(Steps)) :-
    maplist(validate_child_step_capabilities(ChildCapabilities), Steps).

validate_child_plan_caps(ChildCapabilities, Plan) :-
    validate_plan_capabilities_only(Plan, ChildCapabilities).

validate_plan_capabilities_only(plan(Steps), Capabilities) :-
    maplist(validate_operation_capability(Capabilities), Steps).

validate_operation_capability(Capabilities, context(_, Action, _)) :-
    !,
    action_capability(Action, Capability),
    require_child_capability(Capability, Capabilities).
validate_operation_capability(Capabilities, model(Provider, _, _, _)) :-
    !,
    require_child_capability(model(Provider), Capabilities).
validate_operation_capability(Capabilities, tool(Name, _, _)) :-
    !,
    require_child_capability(tool(Name), Capabilities).
validate_operation_capability(Capabilities, rlm(Plan, _)) :-
    !,
    require_child_capability(rlm, Capabilities),
    validate_plan_capabilities_only(Plan, Capabilities).
validate_operation_capability(Capabilities, parallel(Plans, _)) :-
    !,
    require_child_capability(parallel, Capabilities),
    maplist(validate_child_plan_caps(Capabilities), Plans).
validate_operation_capability(Capabilities, retry(_, Plan, _)) :-
    !,
    require_child_capability(retry, Capabilities),
    validate_plan_capabilities_only(Plan, Capabilities).
validate_operation_capability(Capabilities, checkpoint(_)) :-
    !,
    require_child_capability(checkpoint, Capabilities).
validate_operation_capability(_, final(_)) :- !.
validate_operation_capability(_, _).

require_child_capability(Capability, Capabilities) :-
    (   memberchk(Capability, Capabilities)
    ->  true
    ;   throw(completion_fault(child_capability_denied(Capability)))
    ).

action_capability(peek(_), context(peek)).
action_capability(slice(_, _), context(slice)).
action_capability(search(_), context(search)).
action_capability(partition(_), context(partition)).
action_capability(map(_), context(map)).
action_capability(reduce(_), context(reduce)).

recursive_fault(Fault,
                error(completion_error{phase:validate,
                                       kind:recursive_plan_rejected,
                                       detail:Fault,
                                       message:"recursive plan failed depth/cycle/capability validation"})).

count_model_steps(plan(Steps), Count) :-
    maplist(step_model_count, Steps, Counts),
    sum_list(Counts, Count).

step_model_count(model(_, _, _, _), 1) :- !.
step_model_count(rlm(Plan, _), Count) :- !,
    count_model_steps(Plan, Count).
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
bound_plan_model_tokens(_, _, RemainingTokens, _) :-
    RemainingTokens =< 0,
    !,
    throw(completion_fault(token_budget_exhausted)).
bound_plan_model_tokens(Plan, Calls, RemainingTokens, Bounded) :-
    PerCall is max(1, RemainingTokens // Calls),
    bound_plan_tokens(Plan, PerCall, Bounded).

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
    (   get_dict(max_tokens, Options, Requested),
        integer(Requested), Requested > 0
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

/* -------------------------------------------------------------------------
 * Usage and trajectory
 * ---------------------------------------------------------------------- */

plan_usage(Result, Usage) :-
    plan_model_responses(Result, Responses),
    model_responses_usage(Responses, Usage).

plan_model_responses(Result, Responses) :-
    get_dict(model_responses, Result, Recorded),
    is_list(Recorded),
    !,
    Responses = Recorded.
plan_model_responses(Result, Responses) :-
    dict_pairs(Result.vars, _, Pairs),
    findall(Hash-Response,
            ( member(_-Response, Pairs),
              is_model_response(Response),
              term_hash(Response, Hash)
            ),
            RawPairs),
    sort(RawPairs, UniquePairs),
    findall(Response, member(_-Response, UniquePairs), Responses).

is_model_response(Value) :-
    is_dict(Value),
    get_dict(metadata, Value, Metadata),
    is_dict(Metadata),
    get_dict(http_status, Metadata, _),
    get_dict(usage, Value, _).

response_usage(Response, Usage) :-
    (   is_dict(Response),
        get_dict(usage, Response, Raw),
        is_dict(Raw)
    ->  usage_number(Raw, prompt_tokens, Prompt, PromptKnown),
        usage_number(Raw,
                     completion_tokens,
                     Completion,
                     CompletionKnown),
        usage_number(Raw, total_tokens, Total0, TotalKnown0),
        (   TotalKnown0 == true
        ->  Total = Total0,
            TokensKnown = true
        ;   PromptKnown == true,
            CompletionKnown == true
        ->  Total is Prompt+Completion,
            TokensKnown = true
        ;   Total = 0,
            TokensKnown = false
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
    ->  dict_default(prompt_tokens, Raw, 0, Prompt),
        dict_default(completion_tokens, Raw, 0, Completion),
        dict_default(total_tokens, Raw, 0, Total),
        dict_default(cost, Raw, 0.0, Cost),
        Usage = usage_summary{model_calls:1,
                              prompt_tokens:Prompt,
                              completion_tokens:Completion,
                              total_tokens:Total,
                              cost_usd:Cost,
                              cost_known:true,
                              tokens_known:true}
    ;   zero_usage(Zero),
        put_dict(model_calls, Zero, 1, Usage)
    ).

zero_usage(usage_summary{model_calls:0,
                         prompt_tokens:0,
                         completion_tokens:0,
                         total_tokens:0,
                         cost_usd:0.0,
                         cost_known:true,
                         tokens_known:true}).

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

usage_sum([], Usage) :- zero_usage(Usage).
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
    Remaining is max(0, Max-Used).

planner_event(Planner,
              model_event{id:root_planner,
                          parent:none,
                          depth:0,
                          reason:"select symbolic execution plan",
                          provider:Planner.provider_summary.provider,
                          selected_model:Planner.provider_summary.selected_model,
                          http_status:Planner.provider_summary.http_status,
                          usage:Planner.usage}).

completion_model_events(_, Result, Events) :-
    get_dict(model_events, Result, Recorded),
    is_list(Recorded),
    !,
    maplist(recorded_model_event, Recorded, Events).
completion_model_events(Plan, Result, Events) :-
    plan_model_events(Plan, Result.vars, 0, Events).

recorded_model_event(Recorded, Event) :-
    get_dict(id, Recorded, Id),
    get_dict(parent, Recorded, Parent),
    get_dict(depth, Recorded, Depth),
    get_dict(reason, Recorded, Reason),
    get_dict(provider, Recorded, Provider),
    get_dict(response, Recorded, Response),
    response_event_with_identity(Response,
                                 Id,
                                 Parent,
                                 Depth,
                                 Reason,
                                 Provider,
                                 Event).

plan_model_events(plan(Steps), Vars, Depth, Events) :-
    findall(Event,
            plan_model_event(Steps, Vars, Depth, Event),
            Events).

plan_model_event(Steps, Vars, Depth, Event) :-
    member(model(Provider, _, _, Bind), Steps),
    get_dict(Bind, Vars, Response),
    is_model_response(Response),
    response_event(Response, Depth, direct_plan_model, Provider, Event).
plan_model_event(Steps, Vars, Depth, Event) :-
    member(rlm(_, Bind), Steps),
    get_dict(Bind, Vars, Response),
    is_model_response(Response),
    ChildDepth is Depth+1,
    response_event(Response,
                   ChildDepth,
                   "model-selected recursive rlm step",
                   unknown,
                   Event).

response_event(Response, Depth, Reason, ProviderFallback, Event) :-
    term_string(Response, StableText,
                [quoted(true), numbervars(true)]),
    term_hash(StableText, Hash),
    format(atom(Id), 'model_~d', [Hash]),
    response_event_with_identity(Response,
                                 Id,
                                 root_planner,
                                 Depth,
                                 Reason,
                                 ProviderFallback,
                                 Event).

response_event_with_identity(Response,
                             Id,
                             Parent,
                             Depth,
                             Reason,
                             ProviderFallback,
                             model_event{id:Id,
                                         parent:Parent,
                                         depth:Depth,
                                         reason:Reason,
                                         provider:Provider,
                                         selected_model:Selected,
                                         http_status:Status,
                                         usage:Usage}) :-
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
Recursive decomposition is optional. An rlm step contains a nested typed plan, and that child may use only child capabilities.\n\
~s",
           [Query,
            Metadata,
            Capabilities,
            ChildCapabilities,
            ToolSchemas,
            Instruction]).

provider_options(Options, ProviderName, Provider) :-
    option_value(provider, Options, none, Explicit),
    (   Explicit == none
    ->  default_openrouter_model(Model),
        openrouter_provider(Model, Provider),
        option_value(provider_name, Options, openrouter, ProviderName)
    ;   Provider = Explicit,
        provider_name_from_term(Explicit, DefaultName),
        option_value(provider_name, Options, DefaultName, ProviderName)
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
    ;   tool_invocation_options(Options, InvocationOptions),
        tool_registry_runtime_tools(Registry,
                                    Capabilities,
                                    InvocationOptions,
                                    RegistryTools),
        tool_discover(Registry, Schemas)
    ),
    append(RegistryTools, DirectTools, Tools).

tool_invocation_options(Options, InvocationOptions) :-
    ToolMetadata = [authority_context, trace_id, session_id, runtime_id,
                    agent_id, graph_id, run_id],
    findall(Option,
            ( member(Name, ToolMetadata),
              option_value(Name, Options, none, Value),
              Value \== none,
              ground(Value),
              Option =.. [Name, Value]
            ),
            InvocationOptions).

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
    require_nonnegative_integer(Budget.max_recursion_depth,
                                max_recursion_depth),
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
completion_exception(rlm_cancelled(Token), _) :-
    !,
    throw(rlm_cancelled(Token)).
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
