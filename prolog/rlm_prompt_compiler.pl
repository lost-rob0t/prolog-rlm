:- module(rlm_prompt_compiler,
          [ rlm_prompt_compiler_ready/0,
            prompt_catalog_create/1,
            prompt_catalog_destroy/1,
            prompt_catalog_register/3,
            prompt_catalog_register_tool_registry/4,
            prompt_catalog_search/4,
            prompt_catalog_search_schema/1,
            prompt_catalog_search_handler/4,
            prompt_compile/4,
            prompt_recompile/4,
            prompt_explain/3,
            prompt_render/3,
            prompt_compiler_context_units/2,
            prompt_compiler_tool_schemas/2
          ]).

/** <module> Symbolic provider-context compiler

The trusted runtime may know about far more capabilities than a model should see
on one turn.  This module compiles declarative catalog metadata and current
evidence into a bounded, inspectable provider-visible projection.

Registration, availability, contextual activation and execution authorization
are deliberately separate.  This module never executes a tool, stores a trusted
handler, grants a capability, starts an MCP server, or mutates runtime lifecycle
state merely because a unit becomes relevant.

Final token packing belongs to `rlm_context_budget`.  Compiler output is emitted
as ordinary context units so managed conversation, warm/cold context and prompt
compiler material can share one hard provider-visible budget.
*/

:- use_module(library(crypto)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(uuid)).
:- use_module(rlm_context_budget, []).
:- use_module(rlm_closed_data, []).
:- use_module(rlm_tool, []).

:- dynamic prompt_catalog_state/2.
:- dynamic prompt_catalog_unit/3.

rlm_prompt_compiler_ready :-
    rlm_context_budget:rlm_context_budget_ready,
    setup_call_cleanup(
        rlm_tool:tool_registry_create(Registry),
        true,
        rlm_tool:tool_registry_destroy(Registry)).

/* -------------------------------------------------------------------------
 * Catalog lifecycle
 * ---------------------------------------------------------------------- */

prompt_catalog_create(prompt_catalog(Id)) :-
    uuid(UUID, [version(4)]),
    atom_concat(prompt_catalog_, UUID, Id),
    with_mutex(rlm_prompt_catalog,
               assertz(prompt_catalog_state(Id, 0))).

prompt_catalog_destroy(prompt_catalog(Id)) :-
    with_mutex(rlm_prompt_catalog,
               ( retractall(prompt_catalog_unit(Id, _, _)),
                 retractall(prompt_catalog_state(Id, _))
               )).

prompt_catalog_register(Catalog, UnitSpec0, Outcome) :-
    catch(( require_catalog(Catalog, Id),
            normalize_unit_spec(UnitSpec0, UnitSpec),
            register_catalog_unit(Id, UnitSpec, Registration),
            Outcome = ok(Registration)
          ),
          Exception,
          compiler_exception(catalog_register, Exception, Outcome)).

register_catalog_unit(Id, UnitSpec, Registration) :-
    Unit = UnitSpec.unit,
    with_mutex(rlm_prompt_catalog,
               register_catalog_unit_locked(Id,
                                            Unit,
                                            UnitSpec,
                                            Registration)).

register_catalog_unit_locked(Id, Unit, UnitSpec, Registration) :-
    (   prompt_catalog_unit(Id, Unit, Existing)
    ->  (   Existing == UnitSpec
        ->  catalog_revision(Id, Revision),
            Registration = catalog_registration{unit:Unit,
                                                status:existing,
                                                revision:Revision}
        ;   throw(prompt_compiler_fault(duplicate_unit(Unit)))
        )
    ;   assertz(prompt_catalog_unit(Id, Unit, UnitSpec)),
        bump_catalog_revision(Id, Revision),
        Registration = catalog_registration{unit:Unit,
                                            status:registered,
                                            revision:Revision}
    ).

prompt_catalog_register_tool_registry(Catalog,
                                      Registry,
                                      Options,
                                      Outcome) :-
    catch(( require_options(Options),
            require_catalog(Catalog, _),
            rlm_tool:tool_discover(Registry, Schemas),
            maplist(tool_schema_unit_spec(Options), Schemas, Specs),
            register_catalog_specs(Catalog, Specs, Registrations),
            Outcome = ok(catalog_import{kind:tool_registry,
                                        count:Registrations.count,
                                        registrations:Registrations.items})
          ),
          Exception,
          compiler_exception(tool_registry_import, Exception, Outcome)).

register_catalog_specs(Catalog, Specs, Result) :-
    register_catalog_specs(Catalog, Specs, [], Rev),
    reverse(Rev, Items),
    length(Items, Count),
    Result = registrations{count:Count, items:Items}.

register_catalog_specs(_, [], Items, Items).
register_catalog_specs(Catalog, [Spec|Specs], Acc, Items) :-
    prompt_catalog_register(Catalog, Spec, Outcome),
    require_compiler_outcome(Outcome, Registration),
    register_catalog_specs(Catalog,
                           Specs,
                           [Registration|Acc],
                           Items).

tool_schema_unit_spec(Options, Schema0, Spec) :-
    sanitize_tool_schema(Schema0, Schema),
    Name = Schema.name,
    option(tool_category(Category0), Options, local_tool),
    normalize_name(Category0, Category),
    option(tool_priority(Priority), Options, 100),
    require_nonnegative_integer(Priority, tool_priority),
    option(tool_aliases(AliasMap), Options, []),
    schema_aliases(Name, AliasMap, Aliases),
    schema_triggers(Name, Aliases, Triggers),
    Spec = prompt_unit{unit:tool(Name),
                       name:Name,
                       kind:tool,
                       category:Category,
                       description:Schema.description,
                       available:true,
                       aliases:Aliases,
                       triggers:Triggers,
                       requires:[],
                       suggests:[],
                       conflicts:[],
                       supersedes:[],
                       requires_capability:Schema.capability,
                       priority:Priority,
                       provider_visible:true,
                       mandatory_context:true,
                       schema:Schema,
                       content:none,
                       representations:[],
                       provenance:"tool_registry"}.

schema_aliases(Name, AliasMap, Aliases) :-
    (   member(Name-Aliases0, AliasMap)
    ->  normalize_aliases(Aliases0, Aliases)
    ;   Aliases = []
    ).

schema_triggers(Name, Aliases, Triggers) :-
    atom_string(Name, NameText),
    maplist(alias_trigger, Aliases, AliasTriggers),
    Triggers = [trigger(keyword(NameText), 40)|AliasTriggers].

alias_trigger(Alias, trigger(keyword(Alias), 20)).

/* -------------------------------------------------------------------------
 * Bounded sanitized discovery
 * ---------------------------------------------------------------------- */

prompt_catalog_search(Catalog, Query0, Options, Outcome) :-
    catch(( require_catalog(Catalog, Id),
            require_options(Options),
            bounded_search_query(Query0, Query),
            discovery_scope(Options, Scope),
            search_limit(Options, Limit),
            option(include_unavailable(IncludeUnavailable), Options, false),
            require_boolean(IncludeUnavailable, include_unavailable),
            catalog_snapshot(Id, _, Specs),
            findall(Ranked,
                    searchable_spec(Query,
                                    Scope,
                                    IncludeUnavailable,
                                    Specs,
                                    Ranked),
                    Ranked0),
            predsort(compare_search_result, Ranked0, Ranked),
            take_first(Limit, Ranked, Selected, Truncated),
            maplist(search_result_metadata, Selected, Results),
            Outcome = ok(catalog_search{query:Query,
                                        limit:Limit,
                                        truncated:Truncated,
                                        results:Results})
          ),
          Exception,
          compiler_exception(catalog_search, Exception, Outcome)).

searchable_spec(Query, Scope, IncludeUnavailable, Specs, Ranked) :-
    member(Spec, Specs),
    scope_allows(Scope, Spec),
    (IncludeUnavailable == true ; Spec.available == true),
    search_score(Query, Spec, Score),
    Score > 0,
    Ranked = search_rank{score:Score, spec:Spec}.

