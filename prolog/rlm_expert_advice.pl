:- module(rlm_expert_advice,
          [ rlm_expert_advice_ready/0,
            expert_tool_candidates/2,
            expert_tool_select/4,
            expert_mode_signal/2,
            expert_auto_route/6,
            expert_advice_build/3,
            expert_advice_model_request/4,
            expert_advice_model_step/5
          ]).

/** <module> Expert-guided symbolic tool advice

This module composes the canonical leaf-expert runtime with the canonical
prompt compiler and provider boundary.

Experts are trusted deterministic Prolog handlers registered through
rlm_expert. Registration projects each expert as an ordinary read-only tool,
so an expert has one implementation and one capability boundary. This module
does not register handlers and never receives a callable.

For natural-language routing, the prompt compiler ranks only sanitized tool
metadata. Results are filtered back through the inert expert catalog, then
rlm_expert performs the authoritative goal/priority/capability selection.
Advice is closed data. It changes strategy, never authority.

The optional model step is exactly one rlm_chain:model_complete/3 call. The
request exposes only the selected expert-tool schema. A returned tool call is a
proposal; this module does not execute it.
*/

:- use_module(library(lists), [sum_list/2]).
:- use_module(library(pairs), [pairs_keys/2]).

:- use_module(rlm_tool,
              [ tool_lookup/3,
                capabilities_normalize/2
              ]).
:- use_module(rlm_expert,
              [ rlm_expert_ready/0,
                expert_catalog/2,
                expert_select/4
              ]).
:- use_module(rlm_prompt_compiler,
              [ prompt_catalog_create/1,
                prompt_catalog_destroy/1,
                prompt_catalog_register_tool_registry/4,
                prompt_catalog_search/4
              ]).
:- use_module(rlm_native_tool,
              [ native_tool_schema_normalize/2,
                native_tool_schema_wire/3
              ]).
:- use_module(rlm_chain,
              [ model_complete/3
              ]).
:- use_module(rlm_reasoning_mode,
              [ reasoning_mode_select/4
              ]).

rlm_expert_advice_ready :-
    rlm_expert_ready.

expert_tool_candidates(Registry, Outcome) :-
    catch(
        ( expert_catalog(Registry, Contracts),
          maplist(contract_candidate(Registry), Contracts, Candidates),
          Outcome = ok(Candidates)
        ),
        Exception,
        expert_exception(candidates, Exception, Outcome)
    ).

contract_candidate(Registry, Contract, Candidate) :-
    Name = Contract.id,
    tool_lookup(Registry, Name, Lookup),
    require_tool_lookup(Lookup, Name, Schema),
    Candidate = expert_candidate{
                    id:expert(Name),
                    name:Name,
                    goal:Contract.goal,
                    version:Contract.version,
                    priority:Contract.priority,
                    description:Contract.description,
                    required_capability:Schema.capability,
                    effect:Schema.effect,
                    limits:Schema.limits,
                    schema:Schema,
                    contract:Contract,
                    source:expert_registry
                }.

expert_tool_select(Registry, Query0, Context0, Outcome) :-
    catch(
        ( bounded_query(Query0, Query),
          normalize_expert_context(Context0, Context),
          expert_catalog(Registry, Contracts),
          select_with_contracts(Contracts, Registry, Query, Context, Selection),
          Outcome = ok(Selection)
        ),
        Exception,
        expert_exception(select, Exception, Outcome)
    ).

select_with_contracts([], _, _, _, Selection) :-
    !,
    no_expert_selection(Selection).
select_with_contracts(Contracts, Registry, Query, Context, Selection) :-
    setup_call_cleanup(
        prompt_catalog_create(Catalog),
        select_from_catalog(
            Catalog,
            Registry,
            Contracts,
            Query,
            Context,
            Selection
        ),
        prompt_catalog_destroy(Catalog)
    ).

select_from_catalog(Catalog, Registry, Contracts, Query, Context, Selection) :-
    prompt_catalog_register_tool_registry(
        Catalog,
        Registry,
        [],
        RegisterOutcome
    ),
    require_compiler_outcome(RegisterOutcome, register),
    prompt_catalog_search(
        Catalog,
        Query,
        [ limit(64),
          discovery_scope([kind(tool)])
        ],
        SearchOutcome
    ),
    require_compiler_value(SearchOutcome, search, Search),
    first_expert_match(Search.results, Contracts, Match),
    select_matched_expert(Match, Registry, Contracts, Context, Selection).

