:- module(rlm_direct,
          [ rlm_direct/4,
            rlm_direct_async/4,
            rlm_direct_execute/4,
            rlm_direct_model_step/10
          ]).

/** <module> Bounded provider-native direct agent loop */

:- use_module(library(lists)).
:- use_module(rlm_async).
:- use_module(rlm_chain).
:- use_module(rlm_completion,
              [ completion_task_metadata/3,
                require_options/1,
                text_string/2,
                completion_runtime_budget/2,
                cancellation_option/3,
                register_current_thread/1,
                cleanup_cancellation/2,
                acquire_context/3,
                cleanup_context/2,
                require_context_metadata/2,
                provider_options/3,
                provider_tool_projection/6,
                completion_skill_messages/6,
                agent_identity_message/2,
                zero_usage/1,
                remaining_tokens/3,
                planner_token_limit/2,
                model_request_options/3,
                call_model/4,
                response_usage/2,
                usage_add/3,
                budget_usage_check/3,
                context_runtime_options/2,
                tool_invocation_options/2,
                plan_usage/2,
                check_cancelled/1
              ]).
:- use_module(rlm_context).
:- use_module(rlm_native_tool).
:- use_module(rlm_plan, []).
:- use_module(rlm_spec_lang, []).
:- use_module(rlm_verify, []).
:- use_module(rlm_tool).

rlm_direct_async(Query, Context, Options, Future) :-
    completion_task_metadata(direct, Options, Metadata),
    rlm_async_submit(rlm_direct:rlm_direct_execute(Query, Context, Options),
                     Metadata,
                     Future).

rlm_direct(Query, Context, Options, Outcome) :-
    rlm_direct_async(Query, Context, Options, Future),
    setup_call_cleanup(true,
                       rlm_future_await(Future, Outcome),
                       rlm_future_destroy(Future)).

rlm_direct_execute(Query, Context, Options, Outcome) :-
    catch(direct_guarded(Query, Context, Options, Outcome),
          Exception,
          direct_exception(Exception, Outcome)).

rlm_direct_model_step(Context,
                      Capabilities,
                      BaseOptions,
                      BaseBudget,
                      Token,
                      ProviderName,
                      Prompt,
                      RequestOptions,
                      NativeBudget,
                      Outcome) :-
    catch(direct_model_step_(Context,
                             Capabilities,
                             BaseOptions,
                             BaseBudget,
                             Token,
                             ProviderName,
                             Prompt,
                             RequestOptions,
                             NativeBudget,
                             Outcome),
          Exception,
          direct_model_step_exception(Exception, Outcome)).

direct_model_step_(Context,
                   Capabilities,
                   BaseOptions,
                   BaseBudget,
                   Token,
                   ProviderName,
                   Prompt,
                   RequestOptions,
                   NativeBudget,
                   Outcome) :-
    provider_options(BaseOptions, ConfiguredName, _),
    (   ProviderName == ConfiguredName
    ->  true
    ;   throw(direct_fault(direct_error{
                             phase:provider,
                             kind:provider_mismatch,
                             requested:ProviderName,
                             configured:ConfiguredName,
                             message:"typed-plan model provider is not the configured native session provider"}))
    ),
    direct_model_step_budget(BaseBudget, NativeBudget, ChildBudget),
    direct_model_step_token_limit(RequestOptions, BaseOptions, TokenLimit),
    ChildOptions = [ budget(ChildBudget),
                     capabilities(Capabilities),
                     cancel_token(Token),
                     native_request_options(RequestOptions),
                     planner_max_tokens(TokenLimit)
                   | BaseOptions
                   ],
    rlm_direct_execute(Prompt, Context, ChildOptions, DirectOutcome),
    direct_model_step_outcome(DirectOutcome, Outcome).

direct_model_step_budget(Base, Native, Budget) :-
    Tokens is Base.max_total_tokens-Native.used_total_tokens,
    Cost is max(0.0, Base.max_cost_usd-Native.used_cost_usd),
    Output is min(Base.max_output_bytes, Native.max_output_bytes),
    (   Tokens > 0,
        Output > 0
    ->  Budget = completion_budget{
                     max_iterations:Native.max_iterations,
                     max_recursion_depth:Base.max_recursion_depth,
                     max_concurrent_subcalls:Base.max_concurrent_subcalls,
                     max_model_calls:Native.max_model_calls,
                     max_tool_calls:Native.max_tool_calls,
                     max_context_ops:Native.max_context_ops,
                     max_total_tokens:Tokens,
                     max_cost_usd:Cost,
                     max_output_bytes:Output,
                     time_limit:Base.time_limit
                 }
    ;   throw(direct_fault(direct_error{
                             phase:budget,
                             kind:native_model_step_budget_exhausted,
                             remaining_tokens:Tokens,
                             remaining_output_bytes:Output,
                             message:"typed-plan model session has no remaining token or output budget"}))
    ).

direct_model_step_token_limit(RequestOptions, BaseOptions, Limit) :-
    (   get_dict(max_tokens, RequestOptions, Requested),
        integer(Requested), Requested > 0
    ->  Limit = Requested
    ;   get_dict(max_completion_tokens, RequestOptions, Requested),
        integer(Requested), Requested > 0
    ->  Limit = Requested
    ;   planner_token_limit(BaseOptions, Limit)
    ).

direct_model_step_outcome(ok(Result),
                          ok(native_model_execution{
                                 response:Result.response,
                                 responses:Result.responses,
                                 iterations:Result.iterations,
                                 model_calls:Result.turns,
                                 tool_calls:Result.tool_calls,
                                 context_calls:Result.context_calls,
                                 observation_bytes:Result.observation_bytes
                             })) :-
    !.
direct_model_step_outcome(error(Error), error(Error)).

direct_model_step_exception(Exception,
                            error(direct_error{
                                      phase:runtime,
                                      kind:native_model_step_exception,
                                      detail:Safe,
                                      message:"typed-plan native model session raised an exception"})) :-
    term_string(Exception, Safe, [quoted(true),numbervars(true)]).

direct_guarded(Query0, Context, Options, Outcome) :-
    require_options(Options),
    text_string(Query0, Query),
    completion_runtime_budget(Options, Budget),
    cancellation_option(Options, Token, OwnToken),
    setup_call_cleanup(
        register_current_thread(Token),
        call_with_time_limit(Budget.time_limit,
                             direct_with_context(Query,
                                                 Context,
                                                 Options,
                                                 Budget,
                                                 Token,
                                                 Outcome)),
        cleanup_cancellation(Token, OwnToken)).

direct_with_context(Query, Context, Options, Budget, Token, Outcome) :-
    check_cancelled(Token),
    acquire_context(Context, ContextRef, Owned),
    setup_call_cleanup(
        true,
        direct_with_handle(Query, ContextRef, Options, Budget, Token, Outcome),
        cleanup_context(ContextRef, Owned)).