search_score(Query, Spec, Score) :-
    text_tokens(Query, QueryTokens),
    searchable_text(Spec, SearchText),
    text_tokens(SearchText, SearchTokens),
    intersection(QueryTokens, SearchTokens, Common0),
    exclude(stop_token, Common0, Common),
    length(Common, CommonCount),
    unit_short_text(Spec.unit, UnitText),
    string_lower(UnitText, UnitLower),
    string_lower(Query, QueryLower),
    name_match_bonus(UnitLower, QueryLower, NameBonus),
    Evidence is NameBonus+(CommonCount*10),
    (   Evidence > 0
    ->  Score is Evidence+Spec.priority
    ;   Score = 0
    ).

name_match_bonus(Unit, Query, 80) :-
    sub_string(Unit, _, _, _, Query),
    !.
name_match_bonus(Unit, Query, 60) :-
    sub_string(Query, _, _, _, Unit),
    !.
name_match_bonus(_, _, 0).

compare_search_result(Order, A, B) :-
    compare_ranked(Order, A.score, A.spec.unit, B.score, B.spec.unit).

search_result_metadata(Ranked, Metadata) :-
    Spec = Ranked.spec,
    safe_term_text(Spec.unit, UnitText),
    safe_term_text(Spec.requires_capability, CapabilityText),
    Metadata = catalog_metadata{unit:UnitText,
                                name:Spec.name,
                                kind:Spec.kind,
                                category:Spec.category,
                                description:Spec.description,
                                available:Spec.available,
                                requires_capability:CapabilityText,
                                provenance:Spec.provenance,
                                score:Ranked.score}.

prompt_catalog_search_schema(
    tool_schema{name:search_tools,
                description:"Search the bounded model-visible capability catalog. Results are sanitized metadata only and do not grant tool authority.",
                capability:prompt(discover),
                effect:read,
                arguments:_{type:object,
                            required:[query],
                            additional_properties:false,
                            properties:_{query:_{type:string},
                                         limit:_{type:integer,
                                                 minimum:1,
                                                 maximum:32}}},
                result:_{type:object,
                         required:[results, truncated],
                         additional_properties:true},
                limits:_{time_limit:1.0,
                         max_output_bytes:16384}}).

prompt_catalog_search_handler(Catalog, BaseOptions, Args, Result) :-
    get_dict(query, Args, Query),
    (   get_dict(limit, Args, Limit)
    ->  SearchOptions = [limit(Limit)|BaseOptions]
    ;   SearchOptions = BaseOptions
    ),
    prompt_catalog_search(Catalog, Query, SearchOptions, Outcome),
    require_compiler_outcome(Outcome, Search),
    maplist(metadata_json, Search.results, JSONResults),
    Result = json{results:JSONResults,
                  truncated:Search.truncated}.

metadata_json(Metadata,
              json{unit:Metadata.unit,
                   name:Name,
                   kind:Kind,
                   category:Category,
                   description:Metadata.description,
                   available:Metadata.available,
                   requires_capability:Metadata.requires_capability,
                   provenance:Metadata.provenance,
                   score:Metadata.score}) :-
    atom_string(Metadata.name, Name),
    atom_string(Metadata.kind, Kind),
    atom_string(Metadata.category, Category).

/* -------------------------------------------------------------------------
 * Compilation
 * ---------------------------------------------------------------------- */

prompt_compile(Catalog, Input0, Options, Outcome) :-
    catch(( require_catalog(Catalog, Id),
            require_options(Options),
            normalize_compile_input(Input0, Input),
            compile_projection(Catalog,
                               Id,
                               Input,
                               Options,
                               Projection),
            maybe_pack_projection(Projection,
                                  Options,
                                  Compiled),
            Outcome = ok(Compiled)
          ),
          Exception,
          compiler_exception(compile, Exception, Outcome)).

compile_projection(Catalog, Id, Input, Options, Projection) :-
    catalog_snapshot(Id, Revision, Specs),
    catalog_fingerprint(Specs, CatalogFingerprint),
    compile_capabilities(Options, Capabilities),
    discovery_scope(Options, Scope),
    compile_mode(Options, Mode),
    initial_candidates(Specs,
                       Input,
                       Capabilities,
                       Scope,
                       Mode,
                       Options,
                       Candidates,
                       InitialRejected),
    resolve_candidates(Candidates,
                       Specs,
                       Capabilities,
                       Scope,
                       Resolved0,
                       ResolveRejected,
                       DependencyEdges0),
    dedupe_resolved(Resolved0, RequiredResolved),
    add_suggestions(RequiredResolved,
                    Specs,
                    Capabilities,
                    Scope,
                    SuggestedResolved,
                    SuggestionEdges),
    append(RequiredResolved, SuggestedResolved, WithSuggestions0),
    dedupe_resolved(WithSuggestions0, WithSuggestions),
    append(DependencyEdges0, SuggestionEdges, DependencyEdges1),
    sort(DependencyEdges1, DependencyEdges),
    apply_supersession(WithSuggestions,
                       Specs,
                       SupersededFiltered,
                       SupersededRejected),
    apply_conflicts(SupersededFiltered,
                    Specs,
                    SelectedEntries,
                    ConflictRejected),
    append([InitialRejected,
            ResolveRejected,
            SupersededRejected,
            ConflictRejected],
           Rejected0),
    sort_rejections(Rejected0, Rejected),
    build_context_units(SelectedEntries,
                        Options,
                        ContextUnits),
    selected_tool_schemas(SelectedEntries, ToolSchemas),
    selected_unit_terms(SelectedEntries, SelectedUnits),
    grouped_selected_units(SelectedEntries, Groups),
    candidate_public(Candidates, CandidatePublic),
    selected_public(SelectedEntries, SelectedPublic),
    compilation_reasons(SelectedEntries, Rejected, Reasons),
    material_fingerprint(CatalogFingerprint,
                         Input,
                         Capabilities,
                         Scope,
                         Mode,
                         ContextUnits,
                         Options,
                         Fingerprint),
    Projection = compiled_context{
                     catalog:Catalog,
                     catalog_revision:Revision,
                     catalog_fingerprint:CatalogFingerprint,
                     input:Input,
                     signals:Input.signals,
                     candidates:CandidatePublic,
                     selected:SelectedPublic,
                     selected_units:SelectedUnits,
                     dependencies:DependencyEdges,
                     rejected:Rejected,
                     reasons:Reasons,
                     capabilities:Capabilities,
                     discovery_scope:Scope,
                     mode:Mode,
                     instructions:Groups.instructions,
                     skills:Groups.skills,
                     tools:Groups.tools,
                     mcp_servers:Groups.mcp_servers,
                     mcp_tools:Groups.mcp_tools,
                     mcp_prompts:Groups.mcp_prompts,
                     resources:Groups.resources,
                     context_units:ContextUnits,
                     tool_schemas:ToolSchemas,
                     token_ledger:none,
                     context_pack:none,
                     active_units:SelectedUnits,
                     fingerprint:Fingerprint}.

maybe_pack_projection(Projection, Options, Compiled) :-
    option(pack(Pack), Options, true),
    require_boolean(Pack, pack),
    (   Pack == false
    ->  Compiled = Projection
    ;   option(policy(Policy), Options, []),
        rlm_context_budget:context_pack(Projection.context_units,
                                        [],
                                        Policy,
                                        PackOutcome),
        require_budget_outcome(PackOutcome, ContextPack),
        active_units_from_pack(ContextPack, ActiveUnits),
        put_dict(_{token_ledger:ContextPack.ledger,
                   context_pack:ContextPack,
                   active_units:ActiveUnits},
                 Projection,
                 Compiled)
    ).

prompt_recompile(Compiled0, Event, Options, Outcome) :-
    catch(( require_compiled_context(Compiled0),
            recompile_input(Compiled0.input, Event, Input),
            prompt_compile(Compiled0.catalog, Input, Options, Outcome)
          ),
          Exception,
          compiler_exception(recompile, Exception, Outcome)).

recompile_input(Input0, needs(Need), Input) :-
    !,
    append(Input0.needs, [Need], Needs0),
    sort(Needs0, Needs),
    needs_signals(Needs, NeedSignals),
    append(Input0.base_signals, NeedSignals, Signals0),
    sort(Signals0, Signals),
    put_dict(_{needs:Needs, signals:Signals}, Input0, Input).
