:- begin_tests(rlm_mcp_declaration_security).

:- use_module('../prolog/rlm_authority').
:- use_module('../prolog/rlm_mcp_policy').
:- use_module('../prolog/rlm_mcp_server').
:- use_module('../prolog/rlm_mcp_tool_pack').
:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_tool_loader').

:- multifile rlm_mcp_server:mcp_server/2.
:- multifile rlm_mcp_policy:mcp_installer_profile/2.
:- multifile rlm_mcp_policy:mcp_stdio_profile/2.
:- multifile rlm_mcp_policy:mcp_config_value/2.

run_probe('/tmp/prolog_rlm_mcp_run_probe_52').
install_probe('/tmp/prolog_rlm_mcp_install_probe_52').
secret_value("MCP_SECRET_VALUE_52_DO_NOT_SURFACE").

rlm_mcp_policy:mcp_installer_profile(
    test_installer_true,
    mcp_process_profile{executable:path(true),
                        argv_prefix:[],
                        argv_suffix:[],
                        package_format:plain,
                        cwd_roots:['/tmp'],
                        timeout:2.0,
                        max_output_bytes:4096}).

rlm_mcp_policy:mcp_installer_profile(
    test_installer_probe,
    mcp_process_profile{executable:path(touch),
                        argv_prefix:['/tmp/prolog_rlm_mcp_install_probe_52'],
                        argv_suffix:[],
                        package_format:plain,
                        cwd_roots:['/tmp'],
                        timeout:2.0,
                        max_output_bytes:4096}).

rlm_mcp_policy:mcp_stdio_profile(
    test_stdio_cat,
    mcp_process_profile{executable:path(cat),
                        argv_prefix:[],
                        argv_suffix:[],
                        package_format:plain,
                        cwd_roots:['/tmp'],
                        timeout:2.0,
                        max_output_bytes:4096}).

rlm_mcp_policy:mcp_stdio_profile(
    test_stdio_probe,
    mcp_process_profile{executable:path(touch),
                        argv_prefix:['/tmp/prolog_rlm_mcp_run_probe_52'],
                        argv_suffix:[],
                        package_format:plain,
                        cwd_roots:['/tmp'],
                        timeout:2.0,
                        max_output_bytes:4096}).

rlm_mcp_policy:mcp_stdio_profile(
    test_stdio_shell,
    mcp_process_profile{executable:path(sh),
                        argv_prefix:[],
                        argv_suffix:[],
                        package_format:plain,
                        cwd_roots:['/tmp'],
                        timeout:2.0,
                        max_output_bytes:4096}).

rlm_mcp_policy:mcp_config_value(test_secret_52, Value) :-
    secret_value(Value).

rlm_mcp_server:mcp_server(
    secure_stdio_52,
    mcp_server_spec{
        transport:stdio(profile(test_stdio_cat)),
        install:package(test_installer_true, fixture_mcp, "1.0.0"),
        environment:[env('MCP_TEST_TOKEN', config_ref(test_secret_52))],
        working_directory:directory('/tmp'),
        version:"fixture-stdio-52",
        capabilities:[tools],
        options:[timeout(2.0)]
    }).

rlm_mcp_server:mcp_server(
    secure_http_52,
    mcp_server_spec{
        transport:streamable_http('https://example.invalid/mcp'),
        install:none,
        version:"fixture-http-52",
        capabilities:[tools,resources]
    }).

rlm_mcp_server:mcp_server(
    env_ref_stdio_52,
    mcp_server_spec{
        transport:stdio(profile(test_stdio_cat)),
        install:none,
        environment:[env('MCP_PARENT_PATH', env_ref('PATH'))],
        working_directory:inherit,
        version:"fixture-env-ref-52",
        capabilities:[tools]
    }).

rlm_mcp_server:mcp_server(
    missing_config_stdio_52,
    mcp_server_spec{
        transport:stdio(profile(test_stdio_probe)),
        install:none,
        environment:[env('MCP_TEST_TOKEN',
                         config_ref(definitely_missing_config_52))],
        working_directory:inherit,
        version:"fixture-missing-config-52",
        capabilities:[tools]
    }).

