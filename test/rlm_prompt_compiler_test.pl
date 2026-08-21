:- begin_tests(rlm_prompt_compiler).

:- use_module('../prolog/rlm_prompt_compiler').
:- use_module('../prolog/rlm_tool').
:- use_module('support/tool_test_support').

with_catalog(Goal) :-
    setup_call_cleanup(prompt_catalog_create(Catalog),
                       call(Goal, Catalog),
                       prompt_catalog_destroy(Catalog)).

compiler_policy(Max,
                _{max_context_tokens:Max,
                  provider_context_tokens:Max,
                  reserve_output_tokens:0,
                  safety_margin_tokens:0,
                  min_recent_turns:0,
                  overflow:deny}).

git_schema(
    tool_schema{name:git_diff,
                description:"Inspect a Git pull request diff and changed source files",
                capability:tool(git_diff),
                effect:read,
                arguments:_{type:object,
                            required:[],
                            additional_properties:false,
                            properties:_{}},
                result:_{type:object,
                         required:[],
                         additional_properties:true,
                         properties:_{}},
                limits:_{time_limit:1.0,
                         max_output_bytes:4096}}).

search_schema(
    tool_schema{name:project_search,
                description:"Search source code under the active project",
                capability:tool(project_search),
                effect:read,
                arguments:_{type:object,
                            required:[query],
                            additional_properties:false,
                            properties:_{query:_{type:string}}},
                result:_{type:array,
                         items:_{type:string}},
                limits:_{time_limit:1.0,
                         max_output_bytes:4096}}).

register_unit(Catalog, Spec) :-
    prompt_catalog_register(Catalog, Spec, ok(_)).

base_tool_spec(Schema, Triggers, Spec) :-
    Spec = prompt_unit{unit:tool(Schema.name),
                       kind:tool,
                       name:Schema.name,
                       category:source_control,
                       description:Schema.description,
                       available:true,
                       aliases:[],
                       triggers:Triggers,
                       requires:[],
                       suggests:[],
                       conflicts:[],
                       supersedes:[],
                       requires_capability:Schema.capability,
                       priority:100,
                       provider_visible:true,
                       mandatory_context:true,
                       schema:Schema,
                       content:none,
                       representations:[],
                       provenance:test}.

selected_unit(Compiled, Unit) :-
    member(Selected, Compiled.selected),
    Selected.unit == Unit.

rejected_reason(Compiled, Unit, Reason) :-
    member(Rejected, Compiled.rejected),
    Rejected.unit == Unit,
    member(Reason, Rejected.reasons).

/* -------------------------------------------------------------------------
 * Activation evidence
 * ---------------------------------------------------------------------- */

test(phrase_trigger_activates_unit) :-
    with_catalog(test_phrase_trigger).

test_phrase_trigger(Catalog) :-
    git_schema(Schema),
    base_tool_spec(Schema,
                   [trigger(phrase("review pull request"), 80)],
                   Spec),
    register_unit(Catalog, Spec),
    prompt_compile(Catalog,
                   "Please review pull request 42",
                   [capabilities([tool(git_diff)])],
                   ok(Compiled)),
    assertion(selected_unit(Compiled, tool(git_diff))).

test(verb_object_evidence_accumulates) :-
    with_catalog(test_verb_object).

test_verb_object(Catalog) :-
    git_schema(Schema),
    base_tool_spec(Schema,
                   [trigger(verb(review), 30),
                    trigger(object(pull_request), 40)],
                   Spec),
    register_unit(Catalog, Spec),
    Input = prompt_input{text:"review it",
                         signals:[verb(review), object(pull_request)]},
    prompt_compile(Catalog,
                   Input,
                   [capabilities([tool(git_diff)])],
                   ok(Compiled)),
    member(Selected, Compiled.selected),
    Selected.unit == tool(git_diff),
    assertion(Selected.score >= 70).

test(explicit_selection_without_lexical_match) :-
    with_catalog(test_explicit_selection).