direct_with_handle(Query, ContextRef, Options, Budget, Token, Outcome) :-
    context_metadata(ContextRef.handle, MetadataOutcome),
    require_context_metadata(MetadataOutcome, MetadataRef),
    provider_options(Options, ProviderName, Provider),
    provider_format(Options, ProviderName, Format),
    direct_capabilities(Options, Capabilities),
    direct_registry(Options, Registry),
    provider_tool_projection(Query,
                             Registry,
                             Capabilities,
                             Options,
                             Budget,
                             RegistrySchemas),
    native_catalog(Capabilities,
                   RegistrySchemas,
                   Format,
                   Bindings,
                   WireSchemas),
    direct_skill_messages(Query, ProviderName, Capabilities, Options, Budget,
                          SkillMessages),
    initial_messages(Query, MetadataRef.metadata, Options, SkillMessages,
                     Messages),
    zero_usage(Usage),
    State = direct_state{messages:Messages,
                         contexts:[direct_context{id:"input",
                                                  handle:ContextRef.handle,
                                                  source:input,
                                                  value:none}],
                         seen_call_ids:[],
                         responses:[],
                         iterations:0,
                         model_calls:0,
                         context_calls:0,
                         tool_calls:0,
                         output_bytes:0,
                         usage:Usage,
                         trajectory:[]},
    Runtime = direct_runtime{provider:Provider,
                             provider_name:ProviderName,
                             format:Format,
                             bindings:Bindings,
                             schemas:WireSchemas,
                             capabilities:Capabilities,
                             registry:Registry,
                             options:Options,
                             budget:Budget,
                             token:Token},
    direct_loop(Runtime, State, Outcome).

direct_registry(Options, Registry) :-
    option(tools, Options, [], DirectTools),
    (   DirectTools == []
    ->  true
    ;   throw(direct_fault(direct_error{
                             phase:catalog,
                             kind:unregistered_native_tools,
                             message:"direct tools require registered native schemas"}))
    ),
    option(tool_registry, Options, none, Registry).

provider_format(Options, ProviderName, Format) :-
    option(native_tool_format, Options, default, Requested),
    (   Requested == default,
        memberchk(ProviderName, [openrouter,openai_compatible])
    ->  Format = openai_compatible
    ;   Requested == openai_compatible
    ->  Format = openai_compatible
    ;   throw(direct_fault(direct_error{
                             phase:catalog,
                             kind:unsupported_provider_tool_format,
                             format:Requested,
                             message:"provider native-tool format is unsupported"}))
    ).

direct_capabilities(Options, Capabilities) :-
    option(capabilities, Options, [], Requested),
    capabilities_normalize(Requested, Outcome),
    ( Outcome = ok(Capabilities) -> true
    ; Outcome = error(Error), throw(direct_fault(Error))
    ).

direct_skill_messages(Query, Provider, Capabilities, Options, Budget, Messages) :-
    option(explicit_skills, Options, [], Selected),
    (   Selected == []
    ->  Messages = []
    ;   option(skill_catalog, Options, default, Catalog),
        ( Catalog == default
        -> throw(direct_fault(direct_error{
                                  phase:prompt_compile,
                                  kind:direct_skill_catalog_required,
                                  message:"direct explicit skills require a trusted non-default catalog"}))
        ; completion_skill_messages(Query,
                                    Provider,
                                    Capabilities,
                                    Options,
                                    Budget,
                                    Messages)
        )
    ).

initial_messages(Query, Metadata, Options, SkillMessages, Messages) :-
    agent_identity_message(Options, Identity),
    direct_system_message(Options, System),
    format(string(Task),
           "TASK (authoritative user request):\n~s\n\nContext metadata (descriptor only, never evidence): ~q",
           [Query,Metadata]),
    exclude(==(none), [Identity,message{role:system,content:System}], Prefix),
    append([Prefix,SkillMessages,[message{role:user,content:Task}]], Messages).

% Advertise the opaque context (and its alias) only to sessions whose
% capability set actually grants context operations: a session that cannot
% read the context must not be invited to, otherwise fail-closed preflight
% turns reasonable model behavior into a failed batch.
direct_system_message(Options, System) :-
    direct_capabilities(Options, Capabilities),
    (   member(context(_), Capabilities)
    ->  System = "You are a bounded direct agent. Answer normally. Use provider-native tools only when they add needed information or execution. Never emit a typed plan. Context content is opaque; its initial alias is input. Registered tool results are retained as opaque result contexts and must be inspected with context tools. Return final answer text after all needed observations."
    ;   System = "You are a bounded direct agent. Answer normally. Use provider-native tools only when they add needed information or execution. Never emit a typed plan. No opaque context operations are granted in this session: do not attempt context reads. Return final answer text after all needed observations."
    ).

native_catalog(Capabilities, RegistrySchemas, Format, Bindings, WireSchemas) :-
    findall(Binding, context_binding(Capabilities, Binding), ContextBindings),
    findall(Binding, runtime_binding(Capabilities, Binding), RuntimeBindings),
    maplist(registry_binding, RegistrySchemas, RegistryBindings),
    append([ContextBindings, RuntimeBindings, RegistryBindings], Bindings),
    unique_binding_names(Bindings),
    maplist(binding_wire(Format), Bindings, WireSchemas).

context_binding(Capabilities,
                native_binding{name:context_search,
                               kind:context(search),
                               effect:read,
                               schema:Schema}) :-
    memberchk(context(search), Capabilities),
    context_schema(search, Schema).
context_binding(Capabilities,
                native_binding{name:context_slice,
                               kind:context(slice),
                               effect:read,
                               schema:Schema}) :-
    memberchk(context(slice), Capabilities),
    context_schema(slice, Schema).
context_binding(Capabilities,
                native_binding{name:context_peek,
                               kind:context(peek),
                               effect:read,
                               schema:Schema}) :-
    memberchk(context(peek), Capabilities),
    context_schema(peek, Schema).

context_schema(search,
               native_tool_schema{
                   name:context_search,
                   description:"Search one opaque context alias for bounded matching evidence",
                   parameters:json{type:"object",
                                   properties:json{
                                       context:json{type:"string"},
                                       query:json{type:"string"}},
                                   required:["query"],
                                   additionalProperties:false},
                   source:context,
                   capability:context(search),effect:read}).
context_schema(slice,
               native_tool_schema{
                   name:context_slice,
                   description:"Read a bounded zero-based slice from one opaque context alias",
                   parameters:json{type:"object",
                                   properties:json{
                                       context:json{type:"string"},
                                       start:json{type:"integer",minimum:0},
                                       length:json{type:"integer",minimum:1}},
                                   required:["start","length"],
                                   additionalProperties:false},
                   source:context,
                   capability:context(slice),effect:read}).
context_schema(peek,
               native_tool_schema{
                   name:context_peek,
                   description:"Inspect metadata, head, tail, or one item from an opaque context alias",
                   parameters:json{type:"object",
                                   properties:json{
                                       context:json{type:"string"},
                                       selector:json{
                                           type:"object",
                                           properties:json{
                                               type:json{type:"string",
                                                         enum:["metadata","head","tail","item"]},
                                               index:json{type:"integer",minimum:0},
                                               count:json{type:"integer",minimum:1}},
                                           required:["type"],
                                           additionalProperties:false}},
                                   required:["selector"],
                                   additionalProperties:false},
                   source:context,
                   capability:context(peek),effect:read}).

