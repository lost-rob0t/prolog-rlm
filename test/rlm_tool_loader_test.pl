:- begin_tests(rlm_tool_loader).

:- meta_predicate with_registry(1).

:- use_module('../prolog/rlm_authority').
:- use_module('../prolog/rlm_mcp_server').
:- use_module('../prolog/rlm_mcp_tool_pack').
:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_tool_loader').
:- use_module('support/tool_loader_library_alpha').
:- use_module('support/tool_loader_library_beta').

:- multifile rlm_tool_loader:tool_pack/2.
:- multifile rlm_tool_loader:tool_pack_manifest/2.
:- multifile rlm_mcp_server:mcp_server/2.

:- dynamic malformed_enabled/0.
:- dynamic bad_loader_enabled/0.
:- dynamic duplicate_manifest_enabled/0.
:- dynamic conflict_enabled/0.
:- dynamic conflict_calls/1.
:- dynamic lifecycle_race_gate/2.

/* Backward-compatible manifestless pack -------------------------------- */

rlm_tool_loader:tool_pack(
    legacy_fixture_pack,
    plunit_rlm_tool_loader:load_legacy_fixture_pack).

load_legacy_fixture_pack(Registry, Outcome) :-
    legacy_schema(Schema),
    tool_register(Registry,
                  Schema,
                  plunit_rlm_tool_loader:legacy_handler,
                  RegisterOutcome),
    (   RegisterOutcome = ok(_)
    ->  Outcome = ok(tool_pack{pack:legacy_fixture_pack,
                               registered:[legacy_fixture_echo]})
    ;   Outcome = RegisterOutcome
    ).

legacy_schema(
    tool_schema{
        name:legacy_fixture_echo,
        description:"legacy external tool-pack loading fixture",
        capability:tool(legacy_fixture_echo),
        effect:read,
        arguments:_{type:object,
                    required:[value],
                    additional_properties:false,
                    properties:_{value:_{type:integer}}},
        result:_{type:integer},
        limits:_{time_limit:1.0, max_output_bytes:1024}
    }).

legacy_handler(Args, Value) :-
    get_dict(value, Args, Value).

/* Conditional malformed/conflict fixtures ------------------------------ */

rlm_tool_loader:tool_pack(
    malformed_pack,
    plunit_rlm_tool_loader:noop_loader) :-
    malformed_enabled.
rlm_tool_loader:tool_pack_manifest(
    malformed_pack,
    tool_pack_manifest{library:broken_library, category:broken}) :-
    malformed_enabled.

rlm_tool_loader:tool_pack(bad_loader_pack, Loader) :-
    bad_loader_enabled,
    var(Loader).

rlm_tool_loader:tool_pack(
    duplicate_manifest_pack,
    plunit_rlm_tool_loader:noop_loader) :-
    duplicate_manifest_enabled.
rlm_tool_loader:tool_pack_manifest(
    duplicate_manifest_pack,
    tool_pack_manifest{library:duplicate_library,
                       category:duplicate_category,
                       tools:[]}) :-
    duplicate_manifest_enabled.
rlm_tool_loader:tool_pack_manifest(
    duplicate_manifest_pack,
    tool_pack_manifest{library:duplicate_library,
                       category:duplicate_category,
                       tools:[]}) :-
    duplicate_manifest_enabled.

rlm_tool_loader:tool_pack(
    conflict_alpha,
    plunit_rlm_tool_loader:conflict_alpha_loader) :-
    conflict_enabled.
rlm_tool_loader:tool_pack_manifest(
    conflict_alpha,
    tool_pack_manifest{library:conflict_library_alpha,
                       category:conflict_category,
                       tools:[tool_export{name:shared_conflict_tool,
                                          capability:tool(shared_conflict_tool),
                                          effect:read}]}) :-
    conflict_enabled.
rlm_tool_loader:tool_pack(
    conflict_beta,
    plunit_rlm_tool_loader:conflict_beta_loader) :-
    conflict_enabled.
rlm_tool_loader:tool_pack_manifest(
    conflict_beta,
    tool_pack_manifest{library:conflict_library_beta,
                       category:conflict_category,
                       tools:[tool_export{name:shared_conflict_tool,
                                          capability:tool(shared_conflict_tool),
                                          effect:write}]}) :-
    conflict_enabled.

