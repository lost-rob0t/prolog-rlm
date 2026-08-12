:- module(rlm_chain_runtime,
          [ default_retry_policy/1,
            chain_invoke_with_transport/5,
            chain_stream_with_transport/6
          ]).

/** <module> Provider-neutral chain orchestration

This module owns provider routing, ordered middleware, bounded retries,
structured-output validation, usage aggregation, tracing, and streaming
orchestration. Provider-specific transports are injected by `rlm_chain`.
*/

:- use_module(library(option)).
:- use_module(rlm_chain_schema).

default_retry_policy(
    retry_policy{max_attempts:1,
                 base_delay:0.0,
                 max_delay:0.0,
                 retry_kinds:[provider_error,structured_validation]}).

/* -------------------------------------------------------------------------
 * Non-streaming invocation
 * ---------------------------------------------------------------------- */

chain_invoke_with_transport(ProviderSpec, Request0, Options, Transport, Outcome) :-
    catch(chain_invoke_guarded(ProviderSpec,
                               Request0,
                               Options,
                               Transport,
                               Outcome),
          Exception,
          chain_runtime_exception(Exception, Outcome)).

chain_invoke_guarded(ProviderSpec, Request0, Options, Transport, Outcome) :-
    require_options(Options),
    require_callable(Transport, transport),
    runtime_config(Options, Config),
    normalize_chain_request(Request0, Request1),
    message_count(Request1, MessageCount),
    trace_empty(Trace0),
    emit_trace(Config,
               request_normalized,
               _{message_count:MessageCount},
               Trace0,
               Trace1),
    run_request_middleware(Config,
                           Request1,
                           Trace1,
                           RequestOutcome,
                           Trace2),
    after_request_middleware(RequestOutcome,
                             ProviderSpec,
                             Config,
                             Transport,
                             Trace2,
                             Outcome).

after_request_middleware(error(Error), _, _, _, Trace, error(ChainError)) :-
    !,
    error_with_trace(Error, Trace, ChainError).
after_request_middleware(ok(Request0), ProviderSpec, Config, Transport, Trace0,
                         Outcome) :-
    normalize_chain_request(Request0, Request),
    select_provider(ProviderSpec,
                    Request,
                    Config,
                    Trace0,
                    RouteOutcome,
                    Trace1),
    (   RouteOutcome = ok(Provider)
    ->  usage_zero(Usage0),
        invoke_attempt(1,
                       Provider,
                       Request,
                       Config,
                       Transport,
                       Usage0,
                       Trace1,
                       Outcome)
    ;   RouteOutcome = error(Error),
        error_with_trace(Error, Trace1, ChainError),
        Outcome = error(ChainError)
    ).

invoke_attempt(Attempt,
               Provider,
               Request,
               Config,
               Transport,
               UsageAcc0,
               Trace0,
               Outcome) :-
    emit_trace(Config,
               attempt_started,
               _{attempt:Attempt, provider:Provider},
               Trace0,
               Trace1),
    call_transport(Transport, Provider, Request, ProviderOutcome),
    handle_provider_outcome(ProviderOutcome,
                            Attempt,
                            Provider,
                            Request,
                            Config,
                            Transport,
                            UsageAcc0,
                            Trace1,
                            Outcome).

handle_provider_outcome(error(Error),
                        Attempt,
                        Provider,
                        Request,
                        Config,
                        Transport,
                        UsageAcc,
                        Trace0,
                        Outcome) :-
    !,
    emit_trace(Config,
               provider_error,
               _{attempt:Attempt, provider:Provider, error:Error},
               Trace0,
               Trace1),
    retry_or_fail(provider_error,
                  Error,
                  Attempt,
                  Provider,
                  Request,
                  Config,
                  Transport,
                  UsageAcc,
                  Trace1,
                  Outcome).
handle_provider_outcome(ok(Response0),
                        Attempt,
                        Provider,
                        Request,
                        Config,
                        Transport,
                        UsageAcc0,
                        Trace0,
                        Outcome) :-
    !,
    response_usage(Response0, AttemptUsage),
    usage_add(UsageAcc0, AttemptUsage, UsageAcc),
    emit_trace(Config,
               provider_response,
               _{attempt:Attempt,
                 provider:Provider,
                 usage:AttemptUsage},
               Trace0,
               Trace1),
    run_response_middleware(Config,
                            Attempt,
                            Provider,
                            Response0,
                            Trace1,
                            MiddlewareOutcome,
                            Trace2),
    after_response_middleware(MiddlewareOutcome,
                              Attempt,
                              Provider,
                              Request,
                              Config,
                              Transport,
                              UsageAcc,
                              Trace2,
                              Outcome).
handle_provider_outcome(Other,
                        Attempt,
                        Provider,
                        _, _, _, _, Trace,
                        error(Error)) :-
    Error0 = chain_error{phase:provider,
                         kind:invalid_transport_outcome,
                         attempt:Attempt,
                         provider:Provider,
                         detail:Other,
                         message:"transport must return ok(Response) or error(Error)"},
    error_with_trace(Error0, Trace, Error).