runtime_binding(Capabilities,
                native_binding{name:spec_catalog,kind:spec(catalog),effect:read,
                               schema:Schema}) :-
    memberchk(spec(catalog), Capabilities),
    runtime_schema(spec_catalog, Schema).
runtime_binding(Capabilities,
                native_binding{name:spec_normalize,kind:spec(normalize),effect:read,
                               schema:Schema}) :-
    memberchk(spec(normalize), Capabilities),
    runtime_schema(spec_normalize, Schema).
runtime_binding(Capabilities,
                native_binding{name:spec_compile,kind:spec(freeze),effect:read,
                               schema:Schema}) :-
    memberchk(spec(freeze), Capabilities),
    runtime_schema(spec_compile, Schema).
runtime_binding(Capabilities,
                native_binding{name:spec_observe,kind:spec(observe),effect:read,
                               schema:Schema}) :-
    memberchk(spec(observe), Capabilities),
    runtime_schema(spec_observe, Schema).
runtime_binding(Capabilities,
                native_binding{name:spec_verify,kind:spec(verify),effect:read,
                               schema:Schema}) :-
    memberchk(spec(verify), Capabilities),
    runtime_schema(spec_verify, Schema).
runtime_binding(Capabilities,
                native_binding{name:typed_plan_execute,kind:plan(execute),effect:read,
                               schema:Schema}) :-
    memberchk(plan(execute), Capabilities),
    runtime_schema(typed_plan_execute, Schema).

runtime_schema(spec_catalog,
               native_tool_schema{name:spec_catalog,
                                  description:"Inspect the closed SPEC language and trusted assertion catalog",
                                  parameters:json{type:"object",properties:json{},
                                                  required:[],additionalProperties:false},
                                  source:runtime,capability:spec(catalog),effect:read}).
runtime_schema(spec_normalize,
               native_tool_schema{name:spec_normalize,
                                  description:"Normalize one closed declarative SPEC source string without executing it",
                                  parameters:json{type:"object",
                                                  properties:json{source:json{type:"string"}},
                                                  required:["source"],additionalProperties:false},
                                  source:runtime,capability:spec(normalize),effect:read}).
runtime_schema(spec_compile,
               native_tool_schema{name:spec_compile,
                                  description:"Validate and freeze one declarative SPEC source against the host assertion registry",
                                  parameters:json{type:"object",
                                                  properties:json{source:json{type:"string"},
                                                                  series:json{type:"string"},
                                                                  version:json{type:"integer",minimum:1}},
                                                  required:["source","series","version"],
                                                  additionalProperties:false},
                                  source:runtime,capability:spec(freeze),effect:read}).
runtime_schema(spec_observe,
               native_tool_schema{name:spec_observe,
                                  description:"Collect trusted observations for a frozen SPEC retained in an opaque result context",
                                  parameters:json{type:"object",
                                                  properties:json{spec_context:json{type:"string"}},
                                                  required:["spec_context"],additionalProperties:false},
                                  source:runtime,capability:spec(observe),effect:read}).
runtime_schema(spec_verify,
               native_tool_schema{name:spec_verify,
                                  description:"Purely verify retained observations against a retained frozen SPEC",
                                  parameters:json{type:"object",
                                                  properties:json{spec_context:json{type:"string"},
                                                                  observations_context:json{type:"string"}},
                                                  required:["spec_context","observations_context"],
                                                  additionalProperties:false},
                                  source:runtime,capability:spec(verify),effect:read}).
runtime_schema(typed_plan_execute,
               native_tool_schema{name:typed_plan_execute,
                                  description:"Validate and execute one complete typed plan through the canonical plan runtime",
                                  parameters:json{type:"object",
                                                  properties:json{plan:json{type:"object"}},
                                                  required:["plan"],additionalProperties:false},
                                  source:runtime,capability:plan(execute),effect:read}).

registry_binding(RuntimeSchema,
                 native_binding{name:Name,
                                kind:tool(Name),
                                effect:Effect,
                                schema:Native}) :-
    native_tool_schema_normalize(RuntimeSchema, Outcome),
    require_native(Outcome, Native),
    Name = Native.name,
    Effect = Native.effect.

binding_wire(Format, Binding, Wire) :-
    native_tool_schema_wire(Format, Binding.schema, Outcome),
    require_native(Outcome, Wire).

require_native(ok(Value), Value) :- !.
require_native(error(Error), _) :- throw(direct_fault(Error)).

unique_binding_names(Bindings) :-
    findall(Name, (member(B, Bindings), Name=B.name), Names),
    sort(Names, Unique),
    same_length(Names, Unique),
    !.
unique_binding_names(_) :-
    throw(direct_fault(direct_error{
                           phase:catalog,
                           kind:duplicate_native_tool_name,
                           message:"native tool names must be unique"})).

direct_loop(Runtime, State0, Outcome) :-
    check_cancelled(Runtime.token),
    model_admission(Runtime, State0, Admission),
    (   Admission = error(Error)
    ->  Outcome = error(Error)
    ;   provider_turn(Runtime, State0, Outcome)
    ).

model_admission(Runtime, State, error(Error)) :-
    State.model_calls >= Runtime.budget.max_model_calls,
    !,
    state_error(State, budget, model_call_budget_exhausted,
                _{limit:Runtime.budget.max_model_calls},
                "direct model-call budget is exhausted", Error).
model_admission(Runtime, State, error(Error)) :-
    State.iterations >= Runtime.budget.max_iterations,
    !,
    state_error(State, budget, iteration_budget_exhausted,
                _{limit:Runtime.budget.max_iterations},
                "direct iteration budget is exhausted", Error).
model_admission(Runtime, State, error(Error)) :-
    remaining_tokens(Runtime.budget.max_total_tokens,
                     State.usage.total_tokens,
                     Remaining),
    Remaining =< 0,
    !,
    state_error(State, budget, token_budget_exhausted,
                _{limit:Runtime.budget.max_total_tokens},
                "direct token budget is exhausted", Error).
model_admission(_, _, ok).

provider_turn(Runtime, State0, Outcome) :-
    remaining_tokens(Runtime.budget.max_total_tokens,
                     State0.usage.total_tokens,
                     Remaining),
    planner_token_limit(Runtime.options, Requested),
    Limit is max(1, min(Requested, Remaining)),
    model_request_options(Runtime.options, Limit, BaseOptions),
    native_request_options(Runtime.options, Limit, BaseOptions, StepOptions),
    request_options(Runtime.schemas, StepOptions, RequestOptions),
    Request = model_request{messages:State0.messages,options:RequestOptions},
    call_model(Runtime.options, Runtime.provider, Request, ModelOutcome),
    after_provider(ModelOutcome, Runtime, State0, Outcome).

request_options([], Options, Options) :- !.
request_options(Schemas, Options0, Options) :-
    put_dict(_{tools:Schemas,tool_choice:auto}, Options0, Options).