rlm_tool_loader:tool_pack(
    lifecycle_race_pack,
    plunit_rlm_tool_loader:load_lifecycle_race_pack) :-
    lifecycle_race_gate(_, _).
rlm_tool_loader:tool_pack_manifest(
    lifecycle_race_pack,
    tool_pack_manifest{library:lifecycle_race_fixture,
                       category:lifecycle_race,
                       tools:[tool_export{name:lifecycle_race_echo,
                                          capability:tool(lifecycle_race_echo),
                                          effect:read}]}) :-
    lifecycle_race_gate(_, _).

noop_loader(_, ok(noop)).

reset_conflict_calls :-
    retractall(conflict_calls(_)),
    assertz(conflict_calls(0)).

bump_conflict_calls :-
    retract(conflict_calls(Current)),
    Next is Current+1,
    assertz(conflict_calls(Next)).

conflict_alpha_loader(_, ok(unreachable)) :-
    bump_conflict_calls.

conflict_beta_loader(_, ok(unreachable)) :-
    bump_conflict_calls.

lifecycle_race_schema(
    tool_schema{
        name:lifecycle_race_echo,
        description:"registry destroy race fixture",
        capability:tool(lifecycle_race_echo),
        effect:read,
        arguments:_{type:object,
                    required:[],
                    additional_properties:false,
                    properties:_{}},
        result:_{type:integer},
        limits:_{time_limit:1.0, max_output_bytes:1024}
    }).

lifecycle_race_handler(_, 1).

load_lifecycle_race_pack(Registry, Outcome) :-
    lifecycle_race_schema(Schema),
    tool_register(Registry,
                  Schema,
                  plunit_rlm_tool_loader:lifecycle_race_handler,
                  RegisterOutcome),
    (   RegisterOutcome = ok(_)
    ->  lifecycle_race_gate(Entered, Release),
        thread_send_message(Entered, registered),
        thread_get_message(Release, release),
        Outcome = ok(tool_pack{pack:lifecycle_race_pack,
                               registered:[lifecycle_race_echo]})
    ;   Outcome = RegisterOutcome
    ).

/* Inert MCP declaration used by the MCP category tests ----------------- */

rlm_mcp_server:mcp_server(
    loader_mcp_fixture,
    mcp_server_spec{
        transport:fixture(streamable_http,
                          plunit_rlm_tool_loader:unused_mcp_transport),
        install:none,
        version:"loader-fixture-1",
        capabilities:[tools]
    }).

unused_mcp_transport(_, _, _) :-
    throw(error(unexpected_mcp_transport_use, _)).

/* Helpers --------------------------------------------------------------- */

with_registry(Goal) :-
    setup_call_cleanup(tool_registry_create(Registry),
                       call(Goal, Registry),
                       tool_registry_destroy(Registry)).

catalog_has_callable(Catalog) :-
    sub_term(Sub, Catalog),
    nonvar(Sub),
    Sub = _:_ .

pack_status(Pack, Packs, Status) :-
    member(Entry, Packs),
    get_dict(pack, Entry, EntryPack),
    EntryPack == Pack,
    get_dict(status, Entry, Status).

schema_named(Name, Schema) :-
    get_dict(name, Schema, SchemaName),
    SchemaName == Name.

loader_state_count(Count) :-
    findall(Registry-Pack,
            rlm_tool_loader:loaded_tool_pack(Registry, Pack, _, _),
            Rows),
    length(Rows, Count).

load_then_destroy_registry :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        rlm_load_tools(Registry, filesystem, ok(_)),
        tool_registry_destroy(Registry)).

setup_lifecycle_race(Entered, Release) :-
    message_queue_create(Entered),
    message_queue_create(Release),
    assertz(lifecycle_race_gate(Entered, Release)).

cleanup_lifecycle_race(Entered, Release) :-
    retractall(lifecycle_race_gate(_, _)),
    catch(message_queue_destroy(Entered), _, true),
    catch(message_queue_destroy(Release), _, true).

/* Registry lifecycle --------------------------------------------------- */

test(destroy_reclaims_loader_idempotency_state_automatically) :-
    loader_state_count(Before),
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( rlm_load_tools(Registry, filesystem, ok(_)),
          assertion(rlm_tool_loader:loaded_tool_pack(Registry,
                                                     alpha_filesystem,
                                                     _, _)),
          tool_registry_destroy(Registry),
          assertion(\+ rlm_tool_loader:loaded_tool_pack(Registry, _, _, _)),
          loader_state_count(After),
          assertion(After =:= Before)
        ),
        ( rlm_tool_loader_forget_registry(Registry),
          tool_registry_destroy(Registry)
        )).