test_explicit_selection(Catalog) :-
    git_schema(Schema),
    base_tool_spec(Schema, [], Spec),
    register_unit(Catalog, Spec),
    prompt_compile(Catalog,
                   _{text:"unrelated request",
                     selected:[tool(git_diff)]},
                   [capabilities([tool(git_diff)])],
                   ok(Compiled)),
    assertion(selected_unit(Compiled, tool(git_diff))).

test(natural_language_negative_evidence_wins) :-
    with_catalog(test_negative_evidence).

test_negative_evidence(Catalog) :-
    git_schema(Schema),
    base_tool_spec(Schema,
                   [trigger(keyword(review), 50)],
                   Spec0),
    put_dict(aliases, Spec0, ["github"], Spec),
    register_unit(Catalog, Spec),
    prompt_compile(Catalog,
                   "review this without github",
                   [capabilities([tool(git_diff)])],
                   ok(Compiled)),
    assertion(\+ selected_unit(Compiled, tool(git_diff))),
    assertion(rejected_reason(Compiled,
                              tool(git_diff),
                              text_negation("github"))).

test(conflict_keeps_higher_scored_candidate) :-
    with_catalog(test_conflict).

test_conflict(Catalog) :-
    simple_instruction(alpha,
                       [trigger(keyword(review), 80)],
                       [instruction(beta)],
                       [],
                       Alpha),
    simple_instruction(beta,
                       [trigger(keyword(review), 20)],
                       [instruction(alpha)],
                       [],
                       Beta),
    register_unit(Catalog, Alpha),
    register_unit(Catalog, Beta),
    prompt_compile(Catalog, "review", [], ok(Compiled)),
    assertion(selected_unit(Compiled, instruction(alpha))),
    assertion(rejected_reason(Compiled,
                              instruction(beta),
                              conflict_with(instruction(alpha)))).

test(supersession_removes_superseded_unit) :-
    with_catalog(test_supersession).

test_supersession(Catalog) :-
    simple_instruction(old,
                       [trigger(keyword(build), 30)],
                       [],
                       [],
                       Old),
    simple_instruction(new,
                       [trigger(keyword(build), 40)],
                       [],
                       [instruction(old)],
                       New),
    register_unit(Catalog, Old),
    register_unit(Catalog, New),
    prompt_compile(Catalog, "build", [], ok(Compiled)),
    assertion(selected_unit(Compiled, instruction(new))),
    assertion(rejected_reason(Compiled,
                              instruction(old),
                              superseded_by(instruction(new)))).

simple_instruction(Name, Triggers, Conflicts, Supersedes, Spec) :-
    format(string(Text), "Instruction ~w", [Name]),
    Spec = prompt_unit{unit:instruction(Name),
                       kind:instruction,
                       name:Name,
                       category:instruction,
                       description:Text,
                       available:true,
                       aliases:[],
                       triggers:Triggers,
                       requires:[],
                       suggests:[],
                       conflicts:Conflicts,
                       supersedes:Supersedes,
                       requires_capability:none,
                       priority:100,
                       provider_visible:true,
                       mandatory_context:true,
                       schema:none,
                       content:Text,
                       representations:[],
                       provenance:test}.

/* -------------------------------------------------------------------------
 * Dependency closure and deactivation
 * ---------------------------------------------------------------------- */

test(transitive_dependency_closure) :-
    with_catalog(test_dependency_closure).

test_dependency_closure(Catalog) :-
    git_schema(Schema),
    base_tool_spec(Schema, [], ToolSpec),
    Skill = prompt_unit{unit:skill(review_pr),
                        kind:skill,
                        name:review_pr,
                        category:review,
                        description:"Review a pull request",
                        available:true,
                        aliases:[],
                        triggers:[trigger(verb(review), 50)],
                        requires:[tool(git_diff)],
                        suggests:[],
                        conflicts:[],
                        supersedes:[],
                        requires_capability:none,
                        priority:200,
                        provider_visible:true,
                        mandatory_context:true,
                        schema:none,
                        content:"Use the review workflow.",
                        representations:[],
                        provenance:test},
    register_unit(Catalog, ToolSpec),
    register_unit(Catalog, Skill),
    prompt_compile(Catalog,
                   _{text:"review", signals:[verb(review)]},
                   [capabilities([tool(git_diff)])],
                   ok(Compiled)),
    assertion(selected_unit(Compiled, skill(review_pr))),
    assertion(selected_unit(Compiled, tool(git_diff))).

