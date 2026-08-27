:- module(rlm_completion,
          [ rlm_completion/4,
            rlm_completion_async/4,
            llm_query/3,
            llm_query_async/3,
            rlm_query/4,
            rlm_query_async/4,
            rlm_cancellation_token/1,
            rlm_cancel/1,
            default_completion_budget/1,
            completion_task_metadata/3,
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

/** <module> Bounded Recursive Language Model supervisor

The root model either answers directly through the closed direct-answer
envelope or selects a typed symbolic plan. Prolog owns validation,
capabilities, recursion ceilings, budgets, cancellation and trajectory data.
Recursive `rlm(...)` nodes remain closed symbolic plans; a child model call is
still executed by the production provider registry, never by model-generated
Prolog code.

Completion execution follows one direction: the async predicate schedules the
canonical guarded operation; the sync predicate starts that same operation and
awaits its Future. Internal recursive/model steps call canonical execution
predicates directly and never re-enter a synchronous public facade.
*/

:- use_module(library(http/json)).
:- use_module(library(lists)).
:- use_module(library(time)).
:- use_module(library(uuid)).
:- use_module(rlm_async).
:- use_module(rlm_chain).
:- use_module(rlm_context).
:- use_module(rlm_plan).
:- use_module(rlm_prompt_compiler, []).
:- use_module(rlm_skill, []).
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

completion_runtime_budget(Options, Budget) :-
    completion_budget(Options, Budget).

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
    completion_skill_messages(Query,
                               ProviderName,
                               Capabilities,
                               Options,
                               Budget,
                               SkillMessages),
    agent_identity_message(Options, IdentityMessage),
    runtime_tool_bindings(Options,
                          Capabilities,
                          RuntimeTools,
                          Registry),
    provider_tool_projection(Query,
                             Registry,
                             Capabilities,
                             Options,
                             Budget,
                             ToolSchemas),
    planner_prompt(Query,
                   MetadataRef.metadata,
                   Capabilities,
                   ChildCapabilities,
                   ToolSchemas,
                   Options,
                   Prompt),
    planner_messages(IdentityMessage, SkillMessages, Prompt, Messages),
    planner_projection_options(Options, Messages, PlannerOptions),
    planner_attempts(Options, Attempts),
    planner_token_limit(Options, RequestedPlannerTokens),
    PlannerTokenLimit is min(Budget.max_total_tokens,
                             RequestedPlannerTokens),
    planner_plan(Attempts,
                 Prompt,
                 ProviderName,
                 Provider,
                 PlannerOptions,
                 PlannerTokenLimit,
                 Budget,
                 Token,
                 PlannerOutcome),
    % Planner skills define the plan protocol; executed model steps produce the
    % task result and must not inherit planner-only output instructions.
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

completion_skill_messages(Query, Provider, Capabilities, Options, Budget,
                          Messages) :-
    catch(completion_skill_messages_(Query,
                                     Provider,
                                     Capabilities,
                                     Options,
                                     Budget,
                                     Messages),
          Error,
          completion_skill_exception(Error)).

completion_skill_exception(rlm_cancelled(Token)) :-
    !,
    throw(rlm_cancelled(Token)).
completion_skill_exception(error(rlm_cancelled(Token), Context)) :-
    !,
    throw(error(rlm_cancelled(Token), Context)).
completion_skill_exception(time_limit_exceeded) :-
    !,
    throw(time_limit_exceeded).
completion_skill_exception(time_limit_exceeded(Limit)) :-
    !,
    throw(time_limit_exceeded(Limit)).
completion_skill_exception(Error) :-
    throw(prompt_compile_fault(Error)).

completion_skill_messages_(Query, Provider, Capabilities, Options, Budget,
                           Messages) :-
    trusted_skill_controls(Options, Mode, CatalogSpec, Selected, Denied),
    (   Mode == off
    ->  Messages = []
    ;   CatalogSpec == none
    ->  Messages = []
    ;   completion_skill_catalog(CatalogSpec, SkillCatalog, UnitOptions),
        validate_trusted_skill_names(SkillCatalog, Selected, Denied),
        setup_call_cleanup(
            rlm_prompt_compiler:prompt_catalog_create(MetadataCatalog),
            select_skill_units(MetadataCatalog,
                               SkillCatalog,
                               UnitOptions,
                               Query,
                               Capabilities,
                               Selected,
                               Denied,
                               SelectedNames),
            rlm_prompt_compiler:prompt_catalog_destroy(MetadataCatalog)),
        setup_call_cleanup(
            rlm_prompt_compiler:prompt_catalog_create(FinalCatalog),
            compile_selected_skill_catalog(FinalCatalog,
                                           SkillCatalog,
                                           UnitOptions,
                                           SelectedNames,
                                           Query,
                                           Provider,
                                           Capabilities,
                                           Selected,
                                           Denied,
                                           Budget,
                                           Messages),
            rlm_prompt_compiler:prompt_catalog_destroy(FinalCatalog))
    ).

trusted_skill_controls(Options, Mode, Catalog, Selected, Denied) :-
    option_value(skill_mode, Options, on, Mode),
    require_skill_mode(Mode),
    option_value(skill_catalog, Options, default, Catalog),
    option_value(explicit_skills, Options, [], Selected0),
    option_value(disabled_skills, Options, [], Denied0),
    normalize_skill_names(explicit_skills, Selected0, Selected),
    normalize_skill_names(disabled_skills, Denied0, Denied).

require_skill_mode(on) :- !.
require_skill_mode(off) :- !.
require_skill_mode(Mode) :-
    throw(completion_fault(invalid_skill_mode(Mode))).

normalize_skill_names(Field, Names0, Names) :-
    (   is_list(Names0)
    ->  true
    ;   throw(completion_fault(invalid_skill_names(Field, Names0)))
    ),
    length(Names0, Count),
    (   Count =< 64
    ->  true
    ;   throw(completion_fault(too_many_skill_names(Field, Count)))
    ),
    maplist(normalize_skill_name(Field), Names0, Names1),
    sort(Names1, Names).

normalize_skill_name(_, Name, Name) :-
    atom(Name),
    valid_skill_name(Name),
    !.
normalize_skill_name(_, Name0, Name) :-
    string(Name0),
    atom_string(Name, Name0),
    valid_skill_name(Name),
    !.
normalize_skill_name(Field, Name, _) :-
    throw(completion_fault(invalid_skill_name(Field, Name))).

valid_skill_name(Name) :-
    atom_length(Name, Length),
    between(1, 64, Length),
    atom_chars(Name, [First|Chars]),
    char_type(First, lower),
    maplist(skill_name_char, Chars),
    last([First|Chars], Last),
    (char_type(Last, lower) ; char_type(Last, digit)),
    \+ sub_atom(Name, _, 2, _, '--').

skill_name_char(Char) :- char_type(Char, lower), !.
skill_name_char(Char) :- char_type(Char, digit), !.
skill_name_char('-').

completion_skill_catalog(default, Catalog,
                         [ activation(always),
                           mandatory_context(true),
                           provider_visible(true)
                         ]) :-
    !,
    rlm_skill:skill_default_catalog(Outcome),
    require_skill_catalog_outcome(Outcome, Catalog).
completion_skill_catalog(Catalog, Catalog, []) :-
    rlm_skill:skill_catalog_skills(Catalog, _),
    !.
completion_skill_catalog(Spec, _, _) :-
    throw(completion_fault(invalid_skill_catalog_option(Spec))).

require_skill_catalog_outcome(ok(Catalog), Catalog) :- !.
require_skill_catalog_outcome(error(Error), _) :-
    throw(completion_fault(skill_catalog_failed(Error))).

validate_trusted_skill_names(SkillCatalog, Selected, Denied) :-
    rlm_skill:skill_catalog_skills(SkillCatalog, Skills),
    maplist(skill_name, Skills, CatalogNames),
    require_known_skill_names(explicit_skills, Selected, CatalogNames),
    require_known_skill_names(disabled_skills, Denied, CatalogNames).

skill_name(Skill, Name) :-
    Name = Skill.name.

require_known_skill_names(_, [], _).
require_known_skill_names(Field, [Name|Names], CatalogNames) :-
    (   memberchk(Name, CatalogNames)
    ->  require_known_skill_names(Field, Names, CatalogNames)
    ;   throw(completion_fault(unknown_skill_name(Field, Name)))
    ).

select_skill_units(PromptCatalog,
                   SkillCatalog,
                   UnitOptions,
                   Query,
                   Capabilities,
                   SelectedNames,
                   DeniedNames,
                   AdmittedNames) :-
    MetadataOptions = [load_content(false)|UnitOptions],
    rlm_skill:skill_catalog_prompt_units(SkillCatalog,
                                         MetadataOptions,
                                         UnitOutcome),
    require_skill_units(UnitOutcome, Units0),
    maplist(enable_explicit_skill(SelectedNames), Units0, Units),
    skill_compile_input(Query, SelectedNames, DeniedNames, Input),
    maplist(register_prompt_unit(PromptCatalog), Units),
    rlm_prompt_compiler:prompt_compile(
        PromptCatalog,
        Input,
        [capabilities(Capabilities), pack(false)],
        CompileOutcome),
    require_prompt_compile(CompileOutcome, Compiled),
    selected_skill_names(Compiled.selected_units, AdmittedNames),
    require_explicit_skills_admitted(SelectedNames,
                                     AdmittedNames,
                                     Compiled).

require_explicit_skills_admitted([], _, _).
require_explicit_skills_admitted([Name|Names], AdmittedNames, Compiled) :-
    (   memberchk(Name, AdmittedNames)
    ->  require_explicit_skills_admitted(Names, AdmittedNames, Compiled)
    ;   explicit_skill_rejection_explanation(Compiled, Name, Explanation),
        throw(completion_fault(explicit_skill_rejected(Name, Explanation)))
    ).

explicit_skill_rejection_explanation(Compiled, Name, Explanation) :-
    rlm_prompt_compiler:prompt_explain(Compiled,
                                       skill(Name),
                                       ExplainOutcome),
    (   ExplainOutcome = ok(Explanation)
    ->  true
    ;   ExplainOutcome = error(Cause),
        Explanation = prompt_explanation{
                          unit:skill(Name),
                          state:rejected,
                          reasons:[explanation_failed(Cause)]
                      }
    ).

compile_selected_skill_catalog(PromptCatalog,
                               SkillCatalog,
                               UnitOptions,
                               AdmittedNames,
                               Query,
                               Provider,
                               Capabilities,
                               SelectedNames,
                               DeniedNames,
                               Budget,
                               Messages) :-
    maplist(selected_full_skill_unit(SkillCatalog, UnitOptions, SelectedNames),
            AdmittedNames,
            Units),
    maplist(register_prompt_unit(PromptCatalog), Units),
    skill_compile_input(Query, SelectedNames, DeniedNames, Input),
    completion_skill_context_policy(Budget, Policy),
    rlm_prompt_compiler:prompt_compile(
        PromptCatalog,
        Input,
        [capabilities(Capabilities), policy(Policy)],
        CompileOutcome),
    require_prompt_compile(CompileOutcome, Compiled),
    rlm_prompt_compiler:prompt_render(Compiled, Provider, RenderOutcome),
    require_prompt_render(RenderOutcome, Rendered),
    rendered_skill_messages(Rendered.text, Messages).

selected_full_skill_unit(SkillCatalog, UnitOptions, ExplicitNames, Name, Unit) :-
    rlm_skill:skill_catalog_skill(SkillCatalog, Name, Skill),
    rlm_skill:skill_prompt_unit(Skill, UnitOptions, UnitOutcome),
    require_selected_skill_unit(UnitOutcome, Unit0),
    enable_explicit_skill(ExplicitNames, Unit0, Unit).

require_selected_skill_unit(ok(Unit), Unit) :- !.
require_selected_skill_unit(error(Error), _) :-
    throw(completion_fault(skill_conversion_failed(Error))).

skill_compile_input(Query, SelectedNames, DeniedNames, Input) :-
    maplist(skill_unit, SelectedNames, Selected),
    maplist(skill_unit, DeniedNames, Denied),
    Input = prompt_input{text:Query, selected:Selected, denied:Denied}.

selected_skill_names(Units, Names) :-
    findall(Name, member(skill(Name), Units), Names0),
    sort(Names0, Names).

completion_skill_context_policy(Budget,
                                _{max_context_tokens:MaxTokens,
                                  provider_context_tokens:MaxTokens,
                                  reserve_output_tokens:0,
                                  safety_margin_tokens:0,
                                  min_recent_turns:0,
                                  overflow:deny}) :-
    MaxTokens = Budget.max_total_tokens.

require_skill_units(ok(Units), Units) :- !.
require_skill_units(error(Error), _) :-
    throw(completion_fault(skill_conversion_failed(Error))).

enable_explicit_skill(Selected, Unit0, Unit) :-
    Unit0.unit = skill(Name),
    (   memberchk(Name, Selected)
    ->  put_dict(available, Unit0, true, Unit)
    ;   Unit = Unit0
    ).

register_prompt_unit(Catalog, Unit) :-
    rlm_prompt_compiler:prompt_catalog_register(Catalog, Unit, Outcome),
    (   Outcome = ok(_)
    ->  true
    ;   Outcome = error(Error),
        throw(completion_fault(skill_registration_failed(Error)))
    ).

skill_unit(Name, skill(Name)).

require_prompt_compile(ok(Compiled), Compiled) :- !.
require_prompt_compile(error(Error), _) :-
    throw(completion_fault(prompt_compile_failed(Error))).

require_prompt_render(ok(Rendered), Rendered) :- !.
require_prompt_render(error(Error), _) :-
    throw(completion_fault(prompt_render_failed(Error))).

rendered_skill_messages("", []) :- !.
rendered_skill_messages(Text, [message{role:system, content:Text}]).

planner_messages(none, [], Prompt, [message{role:user, content:Prompt}]) :- !.
planner_messages(none, [System], Prompt,
                 [System, message{role:user, content:Prompt}]) :- !.
planner_messages(Identity, [], Prompt,
                 [Identity, message{role:user, content:Prompt}]) :- !.
planner_messages(Identity, [System], Prompt,
                 [Identity, System, message{role:user, content:Prompt}]).

% Root-only agent identity. Direct rlm_completion calls are roots and carry
% an identity system message naming the embedding app (default: this
% library). Delegated subagent children are structurally marked delegated by
% rlm_subagent and never widen back to root identity. The message states the
% identity boundary only; skills and active tool schemas stay the sole
% protocol/content channels.
agent_identity_message(Options, Message) :-
    option_value(agent_scope, Options, root, Scope),
    require_agent_scope(Scope),
    option_value(agent_name, Options, 'prolog-rlm', Name),
    require_agent_name(Name),
    (   Scope == delegated
    ->  Message = none
    ;   root_identity_text(Name, Text),
        Message = message{role:system, content:Text}
    ).

require_agent_scope(root) :- !.
require_agent_scope(delegated) :- !.
require_agent_scope(Scope) :-
    throw(completion_fault(invalid_agent_scope(Scope))).

require_agent_name(Name) :-
    nonempty_name_text(Name),
    !.
require_agent_name(Name) :-
    throw(completion_fault(invalid_agent_name(Name))).

nonempty_name_text(Value) :-
    atom(Value),
    !,
    Value \== ''.
nonempty_name_text(Value) :-
    string(Value),
    Value \== "".

root_identity_text(Name0, Text) :-
    (   atom(Name0)
    ->  Name = Name0
    ;   atom_string(Name, Name0)
    ),
    format(string(Text),
           "You are the root agent inside ~w.\n\
This agent runs on the prolog-rlm runtime, a reusable bounded typed RLM library. Only the core context inputs and the tools your host granted are loaded for this call; nothing else is. Stay inside those boundaries.",
           [Name]).

planner_projection_options(Options0, Messages, Options) :-
    exclude(named_option(compiled_planner_messages), Options0, Rest),
    Options = [compiled_planner_messages(Messages)|Rest].

named_option(Name, Option) :-
    nonvar(Option),
    Option =.. [Name, _].

completion_after_planner(error(Error), _, _, _, _, _, _, _, _, _, _,
                         error(Error)) :-
    !.
completion_after_planner(ok(Planner),
                         _,
                         _,
                         _,
                         _,
                         _,
                         ChildCapabilities,
                         _,
                         _,
                         Budget,
                         Token,
                         Outcome) :-
    Planner.decision == direct,
    !,
    check_cancelled(Token),
    budget_usage_check(Budget, Planner.usage, BudgetOutcome),
    completion_direct_finish(BudgetOutcome,
                             Planner,
                             ChildCapabilities,
                             Outcome).
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
                            TokenBoundedPlan),
    enforce_plan_reasoning_options(Options,
                                   TokenBoundedPlan,
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

completion_direct_finish(error(Error), _, _, error(Error)) :- !.
completion_direct_finish(ok, Planner, ChildCapabilities, ok(Completion)) :-
    direct_root_event(Planner, RootEvent),
    Completion = completion_result{
                     value:Planner.value,
                     plan:none,
                     vars:_{},
                     transitions:[],
                     recursion:recursion_stats{recursive_calls:0,
                                               max_depth:0,
                                               fingerprints:[]},
                     child_capabilities:ChildCapabilities,
                     usage:Planner.usage,
                     trajectory:completion_trajectory{
                                    root_event:RootEvent,
                                    events:[RootEvent],
                                    reason:"root model answered directly without plan execution"
                                }
                 }.

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
 * Root decision: direct answer envelope or typed plan
 * ---------------------------------------------------------------------- */

root_decision_parse(Input, Outcome) :-
    plan_parse(Input, PlanOutcome),
    root_decision_after_plan(PlanOutcome, Input, Outcome).

root_decision_after_plan(ok(Plan), _, ok(root_plan(Plan))) :- !.
root_decision_after_plan(error(PlanError), Input, Outcome) :-
    direct_envelope_probe(Input, DirectOutcome),
    root_decision_from_probe(DirectOutcome, PlanError, Outcome).

root_decision_from_probe(ok(Answer), _, ok(root_direct(Answer))) :- !.
root_decision_from_probe(error(DirectError), _, error(DirectError)) :- !.
root_decision_from_probe(not_direct, PlanError, error(PlanError)).

% A valid typed plan always wins; the direct envelope is recognized only as a
% strict fallback shape with exactly the approved fields. A root object that
% declares a mode without matching the closed envelope is an explicit
% invalid_root_decision failure, never prose, never a native tool call.
direct_envelope_probe(Input, Outcome) :-
    is_dict(Input),
    !,
    direct_envelope_dict(Input, Outcome).
direct_envelope_probe(Input, Outcome) :-
    plain_text(Input),
    !,
    text_string(Input, Text),
    (   catch(direct_envelope_json(Text, Dict), _, fail)
    ->  direct_envelope_dict(Dict, Outcome)
    ;   Outcome = not_direct
    ).
direct_envelope_probe(_, not_direct).

plain_text(Value) :- string(Value), !.
plain_text(Value) :- atom(Value).

direct_envelope_json(Text, Dict) :-
    rlm_plan:json_object_text(Text, JsonText),
    atom_string(Atom, JsonText),
    atom_json_dict(Atom, Dict, []).

direct_envelope_dict(Dict, Outcome) :-
    (   get_dict(mode, Dict, _)
    ->  direct_envelope_strict(Dict, Outcome)
    ;   Outcome = not_direct
    ).

direct_envelope_strict(Dict, Outcome) :-
    dict_keys(Dict, Keys0),
    sort(Keys0, Keys),
    (   Keys == [answer, mode]
    ->  direct_envelope_answer(Dict, Outcome)
    ;   direct_envelope_error(invalid_direct_envelope_fields, Outcome)
    ).

direct_envelope_answer(Dict, Outcome) :-
    get_dict(mode, Dict, Mode),
    (   direct_mode(Mode)
    ->  get_dict(answer, Dict, Answer),
        (   nonempty_text(Answer)
        ->  text_string(Answer, Text),
            Outcome = ok(Text)
        ;   direct_envelope_error(direct_answer_must_be_nonempty_text,
                                  Outcome)
        )
    ;   direct_envelope_error(unsupported_root_mode, Outcome)
    ).

direct_mode(direct) :- !.
direct_mode("direct").

direct_envelope_error(Detail,
                      error(plan_error{phase:normalize,
                                       kind:invalid_root_decision,
                                       detail:Detail,
                                       message:"root decision envelope was rejected"})).

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
            option_value(compiled_planner_messages,
                         Options,
                         [message{role:user, content:Prompt}],
                         BaseMessages),
            planner_attempt_messages(BaseMessages, Options, Messages),
            Request = model_request{
                          messages:Messages,
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
    ;   root_decision_parse(PlanInput, ParseOutcome),
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

planner_parse_result(ok(root_direct(Answer)),
                     Summary,
                     Usage,
                     Attempt,
                     _,
                     _,
                     _,
                     _,
                     _,
                     _,
                     _,
                     _,
                     ok(Planner)) :-
    !,
    Planner = planner_result{decision:direct,
                             value:Answer,
                             attempt:Attempt,
                             usage:Usage,
                             provider_summary:Summary}.
planner_parse_result(ok(root_plan(Plan)),
                     Summary,
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
    !,
    capability_options(Options,
                       ProviderName,
                       Capabilities,
                       _),
    planner_validate_root_plan(Plan, Capabilities, Options, ValidationOutcome),
    planner_validation_result(ValidationOutcome,
                              Plan,
                              Summary,
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
                              Outcome).
planner_parse_result(error(ParseError),
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
    planner_retry_options(Options, ParseError, RetryOptions),
    planner_loop(Next,
                 MaxAttempts,
                 Prompt,
                 ProviderName,
                 Provider,
                 RetryOptions,
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
                             message:"planner responses did not contain a valid direct answer or typed plan"}.

planner_validation_result(ok(_),
                           Plan,
                           Summary,
                           Usage,
                           Attempt,
                           _, _, _, _, _, _, _, _,
                           ok(Planner)) :-
    !,
    Planner = planner_result{decision:plan,
                             plan:Plan,
                             attempt:Attempt,
                             usage:Usage,
                             provider_summary:Summary}.
planner_validation_result(error(ValidationError),
                          _,
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
    planner_repairable_validation(ValidationError),
    Attempt < MaxAttempts,
    !,
    Next is Attempt+1,
    planner_retry_options(Options, ValidationError, RetryOptions),
    planner_loop(Next,
                 MaxAttempts,
                 Prompt,
                 ProviderName,
                 Provider,
                 RetryOptions,
                 TokenLimit,
                 Budget,
                 Token,
                 Usage,
                 Outcome).
planner_validation_result(error(ValidationError),
                          _,
                          _,
                          Usage,
                          Attempt,
                          _, _, _, _, _, _, _, _,
                          error(Error)) :-
    planner_repairable_validation(ValidationError),
    !,
    Error = completion_error{phase:planner,
                             kind:plan_validation_failed,
                             attempts:Attempt,
                             usage:Usage,
                             cause:ValidationError,
                             message:"planner responses did not contain a structurally valid typed plan"}.
planner_validation_result(error(ValidationError),
                           Plan,
                           Summary,
                           Usage,
                           Attempt,
                           _, _, _, _, _, _, _, _,
                           ok(Planner)) :-
    planner_deferred_validation(ValidationError),
    !,
    Planner = planner_result{decision:plan,
                             plan:Plan,
                             attempt:Attempt,
                             usage:Usage,
                             provider_summary:Summary}.
planner_validation_result(error(ValidationError),
                          _, _, _, _, _, _, _, _, _, _, _, _,
                          error(ValidationError)).

planner_repairable_validation(Error) :-
    is_dict(Error),
    get_dict(phase, Error, validate),
    get_dict(kind, Error, invalid_plan).

% Root-plan validation adds one registry-aware structural rule on top of
% plan_validate: a field reference over a binding produced by a REGISTRY
% tool selects from the closed tool_result envelope installed by the adapter
% (see plan_envelope/3 in rlm_tool). A first-hop key outside that envelope
% can never resolve, so it is rejected here as a repairable structural fault
% instead of failing execution unrecoverably. Direct trusted host tools
% (tools([...])) are exempt: their result shape is host-defined.
planner_validate_root_plan(Plan, Capabilities, Options, Outcome) :-
    plan_validate(Plan, Capabilities, default, ValidationOutcome),
    (   ValidationOutcome = ok(_)
    ->  registry_tool_names(Options, RegistryNames),
        catch(tool_envelope_field_check(Plan, RegistryNames),
              plan_validation(Fault),
              true),
        !,
        (   var(Fault)
        ->  Outcome = ValidationOutcome
        ;   Outcome = error(plan_error{phase:validate,
                                       kind:invalid_plan,
                                       detail:Fault,
                                       message:"plan failed structural validation"})
        )
    ;   Outcome = ValidationOutcome
    ).

registry_tool_names(Options, Names) :-
    option_value(tool_registry, Options, none, Registry),
    (   Registry == none
    ->  Names = []
    ;   rlm_tool:tool_discover(Registry, Schemas)
    ->  maplist(schema_tool_name, Schemas, Names)
    ;   Names = []
    ).

schema_tool_name(Schema, Name) :-
    get_dict(name, Schema, Name).

tool_envelope_field_check(plan(Steps), RegistryNames) :-
    envelope_steps_check(Steps, [], RegistryNames).

envelope_steps_check([], _, _).
envelope_steps_check([Step|Steps], EnvelopeBinds, RegistryNames) :-
    envelope_step_check(Step, EnvelopeBinds, NextEnvelopeBinds, RegistryNames),
    envelope_steps_check(Steps, NextEnvelopeBinds, RegistryNames).

envelope_step_check(context(Handle, _, _), Binds, Binds, Names) :-
    !,
    envelope_expr_check(Handle, Binds, Names).
envelope_step_check(model(_, Prompt, _, _), Binds, Binds, Names) :-
    !,
    envelope_expr_check(Prompt, Binds, Names).
envelope_step_check(tool(Name, Args, Bind), Binds0, Binds, RegistryNames) :-
    !,
    envelope_expr_check(Args, Binds0, RegistryNames),
    (   memberchk(Name, RegistryNames)
    ->  Binds = [Bind|Binds0]
    ;   Binds = Binds0
    ).
envelope_step_check(rlm(Child, _), Binds, Binds, Names) :-
    !,
    envelope_child_check(Child, [], Names).
envelope_step_check(parallel(Plans, _), Binds, Binds, Names) :-
    !,
    maplist(envelope_branch_check(Binds, Names), Plans).
envelope_step_check(retry(_, Child, _), Binds, Binds, Names) :-
    !,
    envelope_child_check(Child, Binds, Names).
envelope_step_check(checkpoint(_), Binds, Binds, _) :- !.
envelope_step_check(final(Value), Binds, Binds, Names) :-
    !,
    envelope_expr_check(Value, Binds, Names).

envelope_branch_check(Binds, Names, Child) :-
    envelope_child_check(Child, Binds, Names).

envelope_child_check(plan(ChildSteps), Binds, Names) :-
    envelope_steps_check(ChildSteps, Binds, Names).

envelope_expr_check(Expr, _, _) :-
    var(Expr),
    !.
envelope_expr_check(Expr, _, _) :-
    is_dict(Expr),
    !.
envelope_expr_check(literal(_), _, _) :-
    !.
envelope_expr_check(field(Base, Key), EnvelopeBinds, Names) :-
    !,
    (   Base = var(Name),
        atom(Name),
        memberchk(Name, EnvelopeBinds),
        \+ tool_result_envelope_key(Key)
    ->  throw(plan_validation(tool_result_envelope_field(Key, Name)))
    ;   true
    ),
    envelope_expr_check(Base, EnvelopeBinds, Names).
envelope_expr_check(Expr, EnvelopeBinds, Names) :-
    compound(Expr),
    !,
    Expr =.. [_|Args],
    forall(member(Arg, Args),
           envelope_expr_check(Arg, EnvelopeBinds, Names)).
envelope_expr_check(_, _, _).

tool_result_envelope_key(value).
tool_result_envelope_key(authorization).
tool_result_envelope_key(authority).
tool_result_envelope_key(status).
tool_result_envelope_key(fingerprint).
tool_result_envelope_key(approval_id).
tool_result_envelope_key(output_bytes).
tool_result_envelope_key(elapsed_ms).

planner_deferred_validation(Error) :-
    is_dict(Error),
    get_dict(phase, Error, validate),
    get_dict(kind, Error, Kind),
    memberchk(Kind, [capability_denied, budget_exceeded]).

planner_attempt_messages(BaseMessages, Options, Messages) :-
    option_value(planner_repair_message, Options, none, Repair),
    (   Repair == none
    ->  Messages = BaseMessages
    ;   append(BaseMessages, [Repair], Messages)
    ).

planner_retry_options(Options0, Error, Options) :-
    planner_repair_message(Error, Repair),
    exclude(named_option(planner_repair_message), Options0, Rest),
    Options = [planner_repair_message(Repair)|Rest].

planner_repair_message(Error,
                       message{role:user,
                               content:Content}) :-
    planner_repair_field(Error, phase, unknown, Phase),
    planner_repair_field(Error, kind, invalid_plan, Kind),
    planner_repair_detail(Error, Detail),
    format(string(Content),
           "Previous planner candidate was rejected without execution. Return one complete new JSON root decision: either {\"mode\":\"direct\",\"answer\":\"<nonempty final text>\"} when runtime operations add no value, or the typed plan {\"steps\":[...]} when they do. Host diagnostic: phase=~w kind=~w detail=~s.",
           [Phase, Kind, Detail]).

planner_repair_field(Error, Key, Default, Value) :-
    (   is_dict(Error),
        get_dict(Key, Error, Found),
        atom(Found),
        atom_length(Found, Length),
        Length =< 64
    ->  Value = Found
    ;   Value = Default
    ).

planner_repair_detail(Error, Detail) :-
    (   is_dict(Error),
        get_dict(detail, Error, Raw),
        safe_planner_repair_detail(Raw, Safe)
    ->  term_string(Safe, Detail,
                    [quoted(false), numbervars(true)])
    ;   Detail = "typed_plan_contract_rejected"
    ).

safe_planner_repair_detail(missing_field(Field), missing_field(Field)) :-
    atom(Field),
    atom_length(Field, Length),
    Length =< 64,
    !.
safe_planner_repair_detail(final_must_be_unique_and_last,
                           final_must_be_unique_and_last) :-
    !.
safe_planner_repair_detail(cyclic_plan, cyclic_plan) :-
    !.
safe_planner_repair_detail(invalid_json_text, invalid_json_text) :-
    !.
safe_planner_repair_detail(no_json_object, no_json_object) :-
    !.
safe_planner_repair_detail(direct_answer_must_be_nonempty_text,
                           direct_answer_must_be_nonempty_text) :-
    !.
safe_planner_repair_detail(invalid_direct_envelope_fields,
                           invalid_direct_envelope_fields) :-
    !.
safe_planner_repair_detail(unsupported_root_mode, unsupported_root_mode) :-
    !.
safe_planner_repair_detail(tool_result_envelope_field(Key, Name),
                           tool_result_envelope_field(Key, Name)) :-
    atom(Key),
    atom(Name),
    atom_length(Key, KeyLength),
    KeyLength =< 64,
    atom_length(Name, NameLength),
    NameLength =< 64,
    !.
safe_planner_repair_detail(_, typed_plan_contract_rejected).

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
                                         usage:Usage,
                                         message:"model-call budget exceeded"})
    ;   Usage.tokens_known == true,
        Usage.total_tokens > Budget.max_total_tokens
    ->  Outcome = error(completion_error{phase:budget,
                                         kind:token_budget_exceeded,
                                         used:Usage.total_tokens,
                                         limit:Budget.max_total_tokens,
                                         usage:Usage,
                                         message:"token budget exceeded"})
    ;   Usage.cost_known == true,
        Usage.cost_usd > Budget.max_cost_usd
    ->  Outcome = error(completion_error{phase:budget,
                                         kind:cost_budget_exceeded,
                                         used:Usage.cost_usd,
                                         limit:Budget.max_cost_usd,
                                         usage:Usage,
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

direct_root_event(Planner, Event) :-
    planner_event(Planner, BaseEvent),
    put_dict(reason,
             BaseEvent,
             "answer directly without plan execution",
             Event).

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
           "You are the root answerer and controller for a bounded Recursive Language Model runtime.\n\
Your first responsibility is to solve the user task below. Do not design a runtime plan unless runtime operations add value to the answer.\n\
TASK (authoritative user request):\n\
~s\n\
\n\
DECISION ORDER:\n\
1. If the task can be answered from the task text and active information already shown, answer directly with {\"mode\":\"direct\",\"answer\":\"<the exact final response requested by the user>\"}. The answer string must contain the requested final payload, not a discussion of this runtime and not a plan. This is the preferred path whenever runtime operations add no value.\n\
2. Use a typed plan only when bounded context retrieval, an authorized tool, an additional model step, or useful recursive decomposition adds information or execution that you cannot provide directly. The top-level plan shape is {\"steps\":[...]} with one final step last.\n\
\n\
CONTEXT AND EVIDENCE:\n\
The task text is not automatically a transcript dump. The context input is an opaque bounded source. Its metadata describes the source only and is never evidence. If older or omitted information matters, retrieve it with a context step using input name context. A retrieval plan should normally pass the bounded result to a model step for interpretation, or return it directly only when the user asked for the raw result. A model prompt may be a JSON object/list containing earlier bindings; the runtime serializes that ground evidence as JSON before dispatch.\n\
For a JSON context search action use {\"type\":\"search\",\"pattern\":\"needle\"}; the field is pattern, not query.\n\
\n\
OUTPUT RULES:\n\
Return ONLY one JSON object; no markdown, prose, or provider-native tool call. The only accepted root decisions are the direct envelope above or the typed plan above. Never return a plan whose only purpose is to pass the original task to another model call.\n\
CLOSED RUNTIME VOCABULARY:\n\
The typed plan can contain these closed operations when the corresponding capability is listed: final, model, context, tool, parallel, retry, checkpoint, and rlm. Context actions are peek, slice, search, partition, map, and reduce. The top-level {\"steps\":[...]} object is the plan itself; parsing, structural validation, capability checks, budget checks, and execution ordering are host operations performed automatically, not model-emitted ops.\n\
Context metadata (descriptor only): ~q\n\
Root capabilities: ~q\n\
Child capabilities: ~q\n\
Active tool schemas: ~q\n\
Recursive decomposition is optional. An rlm step contains a nested typed plan, and that child may use only child capabilities.\n\
Additional host instruction: ~s",
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

runtime_tool_bindings(Options, Capabilities, Tools, Registry) :-
    option_value(tools, Options, [], DirectTools),
    (   is_list(DirectTools)
    ->  true
    ;   throw(completion_fault(invalid_tools(DirectTools)))
    ),
    option_value(tool_registry, Options, none, Registry),
    (   Registry == none
    ->  RegistryTools = []
    ;   tool_invocation_options(Options, InvocationOptions),
        tool_registry_runtime_tools(Registry,
                                    Capabilities,
                                    InvocationOptions,
                                    RegistryTools)
    ),
    append(RegistryTools, DirectTools, Tools).

provider_tool_projection(_, none, _, Options, _, []) :-
    !,
    prompt_compile_mode_options(Options, _).
provider_tool_projection(Query,
                         Registry,
                         Capabilities,
                         Options,
                         Budget,
                         ToolSchemas) :-
    prompt_compile_mode_options(Options, ModeOptions),
    setup_call_cleanup(
        rlm_prompt_compiler:prompt_catalog_create(Catalog),
        compile_registry_tool_projection(Catalog,
                                         Registry,
                                         Query,
                                         Capabilities,
                                         ModeOptions,
                                         Budget,
                                         ToolSchemas),
        rlm_prompt_compiler:prompt_catalog_destroy(Catalog)).

prompt_compile_mode_options(Options, []) :-
    option_value(prompt_compile_mode, Options, compiled, compiled),
    !.
prompt_compile_mode_options(Options, [mode(all_tools)]) :-
    option_value(prompt_compile_mode, Options, compiled, all_tools),
    !.
prompt_compile_mode_options(Options, _) :-
    option_value(prompt_compile_mode, Options, compiled, Mode),
    throw(completion_fault(invalid_prompt_compile_mode(Mode))).

compile_registry_tool_projection(Catalog,
                                 Registry,
                                 Query,
                                 Capabilities,
                                 ModeOptions,
                                 Budget,
                                 ToolSchemas) :-
    rlm_prompt_compiler:prompt_catalog_register_tool_registry(
        Catalog,
        Registry,
        [],
        ImportOutcome),
    require_tool_catalog_import(ImportOutcome),
    completion_skill_context_policy(Budget, Policy),
    append([capabilities(Capabilities), policy(Policy)],
           ModeOptions,
           CompileOptions),
    rlm_prompt_compiler:prompt_compile(Catalog,
                                       Query,
                                       CompileOptions,
                                       CompileOutcome),
    require_prompt_compile(CompileOutcome, Compiled),
    rlm_prompt_compiler:prompt_compiler_tool_schemas(Compiled, ToolSchemas).

require_tool_catalog_import(ok(_)) :- !.
require_tool_catalog_import(error(Error)) :-
    throw(completion_fault(tool_catalog_import_failed(Error))).

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
    Base = _{max_tokens:TokenLimit, temperature:Temperature},
    planner_reasoning_effort(Options, Effort),
    request_options_reasoning(Effort, Base, RequestOptions).

model_request_options(Options, TokenLimit, RequestOptions) :-
    option_value(temperature, Options, 0, Temperature),
    Base = _{max_tokens:TokenLimit, temperature:Temperature},
    completion_reasoning_effort(Options, Effort),
    request_options_reasoning(Effort, Base, RequestOptions).

completion_reasoning_effort(Options, Effort) :-
    option_value(reasoning_effort, Options, unspecified, Raw),
    normalize_optional_reasoning_effort(Raw, Effort).

planner_reasoning_effort(Options, Effort) :-
    option_value(planner_reasoning_effort, Options, inherit, Raw),
    (   Raw == inherit
    ->  completion_reasoning_effort(Options, Effort)
    ;   normalize_reasoning_effort(Raw, Effort)
    ).

normalize_optional_reasoning_effort(unspecified, unspecified) :-
    !.
normalize_optional_reasoning_effort(Raw, Effort) :-
    normalize_reasoning_effort(Raw, Effort).

normalize_reasoning_effort(Raw, Effort) :-
    reasoning_effort_atom(Raw, Candidate),
    (   memberchk(Candidate, [none,minimal,low,medium,high,xhigh,max])
    ->  Effort = Candidate
    ;   throw(completion_fault(invalid_reasoning_effort(Raw)))
    ).

reasoning_effort_atom(Value, Effort) :-
    atom(Value),
    !,
    downcase_atom(Value, Effort).
reasoning_effort_atom(Value, Effort) :-
    string(Value),
    !,
    string_lower(Value, Lower),
    atom_string(Effort, Lower).
reasoning_effort_atom(Value, _) :-
    throw(completion_fault(invalid_reasoning_effort(Value))).

request_options_reasoning(unspecified, Options, Options) :-
    !.
request_options_reasoning(Effort, Options0, Options) :-
    put_dict(reasoning, Options0, _{effort:Effort}, Options).

enforce_plan_reasoning_options(Options, Plan0, Plan) :-
    completion_reasoning_effort(Options, Effort),
    enforce_plan_reasoning_effort(Effort, Plan0, Plan).

enforce_plan_reasoning_effort(unspecified, Plan, Plan) :-
    !.
enforce_plan_reasoning_effort(Effort, plan(Steps0), plan(Steps)) :-
    maplist(enforce_step_reasoning_effort(Effort), Steps0, Steps).

enforce_step_reasoning_effort(Effort,
                              model(Provider, Prompt, RequestOptions0, Bind),
                              model(Provider, Prompt, RequestOptions, Bind)) :-
    !,
    put_dict(reasoning,
             RequestOptions0,
             _{effort:Effort},
             RequestOptions).
enforce_step_reasoning_effort(Effort, rlm(Plan0, Bind), rlm(Plan, Bind)) :-
    !,
    enforce_plan_reasoning_effort(Effort, Plan0, Plan).
enforce_step_reasoning_effort(Effort,
                              parallel(Plans0, Bind),
                              parallel(Plans, Bind)) :-
    !,
    maplist(enforce_plan_reasoning_effort(Effort), Plans0, Plans).
enforce_step_reasoning_effort(Effort,
                              retry(Attempts, Plan0, Bind),
                              retry(Attempts, Plan, Bind)) :-
    !,
    enforce_plan_reasoning_effort(Effort, Plan0, Plan).
enforce_step_reasoning_effort(_, Step, Step).

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
completion_exception(completion_fault(invalid_prompt_compile_mode(Mode)),
                     error(completion_error{
                               phase:prompt_compile,
                               kind:invalid_prompt_compile_mode,
                               mode:Mode,
                               message:"invalid trusted prompt_compile_mode"
                           })) :-
    !.
completion_exception(completion_fault(Fault),
                     error(completion_error{phase:runtime,
                                            kind:completion_fault,
                                            detail:Fault,
                                            message:"completion runtime rejected the operation"})) :-
    !.
completion_exception(
    prompt_compile_fault(
        completion_fault(prompt_compile_failed(CompilerError))),
    error(completion_error{
              phase:prompt_compile,
              kind:token_budget_exceeded,
              cause:CompilerError,
              message:"mandatory skill context exceeds the completion token budget"
          })) :-
    is_dict(CompilerError),
    get_dict(detail, CompilerError, context_budget_failed(_)),
    !.
completion_exception(
    prompt_compile_fault(
        completion_fault(explicit_skill_rejected(Name, Explanation))),
    error(completion_error{
              phase:prompt_compile,
              kind:explicit_skill_rejected,
              skill:Name,
              cause:Explanation,
              message:"explicit skill was rejected before planner dispatch"
          })) :-
    !.
completion_exception(prompt_compile_fault(Cause),
                     error(completion_error{
                               phase:prompt_compile,
                               kind:skill_compilation_failed,
                               cause:Cause,
                               message:"skill projection failed before planner dispatch"
                           })) :-
    !.
completion_exception(Exception,
                     error(completion_error{phase:runtime,
                                            kind:exception,
                                            exception:Safe,
                                            message:"completion runtime raised an exception"})) :-
    safe_exception(Exception, Safe).
