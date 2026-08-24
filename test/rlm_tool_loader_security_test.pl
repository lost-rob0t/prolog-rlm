:- begin_tests(rlm_tool_loader_security).

:- meta_predicate with_security_registry(1).

:- use_module('../prolog/rlm_mcp_policy').
:- use_module('../prolog/rlm_mcp_server').
:- use_module('../prolog/rlm_mcp_tool_pack').
:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_tool_loader').

:- multifile rlm_mcp_server:mcp_server/2.
:- multifile rlm_mcp_policy:mcp_installer_profile/2.
:- multifile rlm_mcp_policy:mcp_stdio_profile/2.
:- multifile rlm_mcp_policy:mcp_config_value/2.

rlm_mcp_policy:mcp_installer_profile(
    loader_installer_profile,
    mcp_process_profile{executable:path(true),
                        argv_prefix:[],
                        argv_suffix:[],
                        package_format:plain,
                        cwd_roots:['/tmp'],
                        timeout:2.0,
                        max_output_bytes:4096}).

rlm_mcp_policy:mcp_stdio_profile(
    loader_stdio_profile,
    mcp_process_profile{executable:path(cat),
                        argv_prefix:[trusted_profile_argument_48],
                        argv_suffix:[],
                        package_format:plain,
                        cwd_roots:['/tmp'],
                        timeout:2.0,
                        max_output_bytes:4096}).

rlm_mcp_policy:mcp_config_value(loader_secret_key_48, "ENV_SECRET_48").

rlm_mcp_server:mcp_server(
    loader_secret_fixture,
    mcp_server_spec{
        transport:stdio(profile(loader_stdio_profile)),
        install:package(loader_installer_profile, loader_fixture, "1.0.0"),
        environment:[env('API_KEY', config_ref(loader_secret_key_48))],
        working_directory:directory('/tmp'),
        version:"secret-fixture-2",
        capabilities:[tools],
        options:[timeout(5.0)]
    }).

with_security_registry(Goal) :-
    setup_call_cleanup(tool_registry_create(Registry),
                       call(Goal, Registry),
                       ( rlm_tool_loader_forget_registry(Registry),
                         tool_registry_destroy(Registry) )).

term_does_not_contain(Term, Needle) :-
    term_string(Term, Text, [quoted(true), numbervars(true)]),
    \+ sub_string(Text, _, _, _, Needle).

test(mcp_loader_discovery_exposes_references_not_secret_values) :-
    with_security_registry(
        [Registry]>>(
            rlm_load_tools(Registry, mcp, ok(_)),
            tool_invoke(Registry,
                        [tool(mcp_servers)],
                        mcp_servers,
                        json{},
                        [],
                        ok(Execution),
                        _),
            get_dict(value, Execution, ExecutionValue),
            get_dict(servers, ExecutionValue, Servers),
            member(Server, Servers),
            get_dict(name, Server, loader_secret_fixture),
            get_dict(transport, Server, Transport),
            get_dict(kind, Transport, stdio),
            get_dict(profile, Transport, loader_stdio_profile),
            get_dict(install, Server, Install),
            get_dict(kind, Install, package),
            get_dict(profile, Install, loader_installer_profile),
            get_dict(working_directory, Server, configured),
            get_dict(configuration, Server, [Reference]),
            get_dict(target, Reference, 'API_KEY'),
            get_dict(kind, Reference, config),
            get_dict(name, Reference, loader_secret_key_48),
            assertion(term_does_not_contain(Server, "ENV_SECRET_48")),
            assertion(term_does_not_contain(Server, "/tmp")),
            assertion(term_does_not_contain(Server,
                                             "trusted_profile_argument_48"))
        )).

:- end_tests(rlm_tool_loader_security).