test(missing_required_dependency_rejects_root_structurally) :-
    with_catalog(test_missing_dependency).

test_missing_dependency(Catalog) :-
    Skill = prompt_unit{unit:skill(review_pr),
                        name:review_pr,
                        description:"Review",
                        triggers:[trigger(keyword(review), 50)],
                        requires:[tool(missing)]},
    register_unit(Catalog, Skill),
    prompt_compile(Catalog, "review", [], ok(Compiled)),
    assertion(rejected_reason(Compiled,
                              skill(review_pr),
                              missing_dependency(tool(missing)))).

test(context_deactivation_does_not_unregister_runtime_tool) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        context_deactivation_body(Registry),
        tool_registry_destroy(Registry)).

context_deactivation_body(Registry) :-
    git_schema(Schema),
    tool_register(Registry,
                  Schema,
                  tool_test_support:echo_tool,
                  ok(_)),
    setup_call_cleanup(
        prompt_catalog_create(Catalog),
        ( prompt_catalog_register_tool_registry(Catalog,
                                                Registry,
                                                [],
                                                ok(_)),
          Caps = [tool(git_diff)],
          prompt_compile(Catalog, "git diff review", [capabilities(Caps)], ok(A)),
          assertion(selected_unit(A, tool(git_diff))),
          prompt_compile(Catalog, "weather tomorrow", [capabilities(Caps)], ok(B)),
          assertion(\+ selected_unit(B, tool(git_diff))),
          tool_discover(Registry, StillRegistered),
          assertion(StillRegistered = [Registered]),
          assertion(Registered.name == git_diff),
          prompt_compile(Catalog, "git diff review", [capabilities(Caps)], ok(C)),
          assertion(selected_unit(C, tool(git_diff)))
        ),
        prompt_catalog_destroy(Catalog)).

/* -------------------------------------------------------------------------
 * Authority and child narrowing
 * ---------------------------------------------------------------------- */

test(capability_denied_tool_is_rejected_not_authorized) :-
    with_catalog(test_capability_denied).

test_capability_denied(Catalog) :-
    git_schema(Schema),
    base_tool_spec(Schema,
                   [trigger(keyword(review), 50)],
                   Spec),
    register_unit(Catalog, Spec),
    prompt_compile(Catalog, "review", [], ok(Compiled)),
    assertion(\+ selected_unit(Compiled, tool(git_diff))),
    assertion(rejected_reason(Compiled,
                              tool(git_diff),
                              capability_denied(tool(git_diff)))).

test(needs_does_not_widen_capabilities) :-
    with_catalog(test_needs_no_widen).

test_needs_no_widen(Catalog) :-
    search_schema(Schema),
    base_tool_spec(Schema,
                   [trigger(need(source_search), 100)],
                   Spec),
    register_unit(Catalog, Spec),
    prompt_compile(Catalog,
                   _{text:"find it", needs:[source_search]},
                   [],
                   ok(Compiled)),
    assertion(\+ selected_unit(Compiled, tool(project_search))),
    assertion(rejected_reason(Compiled,
                              tool(project_search),
                              capability_denied(tool(project_search)))).

test(child_discovery_scope_cannot_widen) :-
    with_catalog(test_child_scope_widen).

test_child_scope_widen(Catalog) :-
    simple_instruction(a, [trigger(keyword(a), 10)], [], [], A),
    register_unit(Catalog, A),
    prompt_compile(Catalog,
                   "a",
                   [parent_discovery_scope([kind(instruction)]),
                    discovery_scope([kind(instruction), kind(tool)])],
                   error(Error)),
    assertion(Error.detail = discovery_scope_widening_denied(_)).