recompile_input(Input0, user_message(Text0), Input) :-
    !,
    bounded_input_text(Text0, Text),
    put_dict(text, Input0, Text, Input).
recompile_input(Input0, signals(Signals0), Input) :-
    !,
    require_list(Signals0, signals),
    append(Input0.base_signals, Signals0, Base0),
    sort(Base0, Base),
    needs_signals(Input0.needs, NeedSignals),
    append(Base, NeedSignals, Signals1),
    sort(Signals1, Signals),
    put_dict(_{base_signals:Base, signals:Signals}, Input0, Input).
recompile_input(Input0, Event, Input) :-
    append(Input0.base_signals, [Event], Base0),
    sort(Base0, Base),
    needs_signals(Input0.needs, NeedSignals),
    append(Base, NeedSignals, Signals0),
    sort(Signals0, Signals),
    put_dict(_{base_signals:Base, signals:Signals}, Input0, Input).

/* -------------------------------------------------------------------------
 * Input evidence and candidate generation
 * ---------------------------------------------------------------------- */

normalize_compile_input(Input0, Input) :-
    (   string(Input0)
    ->  bounded_input_text(Input0, Text),
        BaseSignals = [], Needs = [], Selected = [], Denied = []
    ;   atom(Input0)
    ->  atom_string(Input0, Text0),
        bounded_input_text(Text0, Text),
        BaseSignals = [], Needs = [], Selected = [], Denied = []
    ;   is_dict(Input0)
    ->  dict_default(Input0, text, "", Text0),
        bounded_input_text(Text0, Text),
        dict_default(Input0, signals, [], BaseSignals0),
        require_list(BaseSignals0, signals),
        sort(BaseSignals0, BaseSignals),
        dict_default(Input0, needs, [], Needs0),
        require_list(Needs0, needs),
        sort(Needs0, Needs),
        dict_default(Input0, selected, [], Selected0),
        require_list(Selected0, selected),
        sort(Selected0, Selected),
        dict_default(Input0, denied, [], Denied0),
        require_list(Denied0, denied),
        sort(Denied0, Denied)
    ;   throw(prompt_compiler_fault(invalid_input(Input0)))
    ),
    needs_signals(Needs, NeedSignals),
    append(BaseSignals, NeedSignals, Signals0),
    sort(Signals0, Signals),
    Input = prompt_input{text:Text,
                         base_signals:BaseSignals,
                         signals:Signals,
                         needs:Needs,
                         selected:Selected,
                         denied:Denied}.

needs_signals([], []).
needs_signals([Need|Needs], [need(Need)|Signals]) :-
    needs_signals(Needs, Signals).

initial_candidates(Specs,
                   Input,
                   Capabilities,
                   Scope,
                   all_tools,
                   _,
                   Candidates,
                   Rejected) :-
    !,
    findall(Candidate,
            ( member(Spec, Specs),
              root_candidate_status(Spec,
                                    Input,
                                    Capabilities,
                                    Scope,
                                    all_tools,
                                    Candidate,
                                    keep)
            ),
            Candidates0),
    findall(Rejection,
            ( member(Spec, Specs),
              root_candidate_status(Spec,
                                    Input,
                                    Capabilities,
                                    Scope,
                                    all_tools,
                                    Rejection,
                                    reject)
            ),
            Rejected),
    predsort(compare_candidate, Candidates0, Candidates).
initial_candidates(Specs,
                   Input,
                   Capabilities,
                   Scope,
                   compiled,
                   Options,
                   Candidates,
                   Rejected) :-
    findall(Candidate,
            ( member(Spec, Specs),
              root_candidate_status(Spec,
                                    Input,
                                    Capabilities,
                                    Scope,
                                    compiled,
                                    Candidate,
                                    keep)
            ),
            Candidates0),
    findall(Rejection,
            ( member(Spec, Specs),
              root_candidate_status(Spec,
                                    Input,
                                    Capabilities,
                                    Scope,
                                    compiled,
                                    Rejection,
                                    reject)
            ),
            Rejected),
    predsort(compare_candidate, Candidates0, Ranked),
    candidate_limit(Options, Limit),
    take_first(Limit, Ranked, Candidates, _).

root_candidate_status(Spec,
                      Input,
                      Capabilities,
                      Scope,
                      Mode,
                      Value,
                      Status) :-
    unit_evidence(Spec, Input, Mode, Score, Reasons),
    Score > 0,
    (   unit_negative_evidence(Spec, Input, NegativeReason)
    ->  Value = rejected_unit{unit:Spec.unit,
                              reasons:[NegativeReason]},
        Status = reject
    ;   Spec.available \== true
    ->  Value = rejected_unit{unit:Spec.unit,
                              reasons:[unavailable]},
        Status = reject
    ;   \+ scope_allows(Scope, Spec)
    ->  Value = rejected_unit{unit:Spec.unit,
                              reasons:[discovery_scope_denied]},
        Status = reject
    ;   \+ capability_eligible(Spec, Capabilities)
    ->  Value = rejected_unit{unit:Spec.unit,
                              reasons:[capability_denied(Spec.requires_capability)]},
        Status = reject
    ;   Value = candidate{unit:Spec.unit,
                          score:Score,
                          priority:Spec.priority,
                          reasons:Reasons},
        Status = keep
    ).

unit_evidence(Spec, _, all_tools, Score, Reasons) :-
    !,
    Score is 1000+Spec.priority,
    Reasons = [compatibility_mode(all_tools)].
unit_evidence(Spec, Input, compiled, Score, Reasons) :-
    explicit_score(Spec, Input, ExplicitScore, ExplicitReasons),
    trigger_score(Spec.triggers, Input, TriggerScore, TriggerReasons),
    lexical_score(Spec, Input.text, LexicalScore, LexicalReasons),
    BaseScore is ExplicitScore+TriggerScore+LexicalScore,
    append([ExplicitReasons, TriggerReasons, LexicalReasons], Reasons0),
    sort(Reasons0, Reasons),
    (   BaseScore > 0
    ->  Score is BaseScore+Spec.priority
    ;   Score = 0
    ).

explicit_score(Spec, Input, 100000, [explicit_selection]) :-
    memberchk(Spec.unit, Input.selected),
    !.
explicit_score(_, _, 0, []).

trigger_score(Triggers, Input, Score, Reasons) :-
    findall(Weight-Reason,
            ( member(Trigger, Triggers),
              trigger_match(Trigger, Input, Weight, Reason) ),
            Matches),
    findall(Weight, member(Weight-_, Matches), Weights),
    sum_list(Weights, Score),
    findall(Reason, member(_-Reason, Matches), Reasons).

trigger_match(trigger(phrase(Phrase0), Weight), Input, Weight,
              signal(phrase(Phrase), Weight)) :-
    normalize_small_text(Phrase0, Phrase),
    string_lower(Phrase, Lower),
    string_lower(Input.text, TextLower),
    sub_string(TextLower, _, _, _, Lower).
trigger_match(trigger(keyword(Keyword0), Weight), Input, Weight,
              signal(keyword(Keyword), Weight)) :-
    normalize_small_text(Keyword0, Keyword),
    text_tokens(Input.text, Tokens),
    string_lower(Keyword, Lower),
    memberchk(Lower, Tokens).
trigger_match(trigger(verb(Verb), Weight), Input, Weight,
              signal(verb(Verb), Weight)) :-
    ( memberchk(verb(Verb), Input.signals)
    ; signal_token_present(Verb, Input.text)
    ).
trigger_match(trigger(object(Object), Weight), Input, Weight,
              signal(object(Object), Weight)) :-
    ( memberchk(object(Object), Input.signals)
    ; signal_token_present(Object, Input.text)
    ).
trigger_match(trigger(need(Need), Weight), Input, Weight,
              signal(need(Need), Weight)) :-
    memberchk(need(Need), Input.signals).
trigger_match(trigger(Signal, Weight), Input, Weight,
              signal(Signal, Weight)) :-
    memberchk(Signal, Input.signals).

signal_token_present(Value, Text) :-
    safe_term_text(Value, ValueText0),
    string_lower(ValueText0, ValueText),
    text_tokens(Text, Tokens),
    text_tokens(ValueText, ValueTokens),
    ValueTokens \== [],
    subset(ValueTokens, Tokens).