after_response_middleware(error(Error), _, _, _, _, _, _, Trace,
                          error(ChainError)) :-
    !,
    error_with_trace(Error, Trace, ChainError).
after_response_middleware(ok(Response0),
                          Attempt,
                          Provider,
                          Request,
                          Config,
                          Transport,
                          UsageAcc,
                          Trace0,
                          Outcome) :-
    validate_response_shape(Response0, Response1),
    run_tool_call_middleware(Config,
                             Attempt,
                             Provider,
                             Response1,
                             Trace0,
                             ToolOutcome,
                             Trace1),
    (   ToolOutcome = ok(Response)
    ->  config_schema(Config, Schema),
        structured_response(Schema, Response, StructuredOutcome),
        handle_structured_outcome(StructuredOutcome,
                                  Response,
                                  Attempt,
                                  Provider,
                                  Request,
                                  Config,
                                  Transport,
                                  UsageAcc,
                                  Trace1,
                                  Outcome)
    ;   ToolOutcome = error(Error),
        error_with_trace(Error, Trace1, ChainError),
        Outcome = error(ChainError)
    ).

handle_structured_outcome(error(Error),
                          _, Attempt, Provider, Request, Config, Transport,
                          UsageAcc, Trace0, Outcome) :-
    !,
    emit_trace(Config,
               structured_validation_failed,
               _{attempt:Attempt, error:Error},
               Trace0,
               Trace1),
    retry_or_fail(structured_validation,
                  Error,
                  Attempt,
                  Provider,
                  Request,
                  Config,
                  Transport,
                  UsageAcc,
                  Trace1,
                  Outcome).
handle_structured_outcome(ok(Structured),
                          Response, Attempt, Provider, Request, Config, _,
                          UsageAcc, Trace0, Outcome) :-
    emit_trace(Config,
               structured_validation_succeeded,
               _{attempt:Attempt, structured:Structured},
               Trace0,
               Trace1),
    Completion0 = chain_completion{provider:Provider,
                                   request:Request,
                                   response:Response,
                                   structured:Structured,
                                   attempts:Attempt,
                                   usage:UsageAcc},
    run_completion_middleware(Config,
                              Attempt,
                              Provider,
                              Completion0,
                              Trace1,
                              CompletionOutcome,
                              Trace2),
    (   CompletionOutcome = ok(Completion)
    ->  emit_trace(Config,
                   completion,
                   _{attempts:Attempt,
                     provider:Provider,
                     usage:UsageAcc},
                   Trace2,
                   Trace3),
        trace_events(Trace3, Events),
        completion_result(Completion, Events, Result),
        Outcome = ok(Result)
    ;   CompletionOutcome = error(Error),
        error_with_trace(Error, Trace2, ChainError),
        Outcome = error(ChainError)
    ).

retry_or_fail(Kind,
              Error,
              Attempt,
              Provider,
              Request,
              Config,
              Transport,
              UsageAcc,
              Trace0,
              Outcome) :-
    config_retry_policy(Config, Policy),
    (   retry_allowed(Kind, Attempt, Policy)
    ->  retry_delay(Attempt, Policy, Delay),
        NextAttempt is Attempt+1,
        emit_trace(Config,
                   retry_scheduled,
                   _{kind:Kind,
                     failed_attempt:Attempt,
                     next_attempt:NextAttempt,
                     delay:Delay},
                   Trace0,
                   Trace1),
        config_sleep_handler(Config, SleepHandler),
        call_sleep(SleepHandler, Delay),
        invoke_attempt(NextAttempt,
                       Provider,
                       Request,
                       Config,
                       Transport,
                       UsageAcc,
                       Trace1,
                       Outcome)
    ;   Error0 = chain_error{phase:invoke,
                             kind:Kind,
                             attempt:Attempt,
                             provider:Provider,
                             cause:Error,
                             usage:UsageAcc,
                             message:"chain invocation exhausted its bounded retry policy"},
        error_with_trace(Error0, Trace0, ChainError),
        Outcome = error(ChainError)
    ).

retry_allowed(Kind, Attempt, Policy) :-
    get_dict(max_attempts, Policy, MaxAttempts),
    get_dict(retry_kinds, Policy, RetryKinds),
    Attempt < MaxAttempts,
    memberchk(Kind, RetryKinds).

retry_delay(Attempt, Policy, Delay) :-
    get_dict(base_delay, Policy, BaseDelay),
    get_dict(max_delay, Policy, MaxDelay),
    Exponent is max(0, Attempt-1),
    Multiplier is 2 ** Exponent,
    Raw is BaseDelay*Multiplier,
    Delay is min(Raw, MaxDelay).

/* -------------------------------------------------------------------------
 * Streaming invocation
 * ---------------------------------------------------------------------- */