/* -------------------------------------------------------------------------
 * Model-visible discovery and needs(...)
 * ---------------------------------------------------------------------- */

test(bounded_search_returns_sanitized_metadata_only) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        discovery_body(Registry),
        tool_registry_destroy(Registry)).

discovery_body(Registry) :-
    git_schema(Git),
    search_schema(Search),
    tool_register(Registry, Git, tool_test_support:echo_tool, ok(_)),
    tool_register(Registry, Search, tool_test_support:echo_tool, ok(_)),
    setup_call_cleanup(
        prompt_catalog_create(Catalog),
        ( prompt_catalog_register_tool_registry(Catalog, Registry, [], ok(_)),
          prompt_catalog_search(Catalog,
                                "source code search",
                                [limit(1)],
                                ok(Result)),
          assertion(Result.limit =:= 1),
          assertion(length(Result.results, 1)),
          Result.results = [Metadata],
          assertion(Metadata.name == project_search),
          term_string(Metadata, Text),
          assertion(\+ sub_string(Text, _, _, _, "handler")),
          assertion(\+ sub_string(Text, _, _, _, "preflight")),
          assertion(\+ sub_string(Text, _, _, _, "transport"))
        ),
        prompt_catalog_destroy(Catalog)).

test(needs_recompile_exposes_eligible_matching_tool_next_step) :-
    with_catalog(test_needs_recompile).

test_needs_recompile(Catalog) :-
    search_schema(Schema),
    base_tool_spec(Schema,
                   [trigger(need(source_search), 100)],
                   Spec),
    register_unit(Catalog, Spec),
    Caps = [tool(project_search)],
    prompt_compile(Catalog,
                   "inspect the project",
                   [capabilities(Caps)],
                   ok(Before)),
    assertion(\+ selected_unit(Before, tool(project_search))),
    prompt_recompile(Before,
                     needs(source_search),
                     [capabilities(Caps)],
                     ok(After)),
    assertion(selected_unit(After, tool(project_search))).

/* -------------------------------------------------------------------------
 * MCP metadata stays declarative
 * ---------------------------------------------------------------------- */

test(mcp_dependency_closure_does_not_connect_or_install) :-
    with_catalog(test_mcp_closure).

test_mcp_closure(Catalog) :-
    Server = prompt_unit{unit:mcp_server(github),
                         name:github,
                         category:mcp,
                         description:"GitHub MCP server metadata",
                         available:true,
                         provider_visible:false,
                         requires_capability:none,
                         provenance:"cached tools/list"},
    ToolSchema = tool_schema{name:repo_search,
                             description:"Search repository source",
                             capability:network(github),
                             effect:read,
                             arguments:_{type:object,
                                         required:[query],
                                         additional_properties:false,
                                         properties:_{query:_{type:string}}},
                             result:_{type:array, items:_{type:string}},
                             limits:_{time_limit:2.0,
                                      max_output_bytes:4096}},
    Tool = prompt_unit{unit:mcp_tool(github, repo_search),
                       name:repo_search,
                       category:mcp,
                       description:"Search repository source",
                       available:true,
                       triggers:[trigger(need(source_search), 100)],
                       requires:[mcp_server(github)],
                       requires_capability:network(github),
                       schema:ToolSchema,
                       provenance:"cached tools/list"},
    register_unit(Catalog, Server),
    register_unit(Catalog, Tool),
    prompt_compile(Catalog,
                   _{text:"search", needs:[source_search]},
                   [capabilities([network(github)])],
                   ok(Compiled)),
    assertion(selected_unit(Compiled, mcp_tool(github, repo_search))),
    assertion(selected_unit(Compiled, mcp_server(github))),
    assertion(Compiled.context_units \== []).

/* -------------------------------------------------------------------------
 * Shared token-budget contract
 * ---------------------------------------------------------------------- */

test(tool_schema_is_charged_in_compiler_ledger) :-
    with_catalog(test_tool_schema_charged).