native_request_options(Options, Limit, Base, RequestOptions) :-
    option(native_request_options, Options, none, Overrides),
    (   Overrides == none
    ->  Merged0 = Base
    ;   is_dict(Overrides)
    ->  reject_native_request_control(Overrides),
        put_dict(Overrides, Base, Merged0)
    ;   throw(direct_fault(direct_error{
                             phase:provider,
                             kind:invalid_native_request_options,
                             message:"typed-plan model options must be a JSON object"}))
    ),
    (   del_dict(max_completion_tokens, Merged0, _, Merged1)
    ->  true
    ;   Merged1 = Merged0
    ),
    put_dict(max_tokens, Merged1, Limit, RequestOptions).

reject_native_request_control(Options) :-
    member(Key, [messages,tools,tool_choice,stream]),
    get_dict(Key, Options, _),
    !,
    throw(direct_fault(direct_error{
                           phase:provider,
                           kind:reserved_native_request_option,
                           option:Key,
                           message:"typed-plan model options cannot replace native session controls"})).
reject_native_request_control(_).

after_provider(error(Cause), _, State, error(Error)) :-
    !,
    state_error(State, provider, provider_failed, _{cause:Cause},
                "direct provider request failed", Error).
after_provider(ok(Response), Runtime, State0, Outcome) :-
    check_cancelled(Runtime.token),
    response_usage(Response, CallUsage),
    usage_add(State0.usage, CallUsage, Usage),
    ModelCalls is State0.model_calls+1,
    Iterations is State0.iterations+1,
    Responses = [Response|State0.responses],
    model_event(Response, ModelCalls, Event),
    append(State0.trajectory, [Event], Trajectory),
    put_dict(_{iterations:Iterations,model_calls:ModelCalls,responses:Responses,
               usage:Usage,trajectory:Trajectory},
             State0, State1),
    budget_usage_check(Runtime.budget, Usage, BudgetOutcome),
    (   BudgetOutcome = error(BudgetError)
    ->  state_error(State1, budget, provider_usage_exceeded,
                    _{cause:BudgetError},
                    "direct provider usage exceeded its budget", Error),
        Outcome = error(Error)
    ;   normalize_response_calls(Response, CallsOutcome),
        after_call_normalization(CallsOutcome,
                                 Response,
                                 Runtime,
                                 State1,
                                 Outcome)
    ).

normalize_response_calls(Response, Outcome) :-
    (   is_dict(Response),
        get_dict(tool_calls, Response, RawCalls),
        is_list(RawCalls)
    ->  native_tool_calls_normalize(RawCalls, Outcome)
    ;   Outcome = error(native_tool_error{
                            kind:unsupported_tool_call_format,
                            phase:normalize,
                            message:"provider response lacks a tool_calls list"})
    ).

after_call_normalization(error(Cause), _, _, State, error(Error)) :-
    !,
    error_kind(Cause, malformed_native_tool_calls, Kind),
    state_error(State, native_call, Kind, _{cause:Cause},
                "provider native calls were rejected", Error).
after_call_normalization(ok([]), Response, Runtime, State, Outcome) :-
    !,
    finish_direct(Response, Runtime, State, Outcome).
after_call_normalization(ok(Calls), Response, Runtime, State0, Outcome) :-
    preflight_calls(Calls, Runtime, State0, Preflight),
    (   Preflight = error(Cause)
    ->  error_kind(Cause, native_call_rejected, Kind),
        state_error(State0, native_call, Kind, _{cause:Cause},
                    "native call batch failed preflight", Error),
        Outcome = error(Error)
    ;   Preflight = ok(Resolved),
        assistant_message(Response, Calls, AssistantOutcome),
        after_assistant_message(AssistantOutcome,
                                Calls,
                                Resolved,
                                Runtime,
                                State0,
                                Outcome)
    ).

preflight_calls(Calls, Runtime, State, Outcome) :-
    catch(( fresh_call_ids(Calls, State.seen_call_ids),
            maplist(resolve_call(Runtime.bindings), Calls, Resolved),
            validate_effect_batch(Resolved),
            maplist(validate_call_arguments(Runtime), Resolved),
            batch_budget(Resolved, Runtime, State),
            Outcome = ok(Resolved)
          ),
          direct_fault(Error),
          Outcome = error(Error)).

fresh_call_ids([], _).
fresh_call_ids([Call|Calls], Seen) :-
    (   memberchk(Call.id, Seen)
    ->  throw(direct_fault(direct_error{
                              phase:native_call,kind:duplicate_call_id,
                              call_id:Call.id,
                              message:"provider reused a native call ID"}))
    ;   fresh_call_ids(Calls, Seen)
    ).

resolve_call(Bindings, Call, resolved_call{call:Call,binding:Binding}) :-
    (   member(Binding, Bindings), Binding.name == Call.name
    ->  true
    ;   throw(direct_fault(direct_error{
                              phase:catalog,kind:unavailable_tool_schema,
                              tool:Call.name,
                              message:"call is absent from active native schemas"}))
    ).

validate_effect_batch(Resolved) :-
    include(effectful_call, Resolved, Effectful),
    ( Effectful == [] -> true
    ; Resolved = [_] -> true
    ; throw(direct_fault(direct_error{
                             phase:native_call,
                             kind:effectful_batch_unsupported,
                             message:"effectful native calls must be requested singly"}))
    ).

effectful_call(Resolved) :- Resolved.binding.effect \== read.

validate_call_arguments(Runtime, Resolved) :-
    Resolved.binding.kind = tool(Name),
    !,
    tool_validate_arguments(Runtime.registry,
                            Name,
                            Resolved.call.arguments,
                            Validation),
    ( Validation == ok -> true
    ; Validation = error(Error),
      throw(direct_fault(direct_error{
                            phase:schema,kind:malformed_arguments,
                            tool:Name,cause:Error,
                            message:"registered-tool arguments failed schema validation"}))
    ).
validate_call_arguments(_, Resolved) :-
    Resolved.binding.kind = context(_),
    !,
    context_arguments(Resolved.binding.kind, Resolved.call.arguments, _).
validate_call_arguments(_, Resolved) :-
    runtime_arguments(Resolved.binding.kind, Resolved.call.arguments).

batch_budget(Resolved, Runtime, State) :-
    include(context_call, Resolved, Contexts),
    include(tool_call, Resolved, Tools),
    length(Contexts, ContextCount),
    length(Tools, ToolCount),
    ContextTotal is State.context_calls+ContextCount,
    ToolTotal is State.tool_calls+ToolCount,
    ( ContextTotal =< Runtime.budget.max_context_ops -> true
    ; throw(direct_fault(direct_error{
                             phase:budget,kind:context_call_budget_exhausted,
                             used:State.context_calls,
                             limit:Runtime.budget.max_context_ops,
                             message:"direct context-call budget is exhausted"}))
    ),
    ( ToolTotal =< Runtime.budget.max_tool_calls -> true
    ; throw(direct_fault(direct_error{
                             phase:budget,kind:tool_call_budget_exhausted,
                             used:State.tool_calls,
                             limit:Runtime.budget.max_tool_calls,
                             message:"direct tool-call budget is exhausted"}))
    ).