test(destroy_cleanup_is_scoped_to_the_destroyed_registry) :-
    tool_registry_create(RegistryA),
    tool_registry_create(RegistryB),
    setup_call_cleanup(
        true,
        ( rlm_load_tools(RegistryA, filesystem, ok(_)),
          rlm_load_tools(RegistryB, filesystem, ok(_)),
          tool_registry_destroy(RegistryA),
          assertion(\+ rlm_tool_loader:loaded_tool_pack(RegistryA, _, _, _)),
          assertion(rlm_tool_loader:loaded_tool_pack(RegistryB,
                                                     alpha_filesystem,
                                                     _, _))
        ),
        ( rlm_tool_loader_forget_registry(RegistryA),
          rlm_tool_loader_forget_registry(RegistryB),
          tool_registry_destroy(RegistryA),
          tool_registry_destroy(RegistryB)
        )).

test(repeated_registry_churn_does_not_retain_loader_state) :-
    loader_state_count(Before),
    forall(between(1, 32, _), load_then_destroy_registry),
    loader_state_count(After),
    assertion(After =:= Before).

test(destroying_registry_that_never_used_loader_remains_valid) :-
    tool_registry_create(Registry),
    tool_registry_destroy(Registry),
    tool_registry_destroy(Registry).

test(destroy_during_loader_return_cannot_resurrect_loader_state,
     [ setup(setup_lifecycle_race(Entered, Release)),
       cleanup(cleanup_lifecycle_race(Entered, Release))
     ]) :-
    tool_registry_create(Registry),
    thread_create(rlm_load_tools(Registry, lifecycle_race, _), Thread, []),
    setup_call_cleanup(
        true,
        ( thread_get_message(Entered, registered),
          tool_registry_destroy(Registry),
          thread_send_message(Release, release),
          thread_join(Thread, Status),
          assertion(Status == true),
          assertion(\+ rlm_tool_loader:loaded_tool_pack(Registry, _, _, _))
        ),
        ( catch(thread_send_message(Release, release), _, true),
          catch(thread_join(Thread, _), _, true),
          rlm_tool_loader_forget_registry(Registry),
          tool_registry_destroy(Registry)
        )).

/* Discovery ------------------------------------------------------------- */

test(pack_library_and_category_discovery_is_declarative) :-
    rlm_tool_packs(Packs),
    assertion(memberchk(alpha_filesystem, Packs)),
    assertion(memberchk(alpha_git, Packs)),
    assertion(memberchk(beta_filesystem, Packs)),
    assertion(memberchk(mcp_core, Packs)),
    rlm_tool_libraries(Libraries),
    assertion(memberchk(alpha_fixture_library, Libraries)),
    assertion(memberchk(beta_fixture_library, Libraries)),
    assertion(memberchk(prolog_rlm_mcp, Libraries)),
    rlm_tool_categories(Categories),
    assertion(memberchk(filesystem, Categories)),
    assertion(memberchk(git, Categories)),
    assertion(memberchk(mcp, Categories)).

test(model_facing_catalog_never_exposes_trusted_loader_callables) :-
    rlm_tool_catalog(Catalog),
    assertion(\+ catalog_has_callable(Catalog)),
    member(Alpha, Catalog),
    Alpha.pack == alpha_filesystem,
    assertion(Alpha.library == alpha_fixture_library),
    assertion(Alpha.category == filesystem),
    assertion(Alpha.tools = [tool_export{name:alpha_echo,
                                         capability:tool(alpha_echo),
                                         effect:read}]).

test(unknown_category_fails_closed_and_lists_valid_categories) :-
    with_registry(
        [Registry]>>(
            rlm_load_tools(Registry, definitely_missing_category, error(Error)),
            get_dict(kind, Error, unknown_tool_category),
            get_dict(valid_categories, Error, Categories),
            assertion(memberchk(filesystem, Categories)),
            assertion(memberchk(mcp, Categories))
        )).

/* Category composition and isolation ---------------------------------- */