first_expert_match([], _, none).
first_expert_match([Metadata|Rest], Contracts, Match) :-
    ( contract_named(Contracts, Metadata.name, Contract)
    -> Match = match(Metadata, Contract)
    ; first_expert_match(Rest, Contracts, Match)
    ).

contract_named([Contract|_], Name, Contract) :-
    Contract.id == Name,
    !.
contract_named([_|Contracts], Name, Contract) :-
    contract_named(Contracts, Name, Contract).

select_matched_expert(none, _, _, _, Selection) :-
    !,
    no_expert_selection(Selection).
select_matched_expert(
    match(Metadata, MatchedContract),
    Registry,
    Contracts,
    Context,
    Selection
) :-
    expert_select(
        Registry,
        MatchedContract.goal,
        Context,
        DecisionOutcome
    ),
    selection_from_expert_decision(
        DecisionOutcome,
        Metadata,
        Registry,
        Contracts,
        Selection
    ).

selection_from_expert_decision(
    error(Error),
    _,
    _,
    _,
    Selection
) :-
    is_dict(Error, expert_error),
    Error.kind == no_applicable_expert,
    !,
    no_expert_selection(Selection).
selection_from_expert_decision(
    error(Error),
    _,
    _,
    _,
    _
) :-
    throw(expert_fault(expert_selection(Error))).
selection_from_expert_decision(
    ok(Decision),
    Metadata,
    Registry,
    Contracts,
    Selection
) :-
    contract_named(Contracts, Decision.selected, SelectedContract),
    contract_candidate(Registry, SelectedContract, Candidate),
    Selection = expert_selection{
                    applicable:true,
                    candidate:Candidate,
                    decision:Decision,
                    query_score:Metadata.score,
                    source:expert_registry
                }.

no_expert_selection(
    expert_selection{
        applicable:false,
        candidate:none,
        decision:none,
        query_score:0,
        source:expert_registry
    }
).

expert_mode_signal(Selection, Signal) :-
    ( is_dict(Selection, expert_selection),
      get_dict(applicable, Selection, Applicable),
      memberchk(Applicable, [true,false])
    -> Signal = reasoning_task_context{expert_applicable:Applicable}
    ; throw(expert_fault(invalid_selection(Selection)))
    ).


expert_auto_route(
    ModeContext,
    Registry,
    Query,
    ExpertContext,
    TaskSignals0,
    Outcome
) :-
    catch(
        expert_auto_route_(
            ModeContext,
            Registry,
            Query,
            ExpertContext,
            TaskSignals0,
            Outcome
        ),
        Exception,
        expert_exception(auto_route, Exception, Outcome)
    ).

expert_auto_route_(
    ModeContext,
    Registry,
    Query,
    ExpertContext,
    TaskSignals0,
    Outcome
) :-
    normalize_auto_task_signals(TaskSignals0, TaskSignals),
    expert_tool_select(
        Registry,
        Query,
        ExpertContext,
        SelectionOutcome
    ),
    require_advice_outcome(SelectionOutcome, expert_selection, Selection),
    expert_mode_signal(Selection, ExpertSignal),
    ExpertApplicable = ExpertSignal.expert_applicable,
    put_dict(
        expert_applicable,
        TaskSignals,
        ExpertApplicable,
        CombinedSignals
    ),
    reasoning_mode_select(
        ModeContext,
        CombinedSignals,
        [],
        ModeOutcome
    ),
    require_mode_outcome(ModeOutcome, ModeState),
    Outcome = ok(expert_auto_route{
                     mode:ModeState,
                     selection:Selection,
                     signals:CombinedSignals
                 }).

normalize_auto_task_signals(Input, Signals) :-
    ( is_dict(Input)
    -> true
    ; throw(expert_fault(invalid_route_signals(expected_object)))
    ),
    ( get_dict(expert_applicable, Input, _)
    -> throw(expert_fault(
                 invalid_route_signals(
                     reserved_field(expert_applicable)
                 )))
    ; true
    ),
    dict_pairs(Input, _, Pairs),
    dict_pairs(Signals, reasoning_task_context, Pairs).

require_advice_outcome(ok(Value), _, Value) :-
    !.
require_advice_outcome(error(Error), Phase, _) :-
    throw(expert_fault(nested_error(Phase, Error))).

require_mode_outcome(ok(Value), Value) :-
    !.