context_call(R) :- R.binding.kind = context(_).
tool_call(R) :- R.binding.kind \= context(_).

assistant_message(Response, Calls, Outcome) :-
    (   get_dict(assistant, Response, Assistant0)
    ->  message_normalize(Assistant0, Normalized),
        validate_assistant_message(Normalized, Calls, Outcome)
    ;   Outcome = error(direct_error{
                            phase:provider,
                            kind:missing_assistant_message,
                            message:"provider response lacks an assistant message"})
    ).

validate_assistant_message(error(Cause), _, error(Cause)) :-
    !.
validate_assistant_message(ok(Assistant), Calls, Outcome) :-
    (   Assistant.role == assistant,
        get_dict(tool_calls, Assistant, RawCalls),
        native_tool_calls_normalize(RawCalls, ok(AssistantCalls)),
        AssistantCalls == Calls
    ->  Outcome = ok(Assistant)
    ;   Outcome = error(direct_error{
                            phase:provider,
                            kind:assistant_tool_calls_mismatch,
                            message:"assistant message does not match the normalized provider call batch"})
    ).

after_assistant_message(error(Cause), _, _, _, State, error(Error)) :-
    !,
    error_kind(Cause, unsupported_tool_call_format, Kind),
    state_error(State, provider, Kind,
                _{cause:Cause},
                "provider assistant tool-call message is malformed", Error).
after_assistant_message(ok(Assistant), Calls, Resolved, Runtime, State0, Outcome) :-
    append(State0.messages, [Assistant], Messages),
    findall(Id, (member(Call, Calls), Id=Call.id), Ids),
    append(Ids, State0.seen_call_ids, Seen),
    put_dict(_{messages:Messages,seen_call_ids:Seen}, State0, State),
    execute_calls(Resolved, Runtime, State, Outcome).

execute_calls([], Runtime, State, Outcome) :-
    !,
    direct_loop(Runtime, State, Outcome).
execute_calls([Resolved|Calls], Runtime, State0, Outcome) :-
    check_cancelled(Runtime.token),
    charge_call(Resolved, State0, State1),
    execute_one(Resolved, Runtime, State1, Execution),
    after_execution(Execution, Resolved, Calls, Runtime, State1, Outcome).

charge_call(Resolved, State0, State) :-
    ( Resolved.binding.kind = context(_)
    -> Count is State0.context_calls+1, put_dict(context_calls, State0, Count, State)
    ; Count is State0.tool_calls+1, put_dict(tool_calls, State0, Count, State)
    ).

execute_one(Resolved, Runtime, State, context(ContextOutcome)) :-
    Resolved.binding.kind = context(Operation),
    !,
    context_arguments(Resolved.binding.kind, Resolved.call.arguments, Args),
    context_handle(Args.context, State.contexts, Handle),
    context_runtime_options(Runtime.options, ContextOptions),
    call_context(Operation, Handle, Args, ContextOptions, ContextOutcome).
execute_one(Resolved, Runtime, _, tool(Result)) :-
    Resolved.binding.kind = tool(Name),
    tool_invocation_options(Runtime.options, InvocationOptions),
    tool_invoke_execute(Runtime.registry,
                        Runtime.capabilities,
                        Name,
                        Resolved.call.arguments,
                        InvocationOptions,
                        Result).
execute_one(Resolved, Runtime, State, runtime(Result)) :-
    runtime_operation(Resolved.binding.kind,
                      Resolved.call.arguments,
                      Runtime,
                      State,
                      Result).

after_execution(context(error(Cause)), _, _, _, State, error(Error)) :-
    !,
    state_error(State, context, context_operation_failed, _{cause:Cause},
                "native context operation failed", Error).
after_execution(context(ok(ContextResult)), Resolved, Calls, Runtime, State0,
                Outcome) :-
    !,
    Call = Resolved.call,
    Result = native_tool_result{call_id:Call.id,name:Call.name,
                                operation:Resolved.binding.kind,
                                value:ContextResult.value,
                                truncated:ContextResult.truncated,
                                trace:ContextResult.trace},
    Event = direct_event{type:native_context,call_id:Call.id,
                         name:Call.name,result:Result},
    append_observation(Call, Result, Event, Runtime, State0, StateOutcome),
    continue_observation(StateOutcome, Calls, Runtime, Outcome).
after_execution(tool(ToolResult), Resolved, Calls, Runtime, State, Outcome) :-
    after_tool(ToolResult, Resolved, Calls, Runtime, State, Outcome).
after_execution(runtime(error(Cause)), _, _, _, State, error(Error)) :-
    !,
    error_kind(Cause, runtime_operation_failed, Kind),
    state_error(State, runtime, Kind, _{cause:Cause},
                "native runtime operation failed", Error).
after_execution(runtime(ok(Execution)), Resolved, Calls, Runtime, State0,
                Outcome) :-
    charge_runtime_usage(Execution, Runtime, State0, UsageOutcome),
    after_runtime_usage(UsageOutcome,
                        Execution,
                        Resolved,
                        Calls,
                        Runtime,
                        Outcome).

after_tool(ToolResult, Resolved, _, _, State, error(Error)) :-
    ToolResult.outcome = error(Cause),
    !,
    tool_failure_state(ToolResult, Resolved, error, State, State1),
    error_kind(Cause, tool_execution_failed, Kind),
    state_error(State1, tool, Kind, _{cause:Cause},
                "native registered-tool execution failed", Error).
after_tool(ToolResult, Resolved, _, _, State, error(Error)) :-
    ToolResult.outcome = approval_required(Pending),
    !,
    tool_failure_state(ToolResult, Resolved, approval_required, State, State1),
    state_error(State1, authority, approval_required, _{pending:Pending},
                "native tool requires host approval", Error).
after_tool(ToolResult, Resolved, _, _, State, error(Error)) :-
    Resolved.binding.effect \== read,
    ToolResult.trace.status == replayed,
    !,
    tool_failure_state(ToolResult, Resolved, replayed, State, State1),
    state_error(State1, effect, effectful_replay_denied, _{},
                "replayed effect is not fresh retry authority", Error).
after_tool(ToolResult, Resolved, Calls, Runtime, State0, Outcome) :-
    ToolResult.outcome = ok(Execution),
    retain_result(Resolved, Execution.value, Retained),
    after_retained(Retained,
                   ToolResult,
                   Resolved,
                   Calls,
                   Runtime,
                   State0,
                   Outcome).

tool_failure_state(ToolResult, Resolved, Status, State0, State) :-
    Event = direct_event{type:native_tool,call_id:Resolved.call.id,
                         name:Resolved.call.name,status:Status,
                         trace:ToolResult.trace},
    append(State0.trajectory, [Event], Events),
    put_dict(trajectory, State0, Events, State).

retain_result(Resolved, Value, Outcome) :-
    context_register(terms([Value]), [], Register),
    ( Register = ok(ContextRef)
    -> format(string(Alias), "result_~s", [Resolved.call.id]),
       Outcome = ok(direct_context{id:Alias,
                                   handle:ContextRef.handle,
                                   source:Resolved.binding.kind,
                                   value:Value},
                    ContextRef)
    ; Register = error(Error), Outcome = error(Error)
    ).