chain_stream_with_transport(ProviderSpec,
                            Request0,
                            Options,
                            Transport,
                            EventHandler,
                            Outcome) :-
    catch(chain_stream_guarded(ProviderSpec,
                               Request0,
                               Options,
                               Transport,
                               EventHandler,
                               Outcome),
          Exception,
          chain_runtime_exception(Exception, Outcome)).

chain_stream_guarded(ProviderSpec,
                     Request0,
                     Options,
                     Transport,
                     EventHandler,
                     Outcome) :-
    require_options(Options),
    require_callable(Transport, stream_transport),
    require_callable(EventHandler, stream_event_handler),
    runtime_config(Options, Config),
    normalize_chain_request(Request0, Request1),
    message_count(Request1, MessageCount),
    trace_empty(Trace0),
    emit_trace(Config,
               request_normalized,
               _{message_count:MessageCount, streaming:true},
               Trace0,
               Trace1),
    run_request_middleware(Config,
                           Request1,
                           Trace1,
                           RequestOutcome,
                           Trace2),
    (   RequestOutcome = ok(Request0M)
    ->  normalize_chain_request(Request0M, Request),
        select_provider(ProviderSpec,
                        Request,
                        Config,
                        Trace2,
                        RouteOutcome,
                        Trace3),
        stream_after_route(RouteOutcome,
                           Request,
                           Config,
                           Transport,
                           EventHandler,
                           Trace3,
                           Outcome)
    ;   RequestOutcome = error(Error),
        error_with_trace(Error, Trace2, ChainError),
        Outcome = error(ChainError)
    ).

stream_after_route(error(Error), _, _, _, _, Trace, error(ChainError)) :-
    !,
    error_with_trace(Error, Trace, ChainError).
stream_after_route(ok(Provider), Request, Config, Transport, EventHandler,
                   Trace0, Outcome) :-
    emit_trace(Config,
               stream_started,
               _{provider:Provider},
               Trace0,
               Trace1),
    call_stream_transport(Transport,
                          Provider,
                          Request,
                          EventHandler,
                          StreamOutcome),
    stream_transport_outcome(StreamOutcome,
                             Provider,
                             Request,
                             Config,
                             Trace1,
                             Outcome).

stream_transport_outcome(error(Error), Provider, _, _, Trace,
                         error(ChainError)) :-
    !,
    Error0 = chain_error{phase:stream,
                         kind:provider_error,
                         provider:Provider,
                         cause:Error,
                         message:"streaming provider request failed"},
    error_with_trace(Error0, Trace, ChainError).
stream_transport_outcome(ok(StreamResult0), Provider, Request, Config, Trace0,
                         Outcome) :-
    !,
    (   is_dict(StreamResult0),
        get_dict(response, StreamResult0, Response0),
        get_dict(events, StreamResult0, Events),
        is_list(Events)
    ->  true
    ;   throw(chain_runtime_fault(stream,
                                  invalid_stream_result(StreamResult0)))
    ),
    run_response_middleware(Config,
                            1,
                            Provider,
                            Response0,
                            Trace0,
                            ResponseOutcome,
                            Trace1),
    (   ResponseOutcome = ok(Response1)
    ->  validate_response_shape(Response1, Response2),
        run_tool_call_middleware(Config,
                                 1,
                                 Provider,
                                 Response2,
                                 Trace1,
                                 ToolOutcome,
                                 Trace2),
        stream_after_tool_middleware(ToolOutcome,
                                     Events,
                                     Provider,
                                     Request,
                                     Config,
                                     Trace2,
                                     Outcome)
    ;   ResponseOutcome = error(Error),
        error_with_trace(Error, Trace1, ChainError),
        Outcome = error(ChainError)
    ).
stream_transport_outcome(Other, Provider, _, _, Trace, error(ChainError)) :-
    Error0 = chain_error{phase:stream,
                         kind:invalid_transport_outcome,
                         provider:Provider,
                         detail:Other,
                         message:"stream transport must return ok(StreamResult) or error(Error)"},
    error_with_trace(Error0, Trace, ChainError).

stream_after_tool_middleware(error(Error), _, _, _, _, Trace,
                             error(ChainError)) :-
    !,
    error_with_trace(Error, Trace, ChainError).
stream_after_tool_middleware(ok(Response), Events, Provider, Request, Config,
                             Trace0, Outcome) :-
    config_schema(Config, Schema),
    structured_response(Schema, Response, StructuredOutcome),
    (   StructuredOutcome = ok(Structured)
    ->  response_usage(Response, Usage),
        Completion0 = chain_completion{provider:Provider,
                                       request:Request,
                                       response:Response,
                                       structured:Structured,
                                       attempts:1,
                                       usage:Usage},
        run_completion_middleware(Config,
                                  1,
                                  Provider,
                                  Completion0,
                                  Trace0,
                                  CompletionOutcome,
                                  Trace1),
        stream_complete(CompletionOutcome,
                        Events,
                        Provider,
                        Usage,
                        Config,
                        Trace1,
                        Outcome)
    ;   StructuredOutcome = error(Error),
        Error0 = chain_error{phase:stream,
                             kind:structured_validation,
                             provider:Provider,
                             cause:Error,
                             message:"stream completed but structured output was invalid"},
        error_with_trace(Error0, Trace0, ChainError),
        Outcome = error(ChainError)
    ).