require_mode_outcome(error(Error), _) :-
    throw(expert_fault(mode_selection(Error))).

expert_advice_build(Selection, Evidence0, Outcome) :-
    catch(
        ( require_applicable_selection(Selection, Candidate),
          normalize_evidence(Evidence0, Evidence),
          Advice = expert_advice{
                       expert:Candidate.id,
                       expert_goal:Candidate.goal,
                       expert_version:Candidate.version,
                       selected_tool:Candidate.name,
                       recommendation:recommend_tool(Candidate.name),
                       required_capability:Candidate.required_capability,
                       effect:Candidate.effect,
                       source:Candidate.source,
                       rationale:expert_goal_priority_and_registry_relevance,
                       evidence:Evidence,
                       stop_condition:one_model_step,
                       tool_schema:Candidate.schema
                   },
          Outcome = ok(Advice)
        ),
        Exception,
        expert_exception(advice, Exception, Outcome)
    ).

expert_advice_model_request(Advice, Query0, Options0, Outcome) :-
    catch(
        ( require_advice(Advice),
          bounded_query(Query0, Query),
          model_request_options(Options0, MaxTokens),
          advice_wire_tool(Advice, Wire),
          advice_system_text(Advice, SystemText),
          Request = model_request{
                        messages:[
                            message{role:system, content:SystemText},
                            message{role:user, content:Query}
                        ],
                        options:_{
                            max_tokens:MaxTokens,
                            temperature:0,
                            tool_choice:auto,
                            tools:[Wire]
                        }
                    },
          Outcome = ok(Request)
        ),
        Exception,
        expert_exception(model_request, Exception, Outcome)
    ).

expert_advice_model_step(Provider, Advice, Query, Options, Outcome) :-
    expert_advice_model_request(Advice, Query, Options, RequestOutcome),
    model_step_after_request(RequestOutcome, Provider, Outcome).

model_step_after_request(error(Error), _, error(Error)) :-
    !.
model_step_after_request(ok(Request), Provider, Outcome) :-
    model_complete(Provider, Request, Outcome).

advice_wire_tool(Advice, Wire) :-
    native_tool_schema_normalize(Advice.tool_schema, NativeOutcome),
    require_native_value(NativeOutcome, normalize_schema, Native),
    native_tool_schema_wire(openai_compatible, Native, WireOutcome),
    require_native_value(WireOutcome, render_schema, Wire).

advice_system_text(Advice, Text) :-
    format(
        string(Text),
        "Symbolic expert ~q selected expert-tool ~q for goal ~q. You have exactly one reasoning step. Use the offered tool only if it is necessary; otherwise answer directly. Do not assume any tool call has executed. Return control to the symbolic supervisor after this response. Expert evidence: ~q",
        [ Advice.expert,
          Advice.selected_tool,
          Advice.expert_goal,
          Advice.evidence
        ]
    ).