rlm_mcp_server:mcp_server(
    legacy_process_install_52,
    mcp_server_spec{
        transport:streamable_http('https://example.invalid/legacy-install'),
        install:process(touch,
                        ['/tmp/prolog_rlm_mcp_install_probe_52'],
                        []),
        version:"legacy-process-52",
        capabilities:[tools]
    }).

rlm_mcp_server:mcp_server(
    unallowed_installer_52,
    mcp_server_spec{
        transport:streamable_http('https://example.invalid/unallowed'),
        install:package(not_allowed_52, fixture_mcp, "1.0.0"),
        version:"unallowed-installer-52",
        capabilities:[tools]
    }).

rlm_mcp_server:mcp_server(
    injection_install_52,
    mcp_server_spec{
        transport:streamable_http('https://example.invalid/injection'),
        install:package(test_installer_probe,
                        'bad;touch-install-probe',
                        "1.0.0"),
        version:"injection-install-52",
        capabilities:[tools]
    }).

rlm_mcp_server:mcp_server(
    malformed_version_install_52,
    mcp_server_spec{
        transport:streamable_http('https://example.invalid/version'),
        install:package(test_installer_probe,
                        fixture_mcp,
                        '1.0.0;touch'),
        version:"malformed-version-52",
        capabilities:[tools]
    }).

rlm_mcp_server:mcp_server(
    raw_environment_52,
    mcp_server_spec{
        transport:stdio(profile(test_stdio_probe)),
        install:none,
        environment:[env('MCP_TEST_TOKEN', "RAW_SECRET_52")],
        working_directory:inherit,
        version:"raw-environment-52",
        capabilities:[tools]
    }).

rlm_mcp_server:mcp_server(
    legacy_stdio_52,
    mcp_server_spec{
        transport:stdio(touch, ['/tmp/prolog_rlm_mcp_run_probe_52']),
        install:none,
        version:"legacy-stdio-52",
        capabilities:[tools]
    }).

rlm_mcp_server:mcp_server(
    shell_stdio_52,
    mcp_server_spec{
        transport:stdio(profile(test_stdio_shell)),
        install:none,
        version:"shell-stdio-52",
        capabilities:[tools]
    }).

remove_marker(Path) :-
    (   exists_file(Path)
    ->  delete_file(Path)
    ;   true
    ).

markers_absent :-
    run_probe(RunProbe),
    install_probe(InstallProbe),
    \+ exists_file(RunProbe),
    \+ exists_file(InstallProbe).

reset_markers :-
    run_probe(RunProbe),
    install_probe(InstallProbe),
    remove_marker(RunProbe),
    remove_marker(InstallProbe).

with_authority(Context, Mode, Goal) :-
    setup_call_cleanup(rlm_set_authority(Context, Mode, ok(_)),
                       call(Goal),
                       catch(rlm_authority_clear(Context), _, true)).

term_does_not_contain(Term, Needle) :-
    term_string(Term, Text, [quoted(true), numbervars(true)]),
    \+ sub_string(Text, _, _, _, Needle).

test(stdio_and_non_stdio_definitions_are_inert_and_normalized,
     [setup(reset_markers), cleanup(reset_markers)]) :-
    mcp_server_definition(secure_stdio_52, ok(Stdio)),
    mcp_server_definition(secure_http_52, ok(Http)),
    assertion(Stdio.transport == stdio(profile(test_stdio_cat))),
    assertion(Stdio.install ==
              package(test_installer_true, fixture_mcp, '1.0.0')),
    assertion(Stdio.environment ==
              [env('MCP_TEST_TOKEN', config_ref(test_secret_52))]),
    assertion(Stdio.working_directory == directory('/tmp')),
    assertion(Http.transport ==
              streamable_http('https://example.invalid/mcp')),
    assertion(Http.install == none),
    assertion(markers_absent).

