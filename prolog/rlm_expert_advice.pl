:- module(rlm_expert_advice,
          [ rlm_expert_advice_ready/0,
            expert_tool_candidates/2,
            expert_tool_select/4,
            expert_mode_signal/2,
            expert_advice_build/3,
            expert_advice_model_request/4,
            expert_advice_model_step/5
          ]).

/** <module> Expert-guided symbolic tool advice

This is the compatibility bridge for issue #459 while the canonical expert
registry from #377 is landing.

The bridge treats sanitized registered tool schemas as inert expert candidates.
It never receives or exposes a trusted tool handler. Relevance selection reuses
rlm_prompt_compiler rather than creating a second router. Advice is closed data.
A selected tool remains subject to the ordinary rlm_tool capability, authority,
schema, effect, budget, cancellation, and persistence boundaries.

The optional model step is exactly one canonical rlm_chain:model_complete/3
call. The request exposes only the selected tool's provider schema. This module
does not execute a provider-returned tool call.
*/

:- use_module(library(lists), [sum_list/2]).

:- use_module(rlm_tool,
              [ tool_discover/2,
                tool_lookup/3
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

rlm_expert_advice_ready.

expert_tool_candidates(Registry, Outcome) :-
    catch(
        ( tool_discover(Registry, Schemas),
          maplist(schema_candidate, Schemas, Candidates),
          Outcome = ok(Candidates)
        ),
        Exception,
        expert_exception(candidates, Exception, Outcome)
    ).

schema_candidate(
    Schema,
    expert_candidate{
        id:tool(Name),
        name:Name,
        description:Schema.description,
        required_capability:Schema.capability,
        effect:Schema.effect,
        limits:Schema.limits,
        schema:Schema,
        source:tool_registry
    }
) :-
    Name = Schema.name.

expert_tool_select(Registry, Query0, Options0, Outcome) :-
    catch(
        ( bounded_query(Query0, Query),
          require_selection_options(Options0),
          setup_call_cleanup(
              prompt_catalog_create(Catalog),
              select_from_catalog(Catalog, Registry, Query, Selection),
              prompt_catalog_destroy(Catalog)
          ),
          Outcome = ok(Selection)
        ),
        Exception,
        expert_exception(select, Exception, Outcome)
    ).

select_from_catalog(Catalog, Registry, Query, Selection) :-
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
        [limit(1), discovery_scope([kind(tool)])],
        SearchOutcome
    ),
    require_compiler_value(SearchOutcome, search, Search),
    search_selection(Search.results, Registry, Selection).

search_selection([], _,
                 expert_selection{
                     applicable:false,
                     candidate:none,
                     score:0,
                     source:prompt_compiler
                 }).
search_selection([Metadata|_], Registry,
                 expert_selection{
                     applicable:true,
                     candidate:Candidate,
                     score:Score,
                     source:prompt_compiler
                 }) :-
    Name = Metadata.name,
    Score = Metadata.score,
    tool_lookup(Registry, Name, Lookup),
    require_tool_lookup(Lookup, Name, Schema),
    schema_candidate(Schema, Candidate).

expert_mode_signal(Selection, Signal) :-
    ( is_dict(Selection, expert_selection),
      get_dict(applicable, Selection, Applicable),
      memberchk(Applicable, [true,false])
    -> Signal = reasoning_task_context{expert_applicable:Applicable}
    ; throw(expert_fault(invalid_selection(Selection)))
    ).

expert_advice_build(Selection, Evidence0, Outcome) :-
    catch(
        ( require_applicable_selection(Selection, Candidate),
          normalize_evidence(Evidence0, Evidence),
          Advice = expert_advice{
                       expert:Candidate.id,
                       selected_tool:Candidate.name,
                       recommendation:recommend_tool(Candidate.name),
                       required_capability:Candidate.required_capability,
                       effect:Candidate.effect,
                       source:Candidate.source,
                       rationale:deterministic_registry_relevance,
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
        "Symbolic expert ~q selected registered tool ~q. "
        "You have exactly one reasoning step. Use the offered tool only if it "
        "is necessary; otherwise answer directly. Do not assume any tool call "
        "has executed. Return control to the symbolic supervisor after this "
        "response. Expert evidence: ~q",
        [Advice.expert, Advice.selected_tool, Advice.evidence]
    ).

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
      Advice.source == tool_registry,
      Advice.recommendation = recommend_tool(Advice.selected_tool)
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

require_selection_options(Options) :-
    ( Options == []
    -> true
    ; is_list(Options)
    -> throw(expert_fault(invalid_options(unknown_options(Options))))
    ; throw(expert_fault(invalid_options(expected_list)))
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