normalize_expert_context(Context0, Context) :-
    ( is_dict(Context0)
    -> true
    ; throw(expert_fault(invalid_context(expected_object)))
    ),
    dict_pairs(Context0, _, Pairs),
    pairs_keys(Pairs, Keys0),
    sort(Keys0, Keys),
    ( Keys == [capabilities]
    -> true
    ; throw(expert_fault(invalid_context(unexpected_fields(Keys)))
    ),
    capabilities_normalize(Context0.capabilities, CapsOutcome),
    require_capabilities(CapsOutcome, Capabilities),
    Context = expert_context{capabilities:Capabilities}.

require_capabilities(ok(Capabilities), Capabilities) :-
    !.
require_capabilities(error(Error), _) :-
    throw(expert_fault(invalid_context(capabilities(Error)))).

require_applicable_selection(Selection, Candidate) :-
    ( is_dict(Selection, expert_selection),
      Selection.applicable == true,
      Selection.candidate \== none
    -> Candidate = Selection.candidate
    ; throw(expert_fault(no_applicable_expert))
    ).

require_advice(Advice) :-
    ( is_dict(Advice, expert_advice),
      ground(Advice),
      acyclic_term(Advice),
      Advice.stop_condition == one_model_step,
      Advice.source == expert_registry,
      SelectedTool = Advice.selected_tool,
      Advice.recommendation = recommend_tool(SelectedTool)
    -> true
    ; throw(expert_fault(invalid_advice(Advice)))
    ).

normalize_evidence(Evidence0, Evidence) :-
    ( is_list(Evidence0)
    -> true
    ; throw(expert_fault(invalid_evidence(expected_list)))
    ),
    length(Evidence0, Count),
    ( Count =< 16
    -> true
    ; throw(expert_fault(invalid_evidence(too_many_items(Count,16))))
    ),
    maplist(normalize_evidence_item, Evidence0, Evidence),
    maplist(string_length, Evidence, Lengths),
    sum_list(Lengths, Total),
    ( Total =< 2048
    -> true
    ; throw(expert_fault(invalid_evidence(too_many_characters(Total,2048))))
    ).

normalize_evidence_item(Value, Text) :-
    ( string(Value)
    -> Text = Value
    ; atom(Value)
    -> atom_string(Value, Text)
    ; throw(expert_fault(invalid_evidence(non_text(Value))))
    ),
    string_length(Text, Length),
    ( Length =< 256
    -> true
    ; throw(expert_fault(invalid_evidence(item_too_long(Length,256))))
    ).

bounded_query(Value, Query) :-
    ( string(Value)
    -> Query = Value
    ; atom(Value)
    -> atom_string(Value, Query)
    ; throw(expert_fault(invalid_query(Value)))
    ),
    string_length(Query, Length),
    ( Length >= 1,
      Length =< 4096
    -> true
    ; throw(expert_fault(invalid_query_length(Length)))
    ).

model_request_options(Options, MaxTokens) :-
    ( is_list(Options)
    -> model_request_options_(Options, 256, MaxTokens)
    ; throw(expert_fault(invalid_options(expected_list)))
    ).

model_request_options_([], MaxTokens, MaxTokens).
model_request_options_([max_tokens(Value)|Rest], _, MaxTokens) :-
    !,
    ( integer(Value),
      Value >= 1,
      Value =< 4096
    -> model_request_options_(Rest, Value, MaxTokens)
    ; throw(expert_fault(invalid_options(max_tokens(Value))))
    ).
model_request_options_([Option|_], _, _) :-
    throw(expert_fault(invalid_options(unknown_option(Option)))).

require_compiler_outcome(ok(_), _) :-
    !.
require_compiler_outcome(error(Error), Phase) :-
    throw(expert_fault(compiler_error(Phase, Error))).

require_compiler_value(ok(Value), _, Value) :-
    !.
require_compiler_value(error(Error), Phase, _) :-
    throw(expert_fault(compiler_error(Phase, Error))).

require_tool_lookup(ok(Schema), _, Schema) :-
    !.
require_tool_lookup(error(Error), Name, _) :-
    throw(expert_fault(tool_lookup_failed(Name, Error))).

require_native_value(ok(Value), _, Value) :-
    !.
require_native_value(error(Error), Phase, _) :-
    throw(expert_fault(native_schema_error(Phase, Error))).

expert_exception(
    Phase,
    expert_fault(invalid_route_signals(Detail)),
    error(expert_advice_error{
              phase:Phase,
              kind:invalid_route_signals,
              detail:Detail,
              message:"expert auto-route task signals are invalid"
          })
) :-
    !.
expert_exception(
    Phase,
    expert_fault(invalid_context(Detail)),
    error(expert_advice_error{
              phase:Phase,
              kind:invalid_context,
              detail:Detail,
              message:"expert selection context is invalid"
          })
) :-
    !.
expert_exception(
    Phase,
    expert_fault(invalid_options(Detail)),
    error(expert_advice_error{
              phase:Phase,
              kind:invalid_options,
              detail:Detail,
              message:"expert advice options are invalid"
          })
) :-
    !.
expert_exception(
    Phase,
    expert_fault(invalid_evidence(Detail)),
    error(expert_advice_error{
              phase:Phase,
              kind:invalid_evidence,
              detail:Detail,
              message:"expert evidence is invalid"
          })
) :-
    !.
expert_exception(
    Phase,
    expert_fault(Detail),
    error(expert_advice_error{
              phase:Phase,
              kind:invalid_request,
              detail:Detail,
              message:"expert advice request is invalid"
          })
) :-
    !.
expert_exception(
    Phase,
    Exception,
    error(expert_advice_error{
              phase:Phase,
              kind:exception,
              exception:Safe,
              message:"expert advice operation failed"
          })
) :-
    catch(
        term_string(
            Exception,
            Safe,
            [quoted(true), numbervars(true), max_depth(8)]
        ),
        _,
        Safe = "<unprintable exception>"
    ).