after_runtime_usage(error(Error), _, _, _, _, error(Error)) :-
    !.
after_runtime_usage(ok(State0), Execution, Resolved, Calls, Runtime, Outcome) :-
    Trace = runtime_trace{operation:Resolved.binding.kind,
                          status:ok,
                          nested_iterations:Execution.iterations,
                          nested_model_calls:Execution.model_calls,
                          nested_tool_calls:Execution.tool_calls,
                          nested_context_calls:Execution.context_calls},
    Synthetic = tool_async_result{outcome:ok(tool_execution{
                                                 value:Execution.value,
                                                 trace:Trace}),
                                  trace:Trace},
    after_tool(Synthetic, Resolved, Calls, Runtime, State0, Outcome).

charge_runtime_usage(Execution, Runtime, State0, Outcome) :-
    usage_add(State0.usage, Execution.usage, Usage),
    ModelCalls is State0.model_calls+Execution.model_calls,
    Iterations is State0.iterations+Execution.iterations,
    ToolCalls is State0.tool_calls+Execution.tool_calls,
    ContextCalls is State0.context_calls+Execution.context_calls,
    put_dict(_{usage:Usage,iterations:Iterations,model_calls:ModelCalls,
               tool_calls:ToolCalls,context_calls:ContextCalls},
             State0, State),
    budget_usage_check(Runtime.budget, Usage, BudgetOutcome),
    (   Iterations =< Runtime.budget.max_iterations,
        ModelCalls =< Runtime.budget.max_model_calls,
        ToolCalls =< Runtime.budget.max_tool_calls,
        ContextCalls =< Runtime.budget.max_context_ops,
        BudgetOutcome == ok
    ->  Outcome = ok(State)
    ;   state_error(State, budget, nested_runtime_budget_exhausted,
                    _{budget_outcome:BudgetOutcome},
                    "native runtime operation exhausted the shared direct budget",
                    Error),
        Outcome = error(Error)
    ).

after_retained(error(Cause), _, _, _, _, State, error(Error)) :-
    !,
    state_error(State, context, result_context_registration_failed,
                _{cause:Cause},
                "tool result could not be retained as context", Error).
after_retained(ok(Context, ContextRef), ToolResult, Resolved, Calls,
               Runtime, State0, Outcome) :-
    setup_call_cleanup(
        true,
        with_retained(Context, ContextRef, ToolResult, Resolved, Calls,
                      Runtime, State0, Outcome),
        context_delete(ContextRef.handle, _)).

with_retained(Context, ContextRef, ToolResult, Resolved, Calls,
              Runtime, State0, Outcome) :-
    Call = Resolved.call,
    Reference = native_context_ref{id:Context.id,
                                   source:Resolved.binding.kind,
                                   metadata:ContextRef.metadata},
    Result = native_tool_result{call_id:Call.id,name:Call.name,
                                operation:Resolved.binding.kind,
                                value:Reference,truncated:false,
                                trace:ToolResult.trace},
    Event = direct_event{type:native_tool,call_id:Call.id,name:Call.name,
                         result:Result,trace:ToolResult.trace},
    append_observation(Call, Result, Event, Runtime, State0, StateOutcome),
    ( StateOutcome = error(Error) -> Outcome = error(Error)
    ; StateOutcome = ok(State1),
      put_dict(contexts, State1, [Context|State1.contexts], State2),
      execute_calls(Calls, Runtime, State2, Outcome)
    ).

append_observation(Call, Result, Event, Runtime, State0, Outcome) :-
    native_tool_result_message(Call, Result, MessageOutcome),
    ( MessageOutcome = error(Cause)
    -> state_error(State0, native_result, invalid_tool_result,
                   _{cause:Cause}, "native result correlation failed", Error),
       Outcome = error(Error)
    ; MessageOutcome = ok(Message),
      text_bytes(Message.content, Bytes),
      Total is State0.output_bytes+Bytes,
      ( Total =< Runtime.budget.max_output_bytes
      -> append(State0.messages, [Message], Messages),
         append(State0.trajectory, [Event], Events),
         put_dict(_{messages:Messages,trajectory:Events,output_bytes:Total},
                  State0, State),
         Outcome = ok(State)
      ;  state_error(State0, budget, oversized_tool_observation,
                     _{used:Total,limit:Runtime.budget.max_output_bytes},
                     "tool observations exceed the output budget", Error),
         Outcome = error(Error)
      )
    ).

continue_observation(error(Error), _, _, error(Error)) :- !.
continue_observation(ok(State), Calls, Runtime, Outcome) :-
    execute_calls(Calls, Runtime, State, Outcome).

finish_direct(Response, Runtime, State0, Outcome) :-
    ( get_dict(text, Response, Text0), nonempty_text(Text0)
    -> text_string(Text0, Text),
       text_bytes(Text, Bytes),
       Total is State0.output_bytes+Bytes,
       ( Total =< Runtime.budget.max_output_bytes
       -> put_dict(output_bytes, State0, Total, State),
          reverse(State.responses, Responses),
          Outcome = ok(direct_result{value:Text,response:Response,
                                     responses:Responses,
                                     usage:State.usage,
                                     turns:State.model_calls,
                                     iterations:State.iterations,
                                     context_calls:State.context_calls,
                                     tool_calls:State.tool_calls,
                                     observation_bytes:State0.output_bytes,
                                     output_bytes:State.output_bytes,
                                     trajectory:State.trajectory})
       ;  state_error(State0, budget, output_budget_exhausted,
                      _{used:Total,limit:Runtime.budget.max_output_bytes},
                      "direct final output exceeds its budget", Error),
          Outcome = error(Error)
       )
    ; state_error(State0, provider, missing_final_output, _{},
                  "direct provider returned no final text", Error),
      Outcome = error(Error)
    ).

context_arguments(context(search), Args, Normalized) :-
    allowed_args(Args, [context,query]),
    required_text(Args, query, Query),
    context_alias(Args, Context),
    Normalized = context_args{context:Context,query:Query}.
context_arguments(context(slice), Args, Normalized) :-
    allowed_args(Args, [context,start,length]),
    required_nonnegative(Args, start, Start),
    required_positive(Args, length, Length),
    context_alias(Args, Context),
    Normalized = context_args{context:Context,start:Start,length:Length}.
context_arguments(context(peek), Args, Normalized) :-
    allowed_args(Args, [context,selector]),
    ( get_dict(selector, Args, Selector0) -> peek_selector(Selector0, Selector)
    ; argument_fault(missing_selector)
    ),
    context_alias(Args, Context),
    Normalized = context_args{context:Context,selector:Selector}.

allowed_args(Args, Allowed) :-
    dict_keys(Args, Keys), subtract(Keys, Allowed, Extra),
    ( Extra == [] -> true ; argument_fault(unexpected_fields(Extra)) ).