test(env_ref_is_first_class_declaration_metadata) :-
    mcp_server_definition(env_ref_stdio_52, ok(Spec)),
    assertion(Spec.environment ==
              [env('MCP_PARENT_PATH', env_ref('PATH'))]).

test(loader_category_remains_inert_and_capability_gated,
     [setup(reset_markers), cleanup(reset_markers)]) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( rlm_load_tools(Registry, mcp, ok(_)),
          assertion(markers_absent),
          tool_invoke(Registry,
                      [],
                      mcp_servers,
                      _{},
                      [],
                      error(Denied),
                      Trace),
          assertion(Denied.kind == capability_denied),
          assertion(Trace.authorization == denied),
          assertion(markers_absent) ),
        ( rlm_tool_loader_forget_registry(Registry),
          tool_registry_destroy(Registry) )).

test(sanitized_discovery_exposes_reference_not_resolved_secret) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( rlm_load_tools(Registry, mcp, ok(_)),
          tool_invoke(Registry,
                      [tool(mcp_servers)],
                      mcp_servers,
                      _{},
                      [],
                      ok(Execution),
                      _),
          member(Server, Execution.value.servers),
          Server.name == secure_stdio_52,
          assertion(Server.transport.profile == test_stdio_cat),
          assertion(Server.install.profile == test_installer_true),
          assertion(Server.configuration = [Reference]),
          assertion(Reference.kind == config),
          assertion(Reference.name == test_secret_52),
          secret_value(Secret),
          assertion(term_does_not_contain(Server, Secret)) ),
        ( rlm_tool_loader_forget_registry(Registry),
          tool_registry_destroy(Registry) )).

test(missing_config_fails_before_stdio_spawn_even_in_dangerous,
     [setup(reset_markers), cleanup(reset_markers)]) :-
    Context = session(mcp_missing_config_52),
    with_authority(
        Context,
        dangerous,
        ( rlm_run_mcp_server(missing_config_stdio_52,
                             [authority_context(Context)],
                             error(Error)),
          assertion(Error.kind == execution_policy_denied),
          assertion(Error.detail = missing_configuration(_)),
          assertion(markers_absent) )).

test(trusted_package_installer_executes_only_after_policy_and_authority) :-
    Context = session(mcp_install_allowed_52),
    with_authority(
        Context,
        dangerous,
        ( rlm_install_mcp_server(secure_stdio_52,
                                 [authority_context(Context)],
                                 ok(Result)),
          assertion(Result.status == installed),
          assertion(Result.process_status == exit(0)),
          assertion(Result.captured_output_bytes =:= 0),
          assertion(Result.output_limit_bytes =:= 4096) )).

test(approval_pending_state_contains_refs_not_resolved_secret) :-
    Context = session(mcp_install_pending_52),
    setup_call_cleanup(
        rlm_set_authority(Context, approve_diff, ok(_)),
        ( rlm_install_mcp_server(secure_stdio_52,
                                 [authority_context(Context)],
                                 approval_required(Pending)),
          secret_value(Secret),
          assertion(term_does_not_contain(Pending, Secret)),
          rlm_deny(Pending.id, test_cleanup, ok(_)) ),
        catch(rlm_authority_clear(Context), _, true)).

test(stdio_run_uses_trusted_profile_and_keeps_secret_out_of_handle) :-
    Context = session(mcp_stdio_run_52),
    with_authority(
        Context,
        dangerous,
        setup_call_cleanup(
            rlm_run_mcp_server(secure_stdio_52,
                               [authority_context(Context)],
                               ok(Handle)),
            ( assertion(Handle.status == running),
              assertion(Handle.spec.transport ==
                        stdio(profile(test_stdio_cat))),
              secret_value(Secret),
              assertion(term_does_not_contain(Handle, Secret)) ),
            ( rlm_stop_mcp_server(Handle, ok(Stopped)),
              assertion(Stopped.status == stopped) ))).