stream_complete(error(Error), _, _, _, _, Trace, error(ChainError)) :-
    !,
    error_with_trace(Error, Trace, ChainError).
stream_complete(ok(Completion), Events, Provider, Usage, Config, Trace0,
                ok(Result)) :-
    length(Events, EventCount),
    emit_trace(Config,
               stream_completed,
               _{provider:Provider,
                 event_count:EventCount,
                 usage:Usage},
               Trace0,
               Trace1),
    trace_events(Trace1, TraceEvents),
    completion_result(Completion, TraceEvents, Result0),
    put_dict(stream_events, Result0, Events, Result).

/* -------------------------------------------------------------------------
 * Request normalization and trusted routing
 * ---------------------------------------------------------------------- */

normalize_chain_request(Request0, Request) :-
    (   is_dict(Request0)
    ->  true
    ;   throw(chain_runtime_fault(request, invalid_request(Request0)))
    ),
    (   get_dict(messages, Request0, Messages0)
    ->  true
    ;   throw(chain_runtime_fault(request, missing_messages))
    ),
    messages_normalize(Messages0, MessagesOutcome),
    require_schema_success(MessagesOutcome, Messages),
    (   Messages == []
    ->  throw(chain_runtime_fault(request, empty_messages))
    ;   true
    ),
    dict_default(Request0, options, chain_options{}, GenerationOptions0),
    canonical_generation_options(GenerationOptions0, GenerationOptions),
    (   ground(GenerationOptions)
    ->  true
    ;   throw(chain_runtime_fault(request,
                                  invalid_generation_options(GenerationOptions0)))
    ),
    Request = model_request{messages:Messages,
                            options:GenerationOptions}.

canonical_generation_options(Options0, Options) :-
    (   is_dict(Options0)
    ->  canonical_generation_value(Options0, Options)
    ;   throw(chain_runtime_fault(request,
                                  invalid_generation_options(Options0)))
    ).

canonical_generation_value(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_generation_pair, Pairs0, Pairs),
    dict_pairs(Value, chain_options, Pairs).
canonical_generation_value(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_generation_value, Values0, Values).
canonical_generation_value(Value, Value).

canonical_generation_pair(Key-Value0, Key-Value) :-
    canonical_generation_value(Value0, Value).

message_count(Request, Count) :-
    get_dict(messages, Request, Messages),
    length(Messages, Count).

select_provider(provider(Name, ProviderConfig), _, Config, Trace0,
                Outcome, Trace) :-
    !,
    (   valid_provider(provider(Name, ProviderConfig))
    ->  Provider = provider(Name, ProviderConfig),
        Outcome = ok(Provider),
        emit_trace(Config,
                   route_selected,
                   _{provider:Provider, mode:direct},
                   Trace0,
                   Trace)
    ;   Outcome = error(chain_error{phase:route,
                                    kind:invalid_provider_spec,
                                    provider:provider(Name, ProviderConfig),
                                    message:"provider configuration must be ground provider(Name, Config)"}),
        Trace = Trace0
    ).
select_provider(route(Candidates), Request, Config, Trace0, Outcome, Trace) :-
    !,
    (   valid_candidates(Candidates)
    ->  true
    ;   Outcome = error(chain_error{phase:route,
                                    kind:invalid_candidates,
                                    candidates:Candidates,
                                    message:"route candidates must be a non-empty list of ground providers"}),
        Trace = Trace0
    ),
    (   nonvar(Outcome)
    ->  true
    ;   config_router(Config, Router),
        (   Router == none
        ->  Outcome = error(chain_error{phase:route,
                                        kind:missing_router,
                                        message:"route(Candidates) requires router(Closure)"}),
            Trace = Trace0
        ;   call_router(Router,
                        Request,
                        Candidates,
                        Selected,
                        RouterOutcome),
            finish_route_selection(RouterOutcome,
                                   Selected,
                                   Candidates,
                                   Config,
                                   Trace0,
                                   Outcome,
                                   Trace)
        )
    ).
select_provider(ProviderSpec, _, _, Trace,
                error(chain_error{phase:route,
                                  kind:invalid_provider_spec,
                                  provider:ProviderSpec,
                                  message:"provider spec must be provider(Name,Config) or route(Candidates)"}),
                Trace).

valid_provider(provider(Name, ProviderConfig)) :-
    nonvar(Name),
    ground(ProviderConfig).