context_alias(Args, Alias) :-
    ( get_dict(context, Args, Found)
    -> (string(Found), Found \== "" -> Alias=Found
       ; argument_fault(invalid_context_alias))
    ; Alias="input"
    ).

required_text(Args, Key, Value) :-
    ( get_dict(Key, Args, Found), string(Found), Found \== "" -> Value=Found
    ; argument_fault(invalid_text(Key)) ).
required_nonnegative(Args, Key, Value) :-
    ( get_dict(Key, Args, Found), integer(Found), Found >= 0 -> Value=Found
    ; argument_fault(invalid_nonnegative_integer(Key)) ).
required_positive(Args, Key, Value) :-
    ( get_dict(Key, Args, Found), integer(Found), Found > 0 -> Value=Found
    ; argument_fault(invalid_positive_integer(Key)) ).

peek_selector(Dict, Selector) :-
    is_dict(Dict), get_dict(type, Dict, Type0),
    ( string(Type0) -> atom_string(Type, Type0) ; Type=Type0 ),
    peek_selector_type(Type, Dict, Selector),
    !.
peek_selector(_, _) :- argument_fault(invalid_selector).

peek_selector_type(metadata, Dict, metadata) :-
    allowed_args(Dict, [type,index,count]),
    optional_positive(Dict, count).
peek_selector_type(head, Dict, head(N)) :-
    allowed_args(Dict,[type,index,count]),
    optional_nonnegative(Dict, index),
    positive_or_default(Dict, count, N).
peek_selector_type(tail, Dict, tail(N)) :-
    allowed_args(Dict,[type,index,count]),
    optional_nonnegative(Dict, index),
    positive_or_default(Dict, count, N).
peek_selector_type(item, Dict, item(N)) :-
    allowed_args(Dict,[type,index,count]),
    optional_positive(Dict, count),
    nonnegative_or_default(Dict, index, N).
peek_selector_type(_, _, _) :- argument_fault(unsupported_selector).