test(two_independent_libraries_contribute_one_category) :-
    with_registry(
        [Registry]>>(
            rlm_load_tools(Registry, filesystem, ok(Result)),
            get_dict(category, Result, filesystem),
            get_dict(packs, Result, Packs),
            assertion(length(Packs, 2)),
            tool_lookup(Registry, alpha_echo, ok(_)),
            tool_lookup(Registry, beta_echo, ok(_))
        )).

test(one_library_can_advertise_multiple_categories_without_cross_loading) :-
    with_registry(
        [Registry]>>(
            rlm_load_tools(Registry, filesystem, ok(_)),
            tool_lookup(Registry, alpha_echo, ok(_)),
            tool_lookup(Registry, beta_echo, ok(_)),
            tool_lookup(Registry, alpha_git_echo, error(GitError)),
            get_dict(kind, GitError, unknown_tool)
        )).

test(repeated_category_loading_is_idempotent_and_reused) :-
    with_registry(
        [Registry]>>(
            rlm_load_tools(Registry, filesystem, ok(First)),
            get_dict(packs, First, FirstPacks),
            assertion(pack_status(alpha_filesystem, FirstPacks, loaded)),
            rlm_load_tools(Registry, filesystem, ok(Second)),
            get_dict(packs, Second, SecondPacks),
            assertion(pack_status(alpha_filesystem, SecondPacks, reused)),
            assertion(pack_status(beta_filesystem, SecondPacks, reused)),
            tool_discover(Registry, Schemas),
            include(schema_named(alpha_echo), Schemas, AlphaSchemas),
            assertion(AlphaSchemas = [_])
        )).

test(trusted_host_can_load_scoped_external_pack_instance) :-
    with_registry(
        [Registry]>>(
            Manifest = tool_pack_manifest{
                           library:agent_zero_fixture,
                           category:agent_zero,
                           tools:[tool_export{
                                      name:legacy_fixture_echo,
                                      capability:tool(legacy_fixture_echo),
                                      effect:read}]},
            Loader = plunit_rlm_tool_loader:load_legacy_fixture_pack,
            rlm_load_tool_pack_instance(Registry,
                                        agent_zero_fixture_pack,
                                        Manifest,
                                        Loader,
                                        ok(First)),
            get_dict(status, First, loaded),
            tool_lookup(Registry, legacy_fixture_echo, ok(_)),
            rlm_load_tool_pack_instance(Registry,
                                        agent_zero_fixture_pack,
                                        Manifest,
                                        Loader,
                                        ok(Second)),
            get_dict(status, Second, reused)
        )).

test(host_pack_instance_rejects_model_shaped_noncallable_loader) :-
    with_registry(
        [Registry]>>(
            Manifest = tool_pack_manifest{library:bad,
                                          category:agent_zero,
                                          tools:[]},
            rlm_load_tool_pack_instance(Registry,
                                        invalid_instance,
                                        Manifest,
                                        _{handler:"model supplied"},
                                        error(Error)),
            get_dict(kind, Error, invalid_tool_pack_operation)
        )).

test(load_all_loads_each_pack_once_and_reuses_previous_category_load) :-
    with_registry(
        [Registry]>>(
            rlm_load_tools(Registry, filesystem, ok(_)),
            rlm_load_all_tools(Registry, ok(All)),
            get_dict(packs, All, AllPacks),
            assertion(pack_status(alpha_filesystem, AllPacks, reused)),
            assertion(pack_status(beta_filesystem, AllPacks, reused)),
            assertion(pack_status(alpha_git, AllPacks, loaded)),
            assertion(pack_status(mcp_core, AllPacks, loaded)),
            assertion(pack_status(legacy_fixture_pack, AllPacks, loaded)),
            tool_lookup(Registry, alpha_git_echo, ok(_)),
            tool_lookup(Registry, mcp_servers, ok(_)),
            tool_lookup(Registry, legacy_fixture_echo, ok(_))
        )).

/* Fail-closed declarations and conflicts ------------------------------- */

test(malformed_manifest_fails_structurally,
     [setup(assertz(malformed_enabled)),
      cleanup(retractall(malformed_enabled))]) :-
    with_registry(
        [Registry]>>(
            rlm_load_tools(Registry, malformed_pack, error(Error)),
            get_dict(kind, Error, invalid_tool_pack_manifest)
        )).

test(malformed_trusted_loader_fails_structurally,
     [setup(assertz(bad_loader_enabled)),
      cleanup(retractall(bad_loader_enabled))]) :-
    with_registry(
        [Registry]>>(
            rlm_load_tools(Registry, bad_loader_pack, error(Error)),
            get_dict(kind, Error, invalid_tool_pack_operation)
        )).