valid_candidates(Candidates) :-
    is_list(Candidates),
    Candidates \== [],
    maplist(valid_provider, Candidates).

call_router(Router, Request, Candidates, Selected, Outcome) :-
    catch(( call(Router, Request, Candidates, Selected)
          -> Outcome = ok
          ;  Outcome = error(chain_error{phase:route,
                                         kind:router_failed,
                                         message:"provider router predicate failed"})
          ),
          Exception,
          router_exception(Exception, Outcome)).

router_exception(Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
router_exception(Exception,
                 error(chain_error{phase:route,
                                   kind:router_exception,
                                   exception:Safe,
                                   message:"provider router raised an exception"})) :-
    safe_exception(Exception, Safe).

finish_route_selection(error(Error), _, _, _, Trace,
                       error(Error), Trace) :-
    !.
finish_route_selection(ok, Selected, Candidates, Config, Trace0,
                       Outcome, Trace) :-
    (   memberchk(Selected, Candidates)
    ->  Outcome = ok(Selected),
        emit_trace(Config,
                   route_selected,
                   _{provider:Selected, mode:router},
                   Trace0,
                   Trace)
    ;   Outcome = error(chain_error{phase:route,
                                    kind:invalid_route_selection,
                                    selected:Selected,
                                    candidates:Candidates,
                                    message:"router selected a provider outside the declared candidates"}),
        Trace = Trace0
    ).

/* -------------------------------------------------------------------------
 * Ordered middleware
 * ---------------------------------------------------------------------- */

run_request_middleware(Config, Request, Trace0, Outcome, Trace) :-
    Context = chain_context{stage:request,
                            attempt:0,
                            provider:none},
    run_stage_middleware(request,
                         Config,
                         Context,
                         Request,
                         Trace0,
                         Outcome,
                         Trace).

run_response_middleware(Config, Attempt, Provider, Response, Trace0,
                        Outcome, Trace) :-
    Context = chain_context{stage:model_response,
                            attempt:Attempt,
                            provider:Provider},
    run_stage_middleware(model_response,
                         Config,
                         Context,
                         Response,
                         Trace0,
                         Outcome,
                         Trace).

run_completion_middleware(Config, Attempt, Provider, Completion, Trace0,
                          Outcome, Trace) :-
    Context = chain_context{stage:completion,
                            attempt:Attempt,
                            provider:Provider},
    run_stage_middleware(completion,
                         Config,
                         Context,
                         Completion,
                         Trace0,
                         Outcome,
                         Trace).

run_tool_call_middleware(Config, Attempt, Provider, Response0, Trace0,
                         Outcome, Trace) :-
    (   get_dict(tool_calls, Response0, ToolCalls0),
        is_list(ToolCalls0),
        ToolCalls0 \== []
    ->  Context = chain_context{stage:tool_call,
                                attempt:Attempt,
                                provider:Provider},
        middleware_tool_calls(ToolCalls0,
                              Config,
                              Context,
                              Trace0,
                              CallsOutcome,
                              Trace1),
        (   CallsOutcome = ok(ToolCalls)
        ->  put_dict(tool_calls, Response0, ToolCalls, Response),
            Outcome = ok(Response),
            Trace = Trace1
        ;   Outcome = CallsOutcome,
            Trace = Trace1
        )
    ;   Outcome = ok(Response0),
        Trace = Trace0
    ).

middleware_tool_calls([], _, _, Trace, ok([]), Trace).
middleware_tool_calls([Call0|Calls0], Config, Context, Trace0,
                      Outcome, Trace) :-
    run_stage_middleware(tool_call,
                         Config,
                         Context,
                         Call0,
                         Trace0,
                         OneOutcome,
                         Trace1),
    (   OneOutcome = ok(Call)
    ->  middleware_tool_calls(Calls0,
                              Config,
                              Context,
                              Trace1,
                              RestOutcome,
                              Trace2),
        (   RestOutcome = ok(Calls)
        ->  Outcome = ok([Call|Calls]),
            Trace = Trace2
        ;   Outcome = RestOutcome,
            Trace = Trace2
        )
    ;   Outcome = OneOutcome,
        Trace = Trace1
    ).

run_stage_middleware(Stage, Config, Context, Input, Trace0, Outcome, Trace) :-
    config_middleware(Config, Middleware),
    stage_handlers(Stage, Middleware, Handlers),
    run_handlers(Handlers,
                 Stage,
                 Context,
                 Input,
                 Config,
                 Trace0,
                 Outcome,
                 Trace).

stage_handlers(Stage, Middleware, Handlers) :-
    findall(Handler,
            member(middleware(Stage, Handler), Middleware),
            Handlers).

run_handlers([], _, _, Value, _, Trace, ok(Value), Trace).
run_handlers([Handler|Handlers], Stage, Context, Value0, Config, Trace0,
             Outcome, Trace) :-
    emit_trace(Config,
               middleware_started,
               _{stage:Stage},
               Trace0,
               Trace1),
    call_middleware(Handler, Stage, Context, Value0, HandlerOutcome),
    (   HandlerOutcome = ok(Value1)
    ->  emit_trace(Config,
                   middleware_completed,
                   _{stage:Stage},
                   Trace1,
                   Trace2),
        run_handlers(Handlers,
                     Stage,
                     Context,
                     Value1,
                     Config,
                     Trace2,
                     Outcome,
                     Trace)
    ;   Outcome = HandlerOutcome,
        Trace = Trace1
    ).

call_middleware(Handler, Stage, Context, Value0, Outcome) :-
    catch(( call(Handler, Context, Value0, Value)
          -> Outcome = ok(Value)
          ;  Outcome = error(chain_error{phase:middleware,
                                         kind:middleware_failed,
                                         stage:Stage,
                                         message:"middleware predicate failed"})
          ),
          Exception,
          middleware_exception(Stage, Exception, Outcome)).

middleware_exception(_, Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
middleware_exception(Stage, Exception,
                     error(chain_error{phase:middleware,
                                       kind:middleware_exception,
                                       stage:Stage,
                                       exception:Safe,
                                       message:"middleware predicate raised an exception"})) :-
    safe_exception(Exception, Safe).

/* -------------------------------------------------------------------------
 * Structured output, response validation, and usage
 * ---------------------------------------------------------------------- */

structured_response(none, _, ok(none)) :-
    !.
structured_response(Schema, Response, Outcome) :-
    (   get_dict(text, Response, Text),
        nonempty_text(Text)
    ->  structured_decode_validate(Schema, Text, Outcome)
    ;   Outcome = error(chain_schema_error{phase:structured_output,
                                           kind:validation_error,
                                           detail:missing_text,
                                           message:"structured output requires non-empty response text"})
    ).

validate_response_shape(Response, Response) :-
    is_dict(Response),
    !.
validate_response_shape(Response, _) :-
    throw(chain_runtime_fault(provider, invalid_response(Response))).

completion_result(Completion, Trace, Result) :-
    get_dict(provider, Completion, Provider),
    get_dict(request, Completion, Request),
    get_dict(response, Completion, Response),
    get_dict(structured, Completion, Structured),
    get_dict(attempts, Completion, Attempts),
    get_dict(usage, Completion, Usage),
    Result = chain_result{provider:Provider,
                          request:Request,
                          response:Response,
                          structured:Structured,
                          attempts:Attempts,
                          usage:Usage,
                          trace:Trace}.

response_usage(Response, Usage) :-
    (   is_dict(Response),
        get_dict(usage, Response, Usage0),
        is_dict(Usage0)
    ->  usage_value(Usage0, prompt_tokens, Prompt),
        usage_value(Usage0, completion_tokens, Completion),
        usage_value(Usage0, total_tokens, Total),
        usage_value(Usage0, cost, Cost),
        Usage = chain_usage{prompt_tokens:Prompt,
                            completion_tokens:Completion,
                            total_tokens:Total,
                            cost:Cost}
    ;   usage_zero(Usage)
    ).

usage_zero(chain_usage{prompt_tokens:0,
                       completion_tokens:0,
                       total_tokens:0,
                       cost:0.0}).

usage_add(A, B, Usage) :-
    get_dict(prompt_tokens, A, APrompt),
    get_dict(completion_tokens, A, ACompletion),
    get_dict(total_tokens, A, ATotal),
    get_dict(cost, A, ACost),
    get_dict(prompt_tokens, B, BPrompt),
    get_dict(completion_tokens, B, BCompletion),
    get_dict(total_tokens, B, BTotal),
    get_dict(cost, B, BCost),
    Prompt is APrompt+BPrompt,
    Completion is ACompletion+BCompletion,
    Total is ATotal+BTotal,
    Cost is ACost+BCost,
    Usage = chain_usage{prompt_tokens:Prompt,
                        completion_tokens:Completion,
                        total_tokens:Total,
                        cost:Cost}.

usage_value(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Raw), number(Raw)
    ->  Value = Raw
    ;   Key == cost
    ->  Value = 0.0
    ;   Value = 0
    ).

/* -------------------------------------------------------------------------
 * Trace
 * ---------------------------------------------------------------------- */

trace_empty(trace_state{sequence:0, reversed:[]}).

emit_trace(Config, Type, Fields0, Trace0, Trace) :-
    get_dict(sequence, Trace0, Previous),
    Sequence is Previous+1,
    canonical_trace_value(Fields0, Fields),
    Event = chain_event{sequence:Sequence,
                        type:Type,
                        fields:Fields},
    config_trace_handler(Config, TraceHandler),
    call_trace_handler(TraceHandler, Event),
    get_dict(reversed, Trace0, Reversed),
    Trace = trace_state{sequence:Sequence,
                        reversed:[Event|Reversed]}.

trace_events(Trace, Events) :-
    get_dict(reversed, Trace, Reversed),
    reverse(Reversed, Events).

call_trace_handler(none, _) :-
    !.
call_trace_handler(Handler, Event) :-
    catch(( call(Handler, Event)
          -> true
          ;  throw(chain_runtime_fault(trace, trace_handler_failed))
          ),
          Exception,
          trace_handler_exception(Exception)).

trace_handler_exception(Exception) :-
    control_exception(Exception),
    !,
    throw(Exception).
trace_handler_exception(chain_runtime_fault(Phase, Detail)) :-
    !,
    throw(chain_runtime_fault(Phase, Detail)).
trace_handler_exception(Exception) :-
    safe_exception(Exception, Safe),
    throw(chain_runtime_fault(trace, trace_handler_exception(Safe))).

canonical_trace_value(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_trace_pair, Pairs0, Pairs),
    dict_pairs(Value, chain_data, Pairs).
canonical_trace_value(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_trace_value, Values0, Values).
canonical_trace_value(Value, Value) :-
    ground(Value),
    !.
canonical_trace_value(Value, _) :-
    throw(chain_runtime_fault(trace, non_ground_trace_value(Value))).

canonical_trace_pair(Key-Value0, Key-Value) :-
    canonical_trace_value(Value0, Value).

error_with_trace(Error0, Trace, Error) :-
    trace_events(Trace, Events),
    (   is_dict(Error0)
    ->  put_dict(trace, Error0, Events, Error)
    ;   Error = chain_error{phase:invoke,
                            kind:error,
                            cause:Error0,
                            trace:Events,
                            message:"chain invocation failed"}
    ).

/* -------------------------------------------------------------------------
 * Configuration and trusted closures
 * ---------------------------------------------------------------------- */

runtime_config(Options, Config) :-
    option(retry_policy(Policy0), Options, default),
    normalize_retry_policy(Policy0, Policy),
    option(middleware(Middleware0), Options, []),
    normalize_middleware(Middleware0, Middleware),
    option(router(Router), Options, none),
    require_optional_callable(Router, router),
    option(structured_schema(Schema0), Options, none),
    compile_optional_schema(Schema0, Schema),
    option(trace_handler(TraceHandler), Options, none),
    require_optional_callable(TraceHandler, trace_handler),
    option(sleep_handler(SleepHandler),
           Options,
           rlm_chain_runtime:default_sleep),
    require_callable(SleepHandler, sleep_handler),
    Config = chain_config{retry_policy:Policy,
                          middleware:Middleware,
                          router:Router,
                          schema:Schema,
                          trace_handler:TraceHandler,
                          sleep_handler:SleepHandler}.

normalize_retry_policy(default, Policy) :-
    !,
    default_retry_policy(Policy).
normalize_retry_policy(Policy0, Policy) :-
    is_dict(Policy0),
    !,
    default_retry_policy(Default),
    dict_default(Policy0, max_attempts, 1, MaxAttempts0),
    dict_default(Default, max_attempts, 1, DefaultMaxAttempts),
    ( MaxAttempts0 == 1 -> MaxAttempts = DefaultMaxAttempts ; MaxAttempts = MaxAttempts0 ),
    get_dict(base_delay, Default, DefaultBaseDelay),
    get_dict(max_delay, Default, DefaultMaxDelay),
    get_dict(retry_kinds, Default, DefaultRetryKinds),
    dict_default(Policy0, base_delay, DefaultBaseDelay, BaseDelay),
    dict_default(Policy0, max_delay, DefaultMaxDelay, MaxDelay),
    dict_default(Policy0, retry_kinds, DefaultRetryKinds, RetryKinds),
    require_positive_integer(MaxAttempts, max_attempts),
    require_nonnegative_number(BaseDelay, base_delay),
    require_nonnegative_number(MaxDelay, max_delay),
    (   MaxDelay >= BaseDelay
    ->  true
    ;   throw(chain_runtime_fault(config,
                                  max_delay_below_base_delay(MaxDelay,
                                                            BaseDelay)))
    ),
    normalize_retry_kinds(RetryKinds, Kinds),
    Policy = retry_policy{max_attempts:MaxAttempts,
                          base_delay:BaseDelay,
                          max_delay:MaxDelay,
                          retry_kinds:Kinds}.
normalize_retry_policy(Policy, _) :-
    throw(chain_runtime_fault(config, invalid_retry_policy(Policy))).

normalize_retry_kinds(Kinds0, Kinds) :-
    (   is_list(Kinds0)
    ->  true
    ;   throw(chain_runtime_fault(config, invalid_retry_kinds(Kinds0)))
    ),
    forall(member(Kind, Kinds0),
           (   memberchk(Kind, [provider_error,structured_validation])
           ->  true
           ;   throw(chain_runtime_fault(config,
                                          unsupported_retry_kind(Kind)))
           )),
    sort(Kinds0, Kinds).

normalize_middleware(Middleware0, Middleware) :-
    (   is_list(Middleware0)
    ->  true
    ;   throw(chain_runtime_fault(config,
                                  invalid_middleware(Middleware0)))
    ),
    maplist(validate_middleware, Middleware0),
    Middleware = Middleware0.

validate_middleware(middleware(Stage, Handler)) :-
    memberchk(Stage, [request,model_response,tool_call,completion]),
    callable(Handler),
    !.
validate_middleware(Middleware) :-
    throw(chain_runtime_fault(config,
                              invalid_middleware_entry(Middleware))).

compile_optional_schema(none, none) :-
    !.
compile_optional_schema(Spec, Schema) :-
    structured_schema_compile(Spec, Outcome),
    require_schema_success(Outcome, Schema).

config_retry_policy(Config, Value) :- get_dict(retry_policy, Config, Value).
config_middleware(Config, Value) :- get_dict(middleware, Config, Value).
config_router(Config, Value) :- get_dict(router, Config, Value).
config_schema(Config, Value) :- get_dict(schema, Config, Value).
config_trace_handler(Config, Value) :- get_dict(trace_handler, Config, Value).
config_sleep_handler(Config, Value) :- get_dict(sleep_handler, Config, Value).

/* -------------------------------------------------------------------------
 * Transport, sleep, and control exceptions
 * ---------------------------------------------------------------------- */

call_transport(Transport, Provider, Request, Outcome) :-
    catch(( call(Transport, Provider, Request, Raw)
          -> Outcome = Raw
          ;  Outcome = error(chain_error{phase:provider,
                                         kind:transport_failed,
                                         message:"transport predicate failed"})
          ),
          Exception,
          transport_exception(Exception, Outcome)).

call_stream_transport(Transport, Provider, Request, Handler, Outcome) :-
    catch(( call(Transport, Provider, Request, Handler, Raw)
          -> Outcome = Raw
          ;  Outcome = error(chain_error{phase:stream,
                                         kind:transport_failed,
                                         message:"stream transport predicate failed"})
          ),
          Exception,
          transport_exception(Exception, Outcome)).

transport_exception(Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
transport_exception(Exception,
                    error(chain_error{phase:provider,
                                      kind:transport_exception,
                                      exception:Safe,
                                      message:"transport predicate raised an exception"})) :-
    safe_exception(Exception, Safe).

call_sleep(_, Delay) :-
    Delay =< 0,
    !.
call_sleep(Handler, Delay) :-
    catch(call(Handler, Delay),
          Exception,
          sleep_exception(Exception)).

sleep_exception(Exception) :-
    control_exception(Exception),
    !,
    throw(Exception).
sleep_exception(Exception) :-
    safe_exception(Exception, Safe),
    throw(chain_runtime_fault(retry, sleep_handler_exception(Safe))).

default_sleep(Delay) :- sleep(Delay).

control_exception(time_limit_exceeded).
control_exception(time_limit_exceeded(_)).
control_exception(error(time_limit_exceeded, _)).
control_exception(error(rlm_cancelled(_), _)).
control_exception(rlm_cancelled(_)).

/* -------------------------------------------------------------------------
 * Helpers and error conversion
 * ---------------------------------------------------------------------- */

require_schema_success(ok(Value), Value) :-
    !.
require_schema_success(error(Error), _) :-
    throw(chain_runtime_fault(schema, Error)).

require_options(Options) :-
    is_list(Options),
    !.
require_options(Options) :-
    throw(chain_runtime_fault(config, invalid_options(Options))).

require_callable(Value, _) :-
    callable(Value),
    !.
require_callable(Value, Name) :-
    throw(chain_runtime_fault(config, invalid_callable(Name, Value))).

require_optional_callable(none, _) :-
    !.
require_optional_callable(Value, Name) :-
    require_callable(Value, Name).

require_positive_integer(Value, _) :-
    integer(Value),
    Value > 0,
    !.
require_positive_integer(Value, Name) :-
    throw(chain_runtime_fault(config,
                              invalid_positive_integer(Name, Value))).

require_nonnegative_number(Value, _) :-
    number(Value),
    Value >= 0,
    !.
require_nonnegative_number(Value, Name) :-
    throw(chain_runtime_fault(config,
                              invalid_nonnegative_number(Name, Value))).

dict_default(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

nonempty_text(Value) :-
    string(Value),
    Value \== "",
    !.
nonempty_text(Value) :-
    atom(Value),
    Value \== ''.

chain_runtime_exception(Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
chain_runtime_exception(chain_runtime_fault(Phase, Detail), error(Error)) :-
    !,
    Error = chain_error{phase:Phase,
                        kind:runtime_error,
                        detail:Detail,
                        message:"chain runtime validation failed"}.
chain_runtime_exception(Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = chain_error{phase:runtime,
                        kind:exception,
                        exception:Safe,
                        message:"chain runtime raised an exception"}.

safe_exception(Exception, Safe) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).