% Shared peek-selector defaults. The projected JSON schema marks only
% "type" as required and advertises index (minimum 0) and count (minimum 1)
% as optional shared selector fields, so native validation must supply the
% same defaults instead of rejecting the advertised shape (issue #312).
peek_default_count(128).

optional_positive(Dict, Key) :-
    (   get_dict(Key, Dict, _)
    ->  required_positive(Dict, Key, _)
    ;   true
    ).

optional_nonnegative(Dict, Key) :-
    (   get_dict(Key, Dict, _)
    ->  required_nonnegative(Dict, Key, _)
    ;   true
    ).

positive_or_default(Dict, Key, Value) :-
    (   get_dict(Key, Dict, _)
    ->  required_positive(Dict, Key, Value)
    ;   peek_default_count(Value)
    ).

nonnegative_or_default(Dict, Key, Value) :-
    (   get_dict(Key, Dict, _)
    ->  required_nonnegative(Dict, Key, Value)
    ;   Value = 0
    ).

argument_fault(Detail) :-
    throw(direct_fault(direct_error{
                           phase:schema,kind:malformed_arguments,
                           detail:Detail,
                           message:"native context arguments are malformed"})).

context_handle(Alias, Contexts, Handle) :-
    ( member(Context, Contexts), Context.id == Alias -> Handle=Context.handle
    ; throw(direct_fault(direct_error{
                             phase:context,kind:unknown_context_alias,
                             context:Alias,
                             message:"native context alias is unavailable"}))
    ).

call_context(search, Handle, Args, Options, Outcome) :-
    context_search(Handle, Args.query, Options, Outcome).
call_context(slice, Handle, Args, Options, Outcome) :-
    context_slice(Handle, Args.start, Args.length, Options, Outcome).
call_context(peek, Handle, Args, Options, Outcome) :-
    context_peek(Handle, Args.selector, Options, Outcome).

runtime_arguments(spec(catalog), Args) :-
    allowed_args(Args, []).
runtime_arguments(spec(normalize), Args) :-
    allowed_args(Args, [source]),
    required_text(Args, source, _).
runtime_arguments(spec(freeze), Args) :-
    allowed_args(Args, [source,series,version]),
    required_text(Args, source, _),
    required_text(Args, series, _),
    required_positive(Args, version, _).
runtime_arguments(spec(observe), Args) :-
    allowed_args(Args, [spec_context]),
    required_text(Args, spec_context, _).
runtime_arguments(spec(verify), Args) :-
    allowed_args(Args, [spec_context,observations_context]),
    required_text(Args, spec_context, _),
    required_text(Args, observations_context, _).
runtime_arguments(plan(execute), Args) :-
    allowed_args(Args, [plan]),
    ( get_dict(plan, Args, Plan), is_dict(Plan) -> true
    ; argument_fault(invalid_plan)
    ).

runtime_operation(spec(catalog), _, Runtime, _, Outcome) :-
    assertion_registry(Runtime.options, Registry),
    rlm_spec_lang:spec_language_catalog(Registry, Result),
    simple_runtime_result(Result, Outcome).
runtime_operation(spec(normalize), Args, _, _, Outcome) :-
    rlm_spec_lang:spec_source_normalize(Args.source, Result),
    simple_runtime_result(Result, Outcome).
runtime_operation(spec(freeze), Args, Runtime, _, Outcome) :-
    assertion_registry(Runtime.options, Registry),
    atom_string(Series, Args.series),
    rlm_spec_lang:spec_source_compile(Args.source,
                                      Registry,
                                      [series(Series),version(Args.version)],
                                      Result),
    simple_runtime_result(Result, Outcome).
runtime_operation(spec(observe), Args, Runtime, State, Outcome) :-
    assertion_registry(Runtime.options, Registry),
    retained_value(Args.spec_context, State.contexts, Frozen),
    option(observation_sources, Runtime.options, [], Sources),
    option(observe_options, Runtime.options, [], ObserveOptions),
    rlm_verify:spec_observe_execute(Frozen,
                                    Sources,
                                    Registry,
                                    ObserveOptions,
                                    Result),
    simple_runtime_result(Result, Outcome).
runtime_operation(spec(verify), Args, Runtime, State, Outcome) :-
    assertion_registry(Runtime.options, Registry),
    retained_value(Args.spec_context, State.contexts, Frozen),
    retained_value(Args.observations_context, State.contexts, Observations),
    rlm_verify:spec_verify(Frozen, Observations, Registry, Result),
    simple_runtime_result(Result, Outcome).
runtime_operation(plan(execute), Args, Runtime, State, Outcome) :-
    native_plan_runtime(Runtime, State, PlanOptions, PlanBudget, Inputs),
    rlm_plan:plan_run(Args.plan,
                      Runtime.capabilities,
                      PlanOptions,
                      Inputs,
                      PlanOutcome),
    native_plan_result(PlanOutcome, PlanBudget, Outcome).

simple_runtime_result(ok(Value),
                      ok(runtime_execution{value:Value,
                                           usage:Usage,
                                           iterations:0,
                                           model_calls:0,
                                           tool_calls:0,
                                           context_calls:0})) :-
    zero_usage(Usage),
    !.
simple_runtime_result(error(Error), error(Error)).

assertion_registry(Options, Registry) :-
    option(assertion_registry, Options, none, Registry),
    ( Registry \== none -> true
    ; throw(direct_fault(direct_error{
                             phase:spec,kind:missing_assertion_registry,
                             message:"native SPEC operation requires a trusted assertion registry"}))
    ).

retained_value(Alias, Contexts, Value) :-
    ( member(Context, Contexts), Context.id == Alias, Context.value \== none
    -> Value = Context.value
    ; throw(direct_fault(direct_error{
                             phase:context,kind:unknown_result_context,
                             context:Alias,
                             message:"runtime operation requires a retained result context"}))
    ).

native_plan_runtime(Runtime, State, Options, Budget, Inputs) :-
    RemainingSteps is Runtime.budget.max_iterations-State.iterations,
    RemainingModels is Runtime.budget.max_model_calls-State.model_calls,
    RemainingTools is Runtime.budget.max_tool_calls-State.tool_calls,
    RemainingContexts is Runtime.budget.max_context_ops-State.context_calls,
    RemainingOutput is Runtime.budget.max_output_bytes-State.output_bytes,
    Depth is Runtime.budget.max_recursion_depth+1,
    Budget = _{max_steps:RemainingSteps,
               max_depth:Depth,
               max_parallel:Runtime.budget.max_concurrent_subcalls,
               max_model_calls:RemainingModels,
               max_tool_calls:RemainingTools,
               max_context_ops:RemainingContexts,
               max_output_bytes:RemainingOutput,
               time_limit:Runtime.budget.time_limit},
    tool_invocation_options(Runtime.options, InvocationOptions),
    ( Runtime.registry == none -> RuntimeTools=[]
    ; tool_registry_runtime_tools(Runtime.registry,
                                  Runtime.capabilities,
                                  InvocationOptions,
                                  RuntimeTools)
    ),
    context_runtime_options(Runtime.options, ContextOptions),
    context_handle("input", State.contexts, InputHandle),
    native_model_step_handler(Runtime, State, InputHandle, Handler),
    Options = [providers([provider_ref(Runtime.provider_name,Runtime.provider)]),
               tools(RuntimeTools),context_options(ContextOptions),budget(Budget),
               model_step_handler(Handler)],
    option(plan_inputs, Runtime.options, _{}, ExtraInputs),
    put_dict(context, ExtraInputs, InputHandle, Inputs).

% The typed-plan model step runs one provider-native direct session against the
% already-acquired input context handle. The child session receives the exact
% outer provider, capabilities, cancellation token, and the outer budget with
% the outer session's spent usage already netted out. The plan runtime reserves
% one step and one model call for the step and charges actual native
% continuation counts, tool calls, context operations, and observation bytes.
native_model_step_handler(Runtime, State, InputHandle,
                          rlm_direct:rlm_direct_model_step(
                              InputHandle,
                              Runtime.capabilities,
                              Runtime.options,
                              HandlerBudget,
                              Runtime.token)) :-
    remaining_tokens(Runtime.budget.max_total_tokens,
                     State.usage.total_tokens,
                     RemainingTokens),
    RemainingCost is max(0.0, Runtime.budget.max_cost_usd-State.usage.cost_usd),
    put_dict(_{max_total_tokens:RemainingTokens,
               max_cost_usd:RemainingCost},
             Runtime.budget,
             HandlerBudget).

native_plan_result(error(Error), _, error(Error)) :- !.
native_plan_result(ok(Result), Budget,
                   ok(runtime_execution{value:plan_execution{
                                                  value:Result.value,
                                                  vars:Result.vars,
                                                  transitions:Result.transitions},
                                        usage:Usage,
                                        iterations:Iterations,
                                        model_calls:ModelCalls,
                                        tool_calls:ToolCalls,
                                        context_calls:ContextCalls})) :-
    plan_usage(Result, Usage),
    Remaining = Result.budget_remaining,
    Iterations is Budget.max_steps-Remaining.steps,
    ModelCalls is Budget.max_model_calls-Remaining.model_calls,
    ToolCalls is Budget.max_tool_calls-Remaining.tool_calls,
    ContextCalls is Budget.max_context_ops-Remaining.context_ops.

model_event(Response, Sequence,
            direct_event{type:model,sequence:Sequence,
                         response_id:ResponseId,provider:Provider,
                         selected_model:Selected,http_status:Status,
                         usage:Usage}) :-
    dict_default(response_id, Response, none, ResponseId),
    dict_default(provider, Response, unknown, Provider),
    dict_default(selected_model, Response, unknown, Selected),
    ( get_dict(metadata, Response, Metadata), is_dict(Metadata)
    -> dict_default(http_status, Metadata, 0, Status)
    ; Status=0 ),
    response_usage(Response, Usage).

state_error(State, Phase, Kind, Fields, Message, Error) :-
    reverse(State.responses, Responses),
    Base = direct_error{phase:Phase,kind:Kind,message:Message,
                        usage:State.usage,trajectory:State.trajectory,
                        model_responses:Responses,
                        iterations:State.iterations,
                        context_calls:State.context_calls,
                        tool_calls:State.tool_calls,
                        output_bytes:State.output_bytes},
    put_dict(Fields, Base, Error).

error_kind(Error, Default, Kind) :-
    ( is_dict(Error), get_dict(kind, Error, Found) -> Kind=Found ; Kind=Default ).

text_bytes(Text, Bytes) :-
    string_bytes(Text, Octets, utf8), length(Octets, Bytes).

nonempty_text(Value) :- string(Value), Value \== "", !.
nonempty_text(Value) :- atom(Value), Value \== ''.

dict_default(Key, Dict, Default, Value) :-
    ( is_dict(Dict), get_dict(Key, Dict, Found) -> Value=Found ; Value=Default ).

option(Name, Options, Default, Value) :-
    ( member(Entry, Options), nonvar(Entry), Entry =.. [Name,Found]
    -> Value=Found ; Value=Default ).

direct_exception(time_limit_exceeded,
                 error(direct_error{phase:runtime,kind:timeout,
                                    message:"direct loop exceeded wall-time budget"})) :- !.
direct_exception(time_limit_exceeded(_), Outcome) :- !,
    direct_exception(time_limit_exceeded, Outcome).
direct_exception(error(rlm_cancelled(Token), _),
                 error(direct_error{phase:runtime,kind:cancelled,token:Token,
                                    message:"direct loop was cancelled"})) :- !.
direct_exception(rlm_cancelled(Token), Outcome) :- !,
    direct_exception(error(rlm_cancelled(Token), context), Outcome).
direct_exception(direct_fault(Error), error(Error)) :- !.
direct_exception(completion_fault(Fault),
                 error(direct_error{phase:runtime,kind:completion_fault,
                                    detail:Fault,
                                    message:"direct runtime rejected the operation"})) :- !.
direct_exception(Exception,
                 error(direct_error{phase:runtime,kind:exception,
                                    exception:Safe,
                                    message:"direct runtime raised an exception"})) :-
    term_string(Exception, Safe, [quoted(true),numbervars(true)]).