test(duplicate_manifest_declaration_is_not_silently_deduplicated,
     [setup(assertz(duplicate_manifest_enabled)),
      cleanup(retractall(duplicate_manifest_enabled))]) :-
    with_registry(
        [Registry]>>(
            rlm_load_tools(Registry, duplicate_manifest_pack, error(Error)),
            get_dict(kind, Error, invalid_tool_pack_manifest),
            get_dict(cause, Error, Cause),
            get_dict(kind, Cause, duplicate_tool_pack_manifest)
        )).

test(duplicate_tool_name_conflict_fails_before_either_loader_runs,
     [setup((assertz(conflict_enabled), reset_conflict_calls)),
      cleanup((retractall(conflict_enabled), retractall(conflict_calls(_))))]) :-
    with_registry(
        [Registry]>>(
            rlm_load_tools(Registry, conflict_category, error(Error)),
            get_dict(kind, Error, tool_name_conflict),
            get_dict(tool, Error, shared_conflict_tool),
            get_dict(contributors, Error, Contributors),
            assertion(length(Contributors, 2)),
            conflict_calls(Calls),
            assertion(Calls =:= 0)
        )).

/* Loading remains separate from capability and authority -------------- */

test(loading_registers_tools_but_grants_zero_capabilities) :-
    with_registry(
        [Registry]>>(
            rlm_load_tools(Registry, filesystem, ok(_)),
            tool_invoke(Registry,
                        [],
                        alpha_echo,
                        _{value:7},
                        [],
                        error(Error),
                        Trace),
            get_dict(kind, Error, capability_denied),
            get_dict(authorization, Trace, denied)
        )).

test(explicit_capability_allows_loaded_tool) :-
    with_registry(
        [Registry]>>(
            rlm_load_tools(Registry, filesystem, ok(_)),
            tool_invoke(Registry,
                        [tool(alpha_echo)],
                        alpha_echo,
                        _{value:9},
                        [],
                        ok(Execution),
                        Trace),
            get_dict(value, Execution, 9),
            get_dict(authorization, Trace, allowed)
        )).

test(loading_does_not_change_host_authority) :-
    with_registry(
        [Registry]>>(
            rlm_set_authority(Registry, allow_session, ok(_)),
            rlm_authority(Registry, Before),
            rlm_load_tools(Registry, filesystem, ok(_)),
            rlm_authority(Registry, After),
            assertion(Before == allow_session),
            assertion(After == Before)
        )).

/* MCP category ---------------------------------------------------------- */

test(mcp_category_load_is_inert_and_capability_gated) :-
    with_registry(
        [Registry]>>(
            mcp_server_definition(loader_mcp_fixture, ok(BeforeSpec)),
            get_dict(name, BeforeSpec, loader_mcp_fixture),
            rlm_load_tools(Registry, mcp, ok(Result)),
            get_dict(category, Result, mcp),
            tool_lookup(Registry, mcp_servers, ok(_)),
            tool_lookup(Registry, mcp_server_inspect, ok(_)),
            tool_invoke(Registry,
                        [],
                        mcp_servers,
                        _{},
                        [],
                        error(Denied),
                        Trace),
            get_dict(kind, Denied, capability_denied),
            get_dict(authorization, Trace, denied),
            mcp_server_definition(loader_mcp_fixture, ok(AfterSpec)),
            assertion(AfterSpec == BeforeSpec)
        )).

test(explicit_mcp_discovery_capability_invokes_only_sanitized_discovery) :-
    with_registry(
        [Registry]>>(
            rlm_load_tools(Registry, mcp, ok(_)),
            tool_invoke(Registry,
                        [tool(mcp_servers)],
                        mcp_servers,
                        _{},
                        [],
                        ok(Execution),
                        Trace),
            get_dict(authorization, Trace, allowed),
            get_dict(value, Execution, ExecutionValue),
            get_dict(servers, ExecutionValue, Servers),
            member(Server, Servers),
            get_dict(name, Server, loader_mcp_fixture),
            get_dict(transport, Server, Transport),
            get_dict(kind, Transport, fixture),
            assertion(\+ catalog_has_callable(Server))
        )).

:- end_tests(rlm_tool_loader).