lexical_score(Spec, Text, Score, Reasons) :-
    text_tokens(Text, InputTokens),
    searchable_text(Spec, SearchText),
    text_tokens(SearchText, SearchTokens),
    intersection(InputTokens, SearchTokens, Common0),
    exclude(stop_token, Common0, Common),
    length(Common, Count),
    (   Count > 0
    ->  Score is Count*5,
        Reasons = [lexical(Common, Score)]
    ;   Score = 0,
        Reasons = []
    ).

stop_token("a").
stop_token("an").
stop_token("and").
stop_token("for").
stop_token("in").
stop_token("of").
stop_token("on").
stop_token("or").
stop_token("the").
stop_token("to").
stop_token("tool").
stop_token("use").
stop_token("with").

unit_negative_evidence(Spec, Input, explicit_denial) :-
    memberchk(Spec.unit, Input.denied),
    !.
unit_negative_evidence(Spec, Input, signal_denial(Signal)) :-
    member(Signal, Input.signals),
    ( Signal = deny(Spec.unit)
    ; Signal = negated(Spec.unit)
    ; Signal = deny(category(Spec.category))
    ; Signal = negated(category(Spec.category))
    ),
    !.
unit_negative_evidence(Spec, Input, text_negation(Alias)) :-
    unit_negative_aliases(Spec, Aliases),
    member(Alias, Aliases),
    string_lower(Input.text, TextLower),
    string_lower(Alias, AliasLower),
    negative_phrase(AliasLower, Phrase),
    sub_string(TextLower, _, _, _, Phrase),
    !.

negative_phrase(Alias, Phrase) :- string_concat("without ", Alias, Phrase).
negative_phrase(Alias, Phrase) :- string_concat("do not use ", Alias, Phrase).
negative_phrase(Alias, Phrase) :- string_concat("don't use ", Alias, Phrase).
negative_phrase(Alias, Phrase) :- string_concat("dont use ", Alias, Phrase).

unit_negative_aliases(Spec, Aliases) :-
    unit_short_text(Spec.unit, UnitText),
    atom_string(Spec.name, NameText),
    append([UnitText, NameText], Spec.aliases, All0),
    sort(All0, Aliases).

searchable_text(Spec, Text) :-
    unit_short_text(Spec.unit, UnitText),
    atom_string(Spec.name, NameText),
    atom_string(Spec.category, CategoryText),
    atomics_to_string([UnitText,
                       NameText,
                       CategoryText,
                       Spec.description|Spec.aliases],
                      " ",
                      Text).

/* -------------------------------------------------------------------------
 * Dependency closure, suggestions and deterministic conflict handling
 * ---------------------------------------------------------------------- */

resolve_candidates([], _, _, _, [], [], []).
resolve_candidates([Candidate|Candidates],
                   Specs,
                   Capabilities,
                   Scope,
                   Resolved,
                   Rejected,
                   Edges) :-
    resolve_candidate(Candidate,
                      Specs,
                      Capabilities,
                      Scope,
                      CandidateResult,
                      CandidateEdges),
    resolve_candidates(Candidates,
                       Specs,
                       Capabilities,
                       Scope,
                       RestResolved,
                       RestRejected,
                       RestEdges),
    append(CandidateEdges, RestEdges, Edges),
    (   CandidateResult = ok(Entries)
    ->  append(Entries, RestResolved, Resolved),
        Rejected = RestRejected
    ;   CandidateResult = error(Reason)
    ->  Resolved = RestResolved,
        Rejected = [rejected_unit{unit:Candidate.unit,
                                  reasons:[Reason]}|RestRejected]
    ).

resolve_candidate(Candidate,
                  Specs,
                  Capabilities,
                  Scope,
                  Outcome,
                  Edges) :-
    resolve_unit(Candidate.unit,
                 Candidate.unit,
                 Candidate.score,
                 Candidate.reasons,
                 Specs,
                 Capabilities,
                 Scope,
                 [],
                 Outcome,
                 Edges).

resolve_unit(Unit,
             Root,
             Score,
             Reasons,
             Specs,
             Capabilities,
             Scope,
             Visited,
             Outcome,
             Edges) :-
    (   memberchk(Unit, Visited)
    ->  Outcome = ok([]),
        Edges = []
    ;   lookup_spec(Unit, Specs, Spec)
    ->  unit_dependency_eligibility(Spec,
                                    Capabilities,
                                    Scope,
                                    Eligibility),
        (   Eligibility = error(Reason)
        ->  Outcome = error(Reason),
            Edges = []
        ;   resolve_requirements(Spec.requires,
                                 Unit,
                                 Root,
                                 Score,
                                 Specs,
                                 Capabilities,
                                 Scope,
                                 [Unit|Visited],
                                 RequirementsOutcome,
                                 RequirementEdges),
            dependency_resolution_result(RequirementsOutcome,
                                         Spec,
                                         Root,
                                         Score,
                                         Reasons,
                                         Outcome),
            Edges = RequirementEdges
        )
    ;   Outcome = error(missing_dependency(Unit)),
        Edges = []
    ).

unit_dependency_eligibility(Spec, _, _, error(dependency_unavailable(Spec.unit))) :-
    Spec.available \== true,
    !.
unit_dependency_eligibility(Spec,
                            Capabilities,
                            _,
                            error(dependency_capability_denied(Spec.unit,
                                                               Spec.requires_capability))) :-
    \+ capability_eligible(Spec, Capabilities),
    !.
unit_dependency_eligibility(Spec,
                            _,
                            Scope,
                            error(dependency_scope_denied(Spec.unit))) :-
    Spec.provider_visible == true,
    \+ scope_allows(Scope, Spec),
    !.
unit_dependency_eligibility(_, _, _, ok).

resolve_requirements([], _, _, _, _, _, _, _, ok([]), []).
resolve_requirements([Required|Requireds],
                     Parent,
                     Root,
                     Score,
                     Specs,
                     Capabilities,
                     Scope,
                     Visited,
                     Outcome,
                     Edges) :-
    resolve_unit(Required,
                 Root,
                 Score,
                 [dependency_of(Parent)],
                 Specs,
                 Capabilities,
                 Scope,
                 Visited,
                 RequiredOutcome,
                 RequiredEdges),
    (   RequiredOutcome = error(Reason)
    ->  Outcome = error(Reason),
        Edges = [dependency(Parent, Required)|RequiredEdges]
    ;   RequiredOutcome = ok(RequiredEntries),
        resolve_requirements(Requireds,
                             Parent,
                             Root,
                             Score,
                             Specs,
                             Capabilities,
                             Scope,
                             Visited,
                             RestOutcome,
                             RestEdges),
        (   RestOutcome = error(RestReason)
        ->  Outcome = error(RestReason)
        ;   RestOutcome = ok(RestEntries),
            append(RequiredEntries, RestEntries, Entries),
            Outcome = ok(Entries)
        ),
        append([dependency(Parent, Required)|RequiredEdges],
               RestEdges,
               Edges)
    ).

dependency_resolution_result(error(Reason), _, _, _, _, error(Reason)) :- !.
dependency_resolution_result(ok(DependencyEntries),
                             Spec,
                             Root,
                             Score,
                             Reasons,
                             ok([Entry|DependencyEntries])) :-
    Entry = resolved_unit{unit:Spec.unit,
                          root:Root,
                          score:Score,
                          priority:Spec.priority,
                          reasons:Reasons,
                          spec:Spec}.