test(non_stdio_lifecycle_constructs_handle_without_network_io) :-
    setup_call_cleanup(
        rlm_run_mcp_server(secure_http_52, ok(Handle)),
        ( assertion(Handle.status == running),
          assertion(Handle.transport.kind == streamable_http) ),
        rlm_stop_mcp_server(Handle, ok(_))).

test(unallowlisted_installer_fails_before_authority_and_spawn,
     [setup(reset_markers), cleanup(reset_markers)]) :-
    Context = session(mcp_unallowed_52),
    with_authority(
        Context,
        dangerous,
        ( rlm_install_mcp_server(unallowed_installer_52,
                                 [authority_context(Context)],
                                 error(Error)),
          assertion(Error.phase == definition),
          assertion(Error.kind == execution_policy_denied),
          assertion(Error.detail ==
                    unallowed_execution_profile(installer,
                                                not_allowed_52)),
          assertion(markers_absent) )).

test(package_name_injection_fails_before_trusted_profile_spawn,
     [setup(reset_markers), cleanup(reset_markers)]) :-
    Context = session(mcp_package_injection_52),
    with_authority(
        Context,
        dangerous,
        ( rlm_install_mcp_server(injection_install_52,
                                 [authority_context(Context)],
                                 error(Error)),
          assertion(Error.phase == definition),
          assertion(Error.kind == execution_policy_denied),
          assertion(Error.detail == invalid_package_name),
          assertion(term_does_not_contain(Error, "bad;touch-install-probe")),
          assertion(markers_absent) )).

test(malformed_package_version_fails_before_spawn,
     [setup(reset_markers), cleanup(reset_markers)]) :-
    Context = session(mcp_version_injection_52),
    with_authority(
        Context,
        dangerous,
        ( rlm_install_mcp_server(malformed_version_install_52,
                                 [authority_context(Context)],
                                 error(Error)),
          assertion(Error.phase == definition),
          assertion(Error.kind == execution_policy_denied),
          assertion(Error.detail == invalid_package_version),
          assertion(term_does_not_contain(Error, "1.0.0;touch")),
          assertion(markers_absent) )).

test(raw_environment_values_are_not_a_valid_reference_and_are_redacted) :-
    mcp_server_definition(raw_environment_52, error(Error)),
    assertion(Error.phase == definition),
    assertion(Error.kind == execution_policy_denied),
    assertion(Error.detail == invalid_config_reference),
    assertion(term_does_not_contain(Error, "RAW_SECRET_52")).

test(legacy_direct_process_installer_is_rejected_without_spawn,
     [setup(reset_markers), cleanup(reset_markers)]) :-
    mcp_server_definition(legacy_process_install_52, error(Error)),
    assertion(Error.kind == execution_policy_denied),
    assertion(Error.detail == invalid_install_recipe),
    assertion(markers_absent).

test(legacy_direct_stdio_exec_argv_is_rejected_without_spawn,
     [setup(reset_markers), cleanup(reset_markers)]) :-
    mcp_server_definition(legacy_stdio_52, error(Error)),
    assertion(Error.kind == invalid_lifecycle_operation),
    assertion(Error.detail == invalid_transport_spec),
    assertion(markers_absent).

test(shell_execution_profile_is_hard_rejected) :-
    mcp_server_definition(shell_stdio_52, error(Error)),
    assertion(Error.kind == execution_policy_denied),
    assertion(Error.detail == invalid_profile_executable).

test(model_environment_option_is_not_interpreted_as_host_configuration) :-
    Context = session(mcp_raw_call_env_52),
    with_authority(
        Context,
        dangerous,
        ( rlm_install_mcp_server(secure_stdio_52,
                                 [authority_context(Context),
                                  env(['MCP_TEST_TOKEN'="INJECTED"])],
                                 error(Error)),
          assertion(Error.kind == invalid_lifecycle_operation),
          assertion(Error.detail == disallowed_install_call_option) )).

:- end_tests(rlm_mcp_declaration_security).