test_tool_schema_charged(Catalog) :-
    git_schema(Schema),
    base_tool_spec(Schema,
                   [trigger(keyword(review), 50)],
                   Spec),
    register_unit(Catalog, Spec),
    compiler_policy(4096, Policy),
    prompt_compile(Catalog,
                   "review",
                   [capabilities([tool(git_diff)]), policy(Policy)],
                   ok(Compiled)),
    assertion(Compiled.token_ledger.selected_context_tokens > 0),
    assertion(Compiled.context_units = [_]).

test(dropping_irrelevant_tool_changes_ledger) :-
    with_catalog(test_irrelevant_ledger).

test_irrelevant_ledger(Catalog) :-
    git_schema(Git),
    search_schema(Search),
    base_tool_spec(Git, [trigger(keyword(review), 50)], GitSpec),
    base_tool_spec(Search, [trigger(keyword(search), 50)], SearchSpec),
    register_unit(Catalog, GitSpec),
    register_unit(Catalog, SearchSpec),
    Caps = [tool(git_diff), tool(project_search)],
    compiler_policy(4096, Policy),
    prompt_compile(Catalog,
                   "review search",
                   [capabilities(Caps), policy(Policy)],
                   ok(Both)),
    prompt_compile(Catalog,
                   "review",
                   [capabilities(Caps), policy(Policy)],
                   ok(One)),
    assertion(Both.token_ledger.selected_context_tokens >
              One.token_ledger.selected_context_tokens).

test(over_budget_mandatory_tool_fails_structurally) :-
    with_catalog(test_mandatory_over_budget).

test_mandatory_over_budget(Catalog) :-
    git_schema(Schema),
    base_tool_spec(Schema,
                   [trigger(keyword(review), 50)],
                   Spec),
    register_unit(Catalog, Spec),
    compiler_policy(8, Policy),
    prompt_compile(Catalog,
                   "review",
                   [capabilities([tool(git_diff)]), policy(Policy)],
                   error(Error)),
    assertion(Error.detail = context_budget_failed(_)).

/* -------------------------------------------------------------------------
 * Determinism and scale
 * ---------------------------------------------------------------------- */

test(identical_material_inputs_have_identical_fingerprint) :-
    with_catalog(test_same_fingerprint).

test_same_fingerprint(Catalog) :-
    git_schema(Schema),
    base_tool_spec(Schema,
                   [trigger(keyword(review), 50)],
                   Spec),
    register_unit(Catalog, Spec),
    Options = [capabilities([tool(git_diff)]), pack(false)],
    prompt_compile(Catalog, "review", Options, ok(A)),
    prompt_compile(Catalog, "review", Options, ok(B)),
    assertion(A.fingerprint == B.fingerprint),
    prompt_compile(Catalog, "weather", Options, ok(C)),
    assertion(A.fingerprint \== C.fingerprint).

test(synthetic_5000_catalog_narrows_before_pack) :-
    setup_call_cleanup(
        prompt_catalog_create(Catalog),
        synthetic_scale_body(Catalog),
        prompt_catalog_destroy(Catalog)).

synthetic_scale_body(Catalog) :-
    forall(between(1, 5000, Index),
           register_synthetic(Catalog, Index)),
    prompt_compile(Catalog,
                   "needle4999",
                   [candidate_limit(32), pack(false)],
                   ok(Compiled)),
    length(Compiled.candidates, CandidateCount),
    assertion(CandidateCount =< 32),
    assertion(selected_unit(Compiled, instruction(unit4999))).

register_synthetic(Catalog, Index) :-
    format(atom(Name), 'unit~d', [Index]),
    format(string(Needle), 'needle~d', [Index]),
    Spec = prompt_unit{unit:instruction(Name),
                       name:Name,
                       category:synthetic,
                       description:Needle,
                       triggers:[],
                       priority:1,
                       content:Needle,
                       mandatory_context:false,
                       provenance:scale_fixture},
    register_unit(Catalog, Spec).

:- end_tests(rlm_prompt_compiler).