add_suggestions(Entries,
                Specs,
                Capabilities,
                Scope,
                Suggested,
                Edges) :-
    findall(Suggestion-Parent-Score,
            ( member(Entry, Entries),
              member(Suggestion, Entry.spec.suggests),
              Parent = Entry.unit,
              Score is max(1, Entry.score//4) ),
            Requests0),
    sort(Requests0, Requests),
    resolve_suggestions(Requests,
                        Specs,
                        Capabilities,
                        Scope,
                        Suggested0,
                        Edges0),
    dedupe_resolved(Suggested0, Suggested),
    sort(Edges0, Edges).

resolve_suggestions([], _, _, _, [], []).
resolve_suggestions([Suggestion-Parent-Score|Requests],
                    Specs,
                    Capabilities,
                    Scope,
                    Suggested,
                    Edges) :-
    resolve_unit(Suggestion,
                 Suggestion,
                 Score,
                 [suggested_by(Parent)],
                 Specs,
                 Capabilities,
                 Scope,
                 [],
                 SuggestionOutcome,
                 SuggestionEdges),
    resolve_suggestions(Requests,
                        Specs,
                        Capabilities,
                        Scope,
                        RestSuggested,
                        RestEdges),
    append([suggestion(Parent, Suggestion)|SuggestionEdges],
           RestEdges,
           Edges),
    (   SuggestionOutcome = ok(SuggestionEntries)
    ->  append(SuggestionEntries, RestSuggested, Suggested)
    ;   Suggested = RestSuggested
    ).

lookup_spec(Unit, Specs, Spec) :-
    member(Spec, Specs),
    Spec.unit == Unit,
    !.

dedupe_resolved(Entries, Deduped) :-
    predsort(compare_resolved, Entries, Sorted),
    dedupe_resolved_sorted(Sorted, [], Deduped0),
    reverse(Deduped0, Deduped).

compare_resolved(Order, A, B) :-
    compare_ranked(Order, A.score, A.unit, B.score, B.unit).

dedupe_resolved_sorted([], Acc, Acc).
dedupe_resolved_sorted([Entry|Entries], Acc0, Acc) :-
    (   select(Existing, Acc0, Rest),
        Existing.unit == Entry.unit
    ->  merge_resolved(Existing, Entry, Merged),
        Acc1 = [Merged|Rest]
    ;   Acc1 = [Entry|Acc0]
    ),
    dedupe_resolved_sorted(Entries, Acc1, Acc).

merge_resolved(A, B, Merged) :-
    (   A.score >= B.score
    ->  Base = A
    ;   Base = B
    ),
    append(A.reasons, B.reasons, Reasons0),
    sort(Reasons0, Reasons),
    put_dict(reasons, Base, Reasons, Merged).

apply_supersession(Entries, Specs, Selected, Rejected) :-
    findall(Entry,
            ( member(Entry, Entries),
              \+ entry_superseded(Entry, Entries, Specs, _) ),
            Selected),
    findall(rejected_unit{unit:Entry.unit,
                          reasons:[superseded_by(Superseder)]},
            ( member(Entry, Entries),
              entry_superseded(Entry, Entries, Specs, Superseder) ),
            Rejected).

entry_superseded(Entry, Entries, Specs, Superseder) :-
    member(Other, Entries),
    Other.unit \== Entry.unit,
    lookup_spec(Other.unit, Specs, OtherSpec),
    memberchk(Entry.unit, OtherSpec.supersedes),
    Superseder = Other.unit,
    !.

apply_conflicts(Entries, Specs, Selected, Rejected) :-
    predsort(compare_resolved, Entries, Ranked),
    apply_conflicts_ranked(Ranked, Specs, [], SelectedRev, [], RejectedRev),
    reverse(SelectedRev, Selected0),
    predsort(compare_resolved, Selected0, Selected),
    reverse(RejectedRev, Rejected).

apply_conflicts_ranked([], _, Selected, Selected, Rejected, Rejected).
apply_conflicts_ranked([Entry|Entries],
                       Specs,
                       Selected0,
                       Selected,
                       Rejected0,
                       Rejected) :-
    (   conflicting_selected(Entry, Selected0, Specs, Other)
    ->  Selected1 = Selected0,
        Rejected1 = [rejected_unit{unit:Entry.unit,
                                   reasons:[conflict_with(Other.unit)]}
                     |Rejected0]
    ;   Selected1 = [Entry|Selected0],
        Rejected1 = Rejected0
    ),
    apply_conflicts_ranked(Entries,
                           Specs,
                           Selected1,
                           Selected,
                           Rejected1,
                           Rejected).

conflicting_selected(Entry, Selected, Specs, Other) :-
    member(Other, Selected),
    lookup_spec(Entry.unit, Specs, EntrySpec),
    lookup_spec(Other.unit, Specs, OtherSpec),
    ( memberchk(Other.unit, EntrySpec.conflicts)
    ; memberchk(Entry.unit, OtherSpec.conflicts)
    ),
    !.

/* -------------------------------------------------------------------------
 * Context representations and token accounting
 * ---------------------------------------------------------------------- */

build_context_units([], _, []).
build_context_units([Entry|Entries], Options, Units) :-
    (   Entry.spec.provider_visible == true
    ->  context_unit_for_entry(Entry, Options, Unit),
        Units = [Unit|Rest]
    ;   Units = Rest
    ),
    build_context_units(Entries, Options, Rest).

context_unit_for_entry(Entry, Options, Unit) :-
    Spec = Entry.spec,
    prompt_representations(Spec, Representations0),
    maplist(context_variant_for_representation(Entry, Options),
            Representations0,
            Variants),
    unit_context_id(Spec.unit, Id),
    Unit = context_unit{id:Id,
                        section:prompt_compiler,
                        mandatory:Spec.mandatory_context,
                        variants:Variants}.

prompt_representations(Spec, Representations) :-
    Spec.representations \== [],
    !,
    Representations = Spec.representations.
prompt_representations(Spec,
                       [prompt_representation{kind:full,
                                              text:Text,
                                              utility:Utility}]) :-
    default_representation_text(Spec, Text),
    Utility is 1000000+Spec.priority.

default_representation_text(Spec, Text) :-
    (   (Spec.kind == tool ; Spec.kind == mcp_tool),
        Spec.schema \== none
    ->  safe_term_text(Spec.schema, SchemaText),
        format(string(Text),
               "Active tool schema for ~q: ~s",
               [Spec.unit, SchemaText])
    ;   Spec.content \== none
    ->  Text = Spec.content
    ;   format(string(Text),
               "Active capability ~q (~w): ~s",
               [Spec.unit, Spec.category, Spec.description])
    ).

context_variant_for_representation(Entry,
                                   Options,
                                   Representation,
                                   Variant) :-
    option(token_options(TokenOptions), Options, []),
    require_options(TokenOptions),
    rlm_context_budget:token_count_text(Representation.text,
                                        TokenOptions,
                                        TokenOutcome),
    require_budget_outcome(TokenOutcome, TokenCount),
    Utility is Representation.utility+Entry.score,
    Value = prompt_context_value{text:Representation.text,
                                 unit:Entry.unit,
                                 kind:Entry.spec.kind,
                                 representation:Representation.kind},
    Variant = context_variant{kind:Representation.kind,
                              tokens:TokenCount.tokens,
                              utility:Utility,
                              value:Value}.

unit_context_id(Unit, Id) :-
    safe_term_text(Unit, Text),
    crypto_data_hash(Text, Hash, [algorithm(sha256)]),
    sub_atom(Hash, 0, 16, _, Short),
    atom_concat(prompt_unit_, Short, Id).

active_units_from_pack(ContextPack, Active) :-
    findall(Unit,
            ( member(Selection, ContextPack.selected),
              is_dict(Selection.value),
              get_dict(unit, Selection.value, Unit) ),
            Active0),
    sort(Active0, Active).

selected_tool_schemas(Entries, Schemas) :-
    findall(Schema,
            ( member(Entry, Entries),
              (Entry.spec.kind == tool ; Entry.spec.kind == mcp_tool),
              Entry.spec.schema \== none,
              Schema = Entry.spec.schema ),
            Schemas0),
    sort(Schemas0, Schemas).

prompt_compiler_context_units(Compiled, Units) :-
    require_compiled_context(Compiled),
    Units = Compiled.context_units.

prompt_compiler_tool_schemas(Compiled, Schemas) :-
    require_compiled_context(Compiled),
    Schemas = Compiled.tool_schemas.

/* -------------------------------------------------------------------------
 * Explainability and rendering
 * ---------------------------------------------------------------------- */

prompt_explain(Compiled, Unit, Outcome) :-
    catch(( require_compiled_context(Compiled),
            explain_unit(Compiled, Unit, Explanation),
            Outcome = ok(Explanation)
          ),
          Exception,
          compiler_exception(explain, Exception, Outcome)).

explain_unit(Compiled, Unit, Explanation) :-
    (   member(Selected, Compiled.selected),
        Selected.unit == Unit
    ->  selected_state(Compiled, Unit, State),
        Explanation = prompt_explanation{unit:Unit,
                                         state:State,
                                         reasons:Selected.reasons,
                                         capability_authority:runtime_recheck_required}
    ;   member(Rejected, Compiled.rejected),
        Rejected.unit == Unit
    ->  Explanation = prompt_explanation{unit:Unit,
                                         state:rejected,
                                         reasons:Rejected.reasons,
                                         capability_authority:not_granted}
    ;   Explanation = prompt_explanation{unit:Unit,
                                         state:hidden,
                                         reasons:[no_matching_evidence],
                                         capability_authority:not_granted}
    ).

selected_state(Compiled, Unit, active) :-
    memberchk(Unit, Compiled.active_units),
    !.
selected_state(Compiled, _, selected_pending_pack) :-
    Compiled.context_pack == none,
    !.
selected_state(_, _, selected_not_visible).

prompt_render(Compiled, Provider, Outcome) :-
    catch(( require_compiled_context(Compiled),
            compiled_render_selections(Compiled, Selections),
            maplist(selection_text, Selections, Texts),
            atomics_to_string(Texts, "\n", Text),
            Outcome = ok(prompt_render{provider:Provider,
                                       text:Text,
                                       tool_schemas:Compiled.tool_schemas,
                                       active_units:Compiled.active_units,
                                       fingerprint:Compiled.fingerprint})
          ),
          Exception,
          compiler_exception(render, Exception, Outcome)).

compiled_render_selections(Compiled, Selections) :-
    (   Compiled.context_pack == none
    ->  Selections = []
    ;   Selections = Compiled.context_pack.selected
    ).

selection_text(Selection, Text) :-
    (   is_dict(Selection.value),
        get_dict(text, Selection.value, Text0)
    ->  normalize_small_text(Text0, Text)
    ;   safe_term_text(Selection.value, Text)
    ).

/* -------------------------------------------------------------------------
 * Public IR helpers
 * ---------------------------------------------------------------------- */

candidate_public(Candidates, Public) :-
    maplist(candidate_public_one, Candidates, Public).

candidate_public_one(Candidate,
                     candidate{unit:Candidate.unit,
                               score:Candidate.score,
                               reasons:Candidate.reasons}).

selected_public(Entries, Public) :-
    maplist(selected_public_one, Entries, Public).

selected_public_one(Entry,
                    selected_unit{unit:Entry.unit,
                                  score:Entry.score,
                                  reasons:Entry.reasons}).

selected_unit_terms(Entries, Units) :-
    findall(Unit, (member(Entry, Entries), Unit = Entry.unit), Units0),
    sort(Units0, Units).

grouped_selected_units(Entries,
                       groups{instructions:Instructions,
                              skills:Skills,
                              tools:Tools,
                              mcp_servers:MCPServers,
                              mcp_tools:MCPTools,
                              mcp_prompts:MCPPrompts,
                              resources:Resources}) :-
    units_of_kind(Entries, instruction, Instructions),
    units_of_kind(Entries, skill, Skills),
    units_of_kind(Entries, tool, Tools),
    units_of_kind(Entries, mcp_server, MCPServers),
    units_of_kind(Entries, mcp_tool, MCPTools),
    units_of_kind(Entries, mcp_prompt, MCPPrompts),
    units_of_kind(Entries, resource, Resources).

units_of_kind(Entries, Kind, Units) :-
    findall(Unit,
            ( member(Entry, Entries),
              Entry.spec.kind == Kind,
              Unit = Entry.unit ),
            Units0),
    sort(Units0, Units).

compilation_reasons(Selected, Rejected, Reasons) :-
    findall(selected(Unit, because(Why)),
            ( member(Entry, Selected),
              Unit = Entry.unit,
              Why = Entry.reasons ),
            SelectedReasons),
    findall(rejected(Unit, because(Why)),
            ( member(Entry, Rejected),
              Unit = Rejected.unit,
              Why = Rejected.reasons ),
            RejectedReasons),
    append(SelectedReasons, RejectedReasons, Reasons).

sort_rejections(Rejected0, Rejected) :-
    predsort(compare_rejection, Rejected0, Rejected).

compare_rejection(Order, A, B) :-
    compare_unit(Order, A.unit, B.unit).

/* -------------------------------------------------------------------------
 * Unit normalization and sanitization
 * ---------------------------------------------------------------------- */

normalize_unit_spec(Spec0, Spec) :-
    (   is_dict(Spec0), get_dict(unit, Spec0, Unit0)
    ->  normalize_unit_identity(Unit0, Unit),
        unit_kind(Unit, ExpectedKind),
        dict_default(Spec0, kind, ExpectedKind, Kind0),
        normalize_name(Kind0, Kind),
        require_matching_kind(ExpectedKind, Kind, Unit),
        unit_default_name(Unit, DefaultName),
        dict_default(Spec0, name, DefaultName, Name0),
        normalize_name(Name0, Name),
        dict_default(Spec0, category, Kind, Category0),
        normalize_name(Category0, Category),
        dict_default(Spec0, description, "", Description0),
        bounded_description(Description0, Description),
        dict_default(Spec0, available, true, Available),
        require_boolean(Available, available),
        dict_default(Spec0, aliases, [], Aliases0),
        normalize_aliases(Aliases0, Aliases),
        dict_default(Spec0, triggers, [], Triggers0),
        normalize_triggers(Triggers0, Triggers),
        normalize_unit_list_field(Spec0, requires, Requires),
        normalize_unit_list_field(Spec0, suggests, Suggests),
        normalize_unit_list_field(Spec0, conflicts, Conflicts),
        normalize_unit_list_field(Spec0, supersedes, Supersedes),
        dict_default(Spec0, requires_capability, none, Capability),
        require_ground(Capability, requires_capability),
        dict_default(Spec0, priority, 100, Priority),
        require_nonnegative_integer(Priority, priority),
        default_provider_visible(Kind, DefaultVisible),
        dict_default(Spec0, provider_visible, DefaultVisible, ProviderVisible),
        require_boolean(ProviderVisible, provider_visible),
        dict_default(Spec0, mandatory_context, true, MandatoryContext),
        require_boolean(MandatoryContext, mandatory_context),
        dict_default(Spec0, schema, none, Schema0),
        normalize_schema(Kind, Schema0, Schema),
        dict_default(Spec0, content, none, Content0),
        normalize_optional_content(Content0, Content),
        dict_default(Spec0, representations, [], Reps0),
        normalize_representations(Reps0, Representations),
        dict_default(Spec0, provenance, "host", Provenance0),
        safe_bounded_provenance(Provenance0, Provenance),
        Spec = prompt_unit{unit:Unit,
                           name:Name,
                           kind:Kind,
                           category:Category,
                           description:Description,
                           available:Available,
                           aliases:Aliases,
                           triggers:Triggers,
                           requires:Requires,
                           suggests:Suggests,
                           conflicts:Conflicts,
                           supersedes:Supersedes,
                           requires_capability:Capability,
                           priority:Priority,
                           provider_visible:ProviderVisible,
                           mandatory_context:MandatoryContext,
                           schema:Schema,
                           content:Content,
                           representations:Representations,
                           provenance:Provenance}
    ;   throw(prompt_compiler_fault(invalid_unit_spec(Spec0)))
    ).

require_matching_kind(Kind, Kind, _) :- !.
require_matching_kind(Expected, Actual, Unit) :-
    throw(prompt_compiler_fault(unit_kind_mismatch(Unit,
                                                  Expected,
                                                  Actual))).

normalize_unit_identity(Unit, Unit) :-
    ground(Unit),
    unit_kind(Unit, _),
    !.
normalize_unit_identity(Unit, _) :-
    throw(prompt_compiler_fault(invalid_unit_identity(Unit))).

unit_kind(skill(Name), skill) :- valid_unit_name(Name).
unit_kind(tool(Name), tool) :- valid_unit_name(Name).
unit_kind(mcp_server(Name), mcp_server) :- valid_unit_name(Name).
unit_kind(mcp_tool(Server, Name), mcp_tool) :-
    valid_unit_name(Server), valid_unit_name(Name).
unit_kind(mcp_prompt(Server, Name), mcp_prompt) :-
    valid_unit_name(Server), valid_unit_name(Name).
unit_kind(resource(Name), resource) :- valid_unit_name(Name).
unit_kind(instruction(Name), instruction) :- valid_unit_name(Name).

valid_unit_name(Name) :- atom(Name), !.
valid_unit_name(Name) :- string(Name), Name \== "".

unit_default_name(skill(Name), Atom) :- normalize_name(Name, Atom).
unit_default_name(tool(Name), Atom) :- normalize_name(Name, Atom).
unit_default_name(mcp_server(Name), Atom) :- normalize_name(Name, Atom).
unit_default_name(mcp_tool(_, Name), Atom) :- normalize_name(Name, Atom).
unit_default_name(mcp_prompt(_, Name), Atom) :- normalize_name(Name, Atom).
unit_default_name(resource(Name), Atom) :- normalize_name(Name, Atom).
unit_default_name(instruction(Name), Atom) :- normalize_name(Name, Atom).

default_provider_visible(mcp_server, false) :- !.
default_provider_visible(_, true).

normalize_unit_list_field(Dict, Key, Units) :-
    dict_default(Dict, Key, [], Units0),
    require_list(Units0, Key),
    maplist(normalize_unit_identity, Units0, Units1),
    sort(Units1, Units).

normalize_aliases(Aliases0, Aliases) :-
    require_list(Aliases0, aliases),
    length(Aliases0, Count),
    (   Count =< 32
    ->  true
    ;   throw(prompt_compiler_fault(too_many_aliases(Count)))
    ),
    maplist(normalize_alias, Aliases0, Aliases1),
    sort(Aliases1, Aliases).

normalize_alias(Alias0, Alias) :-
    normalize_small_text(Alias0, Alias),
    string_length(Alias, Length),
    (   Length =< 128
    ->  true
    ;   throw(prompt_compiler_fault(alias_too_large(Length)))
    ).

normalize_triggers(Triggers0, Triggers) :-
    require_list(Triggers0, triggers),
    maplist(normalize_trigger, Triggers0, Triggers1),
    sort(Triggers1, Triggers).

normalize_trigger(trigger(Signal, Weight), trigger(Signal, Weight)) :-
    ground(Signal),
    integer(Weight),
    Weight >= 0,
    Weight =< 100000,
    !.
normalize_trigger(Trigger, _) :-
    throw(prompt_compiler_fault(invalid_trigger(Trigger))).

normalize_schema(_, none, none) :- !.
normalize_schema(tool, Schema0, Schema) :-
    !,
    sanitize_tool_schema(Schema0, Schema).
normalize_schema(mcp_tool, Schema0, Schema) :-
    !,
    sanitize_tool_schema(Schema0, Schema).
normalize_schema(_, _, _) :-
    throw(prompt_compiler_fault(schema_only_valid_for_tools)).

sanitize_tool_schema(Schema0, Schema) :-
    (   is_dict(Schema0),
        get_dict(name, Schema0, Name0),
        get_dict(description, Schema0, Description0),
        get_dict(capability, Schema0, Capability),
        get_dict(effect, Schema0, Effect),
        get_dict(arguments, Schema0, Arguments0),
        get_dict(result, Schema0, Result0),
        get_dict(limits, Schema0, Limits0)
    ->  normalize_name(Name0, Name),
        bounded_description(Description0, Description),
        require_ground(Capability, schema_capability),
        require_ground(Effect, schema_effect),
        closed_schema_value(Arguments0, schema_arguments, Arguments),
        closed_schema_value(Result0, schema_result, Result),
        closed_schema_value(Limits0, schema_limits, Limits),
        Schema = tool_schema{name:Name,
                             description:Description,
                             capability:Capability,
                             effect:Effect,
                             arguments:Arguments,
                             result:Result,
                             limits:Limits}
    ;   throw(prompt_compiler_fault(invalid_tool_schema(Schema0)))
    ).

closed_schema_value(Value0, Field, Value) :-
    catch(rlm_closed_data:closed_data_normalize(Value0, Value),
          rlm_closed_data_fault(Reason),
          throw(prompt_compiler_fault(closed_data(Field, Reason)))).

normalize_optional_content(none, none) :- !.
normalize_optional_content(Content0, Content) :-
    bounded_content(Content0, Content).

normalize_representations(Reps0, Representations) :-
    require_list(Reps0, representations),
    maplist(normalize_representation, Reps0, Reps),
    sort(Reps, Representations).

normalize_representation(prompt_representation{kind:Kind0,
                                               text:Text0,
                                               utility:Utility},
                         prompt_representation{kind:Kind,
                                               text:Text,
                                               utility:Utility}) :-
    !,
    normalize_name(Kind0, Kind),
    bounded_content(Text0, Text),
    require_nonnegative_integer(Utility, representation_utility).
normalize_representation(representation(Kind0, Text0, Utility),
                         prompt_representation{kind:Kind,
                                               text:Text,
                                               utility:Utility}) :-
    !,
    normalize_name(Kind0, Kind),
    bounded_content(Text0, Text),
    require_nonnegative_integer(Utility, representation_utility).
normalize_representation(Representation, _) :-
    throw(prompt_compiler_fault(invalid_representation(Representation))).

bounded_description(Text0, Text) :-
    normalize_small_text(Text0, Text),
    string_length(Text, Length),
    (   Length =< 2048
    ->  true
    ;   throw(prompt_compiler_fault(description_too_large(Length)))
    ).

bounded_content(Text0, Text) :-
    normalize_small_text(Text0, Text),
    string_length(Text, Length),
    (   Length =< 32768
    ->  true
    ;   throw(prompt_compiler_fault(content_too_large(Length)))
    ).

safe_bounded_provenance(Value, Text) :-
    safe_term_text(Value, Text0),
    string_length(Text0, Length),
    (   Length =< 512
    ->  Text = Text0
    ;   sub_string(Text0, 0, 512, _, Text)
    ).

/* -------------------------------------------------------------------------
 * Catalog snapshots and fingerprints
 * ---------------------------------------------------------------------- */

require_catalog(prompt_catalog(Id), Id) :-
    atom(Id),
    prompt_catalog_state(Id, _),
    !.
require_catalog(Catalog, _) :-
    throw(prompt_compiler_fault(unknown_catalog(Catalog))).

catalog_snapshot(Id, Revision, Specs) :-
    with_mutex(rlm_prompt_catalog,
               ( catalog_revision(Id, Revision),
                 findall(Spec,
                         prompt_catalog_unit(Id, _, Spec),
                         Specs0)
               )),
    predsort(compare_spec, Specs0, Specs).

compare_spec(Order, A, B) :- compare_unit(Order, A.unit, B.unit).

catalog_revision(Id, Revision) :-
    (   prompt_catalog_state(Id, Revision)
    ->  true
    ;   throw(prompt_compiler_fault(unknown_catalog(prompt_catalog(Id))))
    ).

bump_catalog_revision(Id, Revision) :-
    retract(prompt_catalog_state(Id, Previous)),
    Revision is Previous+1,
    assertz(prompt_catalog_state(Id, Revision)).

catalog_fingerprint(Specs, Fingerprint) :-
    fingerprint_term(Specs, Fingerprint).

material_fingerprint(CatalogFingerprint,
                     Input,
                     Capabilities,
                     Scope,
                     Mode,
                     ContextUnits,
                     Options,
                     Fingerprint) :-
    option(policy(Policy), Options, []),
    option(candidate_limit(CandidateLimit), Options, 64),
    Material = prompt_material{catalog:CatalogFingerprint,
                               input:Input,
                               capabilities:Capabilities,
                               discovery_scope:Scope,
                               mode:Mode,
                               candidate_limit:CandidateLimit,
                               policy:Policy,
                               context_units:ContextUnits},
    fingerprint_term(Material, Fingerprint).

fingerprint_term(Term, Fingerprint) :-
    term_string(Term,
                Text,
                [ quoted(true),
                  numbervars(true),
                  ignore_ops(true)
                ]),
    crypto_data_hash(Text, Fingerprint, [algorithm(sha256)]).

/* -------------------------------------------------------------------------
 * Capabilities, scope and modes
 * ---------------------------------------------------------------------- */

compile_capabilities(Options, Capabilities) :-
    option(capabilities(Caps0), Options, []),
    require_list(Caps0, capabilities),
    sort(Caps0, Capabilities).

capability_eligible(Spec, _) :- Spec.requires_capability == none, !.
capability_eligible(Spec, Capabilities) :-
    memberchk(Spec.requires_capability, Capabilities).

discovery_scope(Options, Scope) :-
    option(discovery_scope(Requested0), Options, all),
    normalize_scope(Requested0, Requested),
    option(parent_discovery_scope(Parent0), Options, all),
    normalize_scope(Parent0, Parent),
    narrow_scope(Parent, Requested, Scope).

normalize_scope(all, all) :- !.
normalize_scope(Scope0, scope(Items)) :-
    is_list(Scope0),
    !,
    maplist(normalize_scope_item, Scope0, Items0),
    sort(Items0, Items).
normalize_scope(Scope, _) :-
    throw(prompt_compiler_fault(invalid_discovery_scope(Scope))).

normalize_scope_item(kind(Kind0), kind(Kind)) :-
    !,
    normalize_name(Kind0, Kind).
normalize_scope_item(category(Category0), category(Category)) :-
    !,
    normalize_name(Category0, Category).
normalize_scope_item(unit(Unit0), unit(Unit)) :-
    !,
    normalize_unit_identity(Unit0, Unit).
normalize_scope_item(Unit0, unit(Unit)) :-
    normalize_unit_identity(Unit0, Unit).

narrow_scope(all, Requested, Requested) :- !.
narrow_scope(scope(Parent), all, scope(Parent)) :- !.
narrow_scope(scope(Parent), scope(Requested), scope(Requested)) :-
    (   forall(member(Item, Requested), memberchk(Item, Parent))
    ->  true
    ;   subtract(Requested, Parent, Widening),
        throw(prompt_compiler_fault(discovery_scope_widening_denied(Widening)))
    ).

scope_allows(all, _) :- !.
scope_allows(scope(Items), Spec) :-
    ( memberchk(unit(Spec.unit), Items)
    ; memberchk(kind(Spec.kind), Items)
    ; memberchk(category(Spec.category), Items)
    ).

compile_mode(Options, all_tools) :-
    ( option(mode(all_tools), Options)
    ; option(all_tools(true), Options)
    ),
    !.
compile_mode(_, compiled).

candidate_limit(Options, Limit) :-
    option(candidate_limit(Requested), Options, 64),
    require_positive_integer(Requested, candidate_limit),
    Limit is min(Requested, 256).

search_limit(Options, Limit) :-
    option(limit(Requested), Options, 8),
    require_positive_integer(Requested, search_limit),
    Limit is min(Requested, 32).

/* -------------------------------------------------------------------------
 * Deterministic ordering / text helpers
 * ---------------------------------------------------------------------- */

compare_candidate(Order, A, B) :-
    compare_ranked(Order, A.score, A.unit, B.score, B.unit).

compare_ranked(Order, ScoreA, UnitA, ScoreB, UnitB) :-
    (   ScoreA > ScoreB
    ->  Order = (<)
    ;   ScoreA < ScoreB
    ->  Order = (>)
    ;   compare_unit(Order, UnitA, UnitB)
    ).

compare_unit(Order, A, B) :-
    safe_term_text(A, TextA),
    safe_term_text(B, TextB),
    compare(Order, TextA, TextB).

unit_short_text(Unit, Text) :-
    unit_default_name(Unit, Name),
    atom_string(Name, Text).

text_tokens(Text0, Tokens) :-
    normalize_small_text(Text0, Text),
    string_lower(Text, Lower),
    split_string(Lower,
                 " \t\n\r.,;:!?()[]{}<>/\\\"'_-=+|@#$%^&*`~",
                 " \t\n\r.,;:!?()[]{}<>/\\\"'_-=+|@#$%^&*`~",
                 Tokens0),
    exclude(=(""), Tokens0, Tokens1),
    sort(Tokens1, Tokens).

bounded_search_query(Query0, Query) :-
    normalize_small_text(Query0, Query),
    string_length(Query, Length),
    (   Length > 0, Length =< 512
    ->  true
    ;   throw(prompt_compiler_fault(invalid_search_query_length(Length)))
    ).

bounded_input_text(Text0, Text) :-
    normalize_small_text(Text0, Text),
    string_length(Text, Length),
    (   Length =< 32768
    ->  true
    ;   throw(prompt_compiler_fault(input_too_large(Length)))
    ).

normalize_small_text(Value, Text) :- string(Value), !, Text = Value.
normalize_small_text(Value, Text) :- atom(Value), !, atom_string(Value, Text).
normalize_small_text(Value, _) :-
    throw(prompt_compiler_fault(expected_text(Value))).

normalize_name(Value, Atom) :- atom(Value), !, Atom = Value.
normalize_name(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
normalize_name(Value, _) :-
    throw(prompt_compiler_fault(expected_name(Value))).

safe_term_text(Term, Text) :-
    term_string(Term,
                Text,
                [ quoted(true),
                  numbervars(true),
                  portray(false),
                  max_depth(24)
                ]).

take_first(Limit, Items, Selected, Truncated) :-
    length(Prefix, Limit),
    append(Prefix, Rest, Items),
    !,
    Selected = Prefix,
    ( Rest == [] -> Truncated = false ; Truncated = true ).
take_first(_, Items, Items, false).

/* -------------------------------------------------------------------------
 * Validation and structured errors
 * ---------------------------------------------------------------------- */

require_compiled_context(Compiled) :-
    (   is_dict(Compiled, compiled_context),
        get_dict(catalog, Compiled, _),
        get_dict(fingerprint, Compiled, _)
    ->  true
    ;   throw(prompt_compiler_fault(invalid_compiled_context(Compiled)))
    ).

require_options(Options) :- is_list(Options), !.
require_options(Options) :-
    throw(prompt_compiler_fault(expected_options(Options))).

require_list(Value, _) :- is_list(Value), !.
require_list(Value, Field) :-
    throw(prompt_compiler_fault(expected_list(Field, Value))).

require_ground(Value, _) :- ground(Value), !.
require_ground(Value, Field) :-
    throw(prompt_compiler_fault(non_ground(Field, Value))).

require_boolean(true, _) :- !.
require_boolean(false, _) :- !.
require_boolean(Value, Field) :-
    throw(prompt_compiler_fault(expected_boolean(Field, Value))).

require_positive_integer(Value, _) :- integer(Value), Value > 0, !.
require_positive_integer(Value, Field) :-
    throw(prompt_compiler_fault(expected_positive_integer(Field, Value))).

require_nonnegative_integer(Value, _) :- integer(Value), Value >= 0, !.
require_nonnegative_integer(Value, Field) :-
    throw(prompt_compiler_fault(expected_nonnegative_integer(Field, Value))).

require_compiler_outcome(ok(Value), Value) :- !.
require_compiler_outcome(error(Error), _) :-
    throw(prompt_compiler_fault(nested_error(Error))).
require_compiler_outcome(Outcome, _) :-
    throw(prompt_compiler_fault(invalid_outcome(Outcome))).

require_budget_outcome(ok(Value), Value) :- !.
require_budget_outcome(error(Error), _) :-
    throw(prompt_compiler_fault(context_budget_failed(Error))).
require_budget_outcome(Outcome, _) :-
    throw(prompt_compiler_fault(invalid_budget_outcome(Outcome))).

dict_default(Dict, Key, Default, Value) :-
    (   is_dict(Dict), get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

compiler_exception(Phase,
                   prompt_compiler_fault(Fault),
                   error(prompt_compiler_error{phase:Phase,
                                               kind:prompt_compiler_fault,
                                               detail:Fault,
                                               message:"prompt compiler rejected the operation"})) :-
    !.
compiler_exception(Phase,
                   Exception,
                   error(prompt_compiler_error{phase:Phase,
                                               kind:exception,
                                               exception:Safe,
                                               message:"prompt compiler raised an exception"})) :-
    safe_term_text(Exception, Safe).
