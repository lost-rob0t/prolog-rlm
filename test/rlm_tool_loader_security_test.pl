:- begin_tests(rlm_tool_loader_security).

:- use_module('../prolog/rlm_mcp_server').
:- use_module('../prolog/rlm_mcp_tool_pack').
:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_tool_loader').

:- multifile rlm_mcp_server:mcp_server/2.

rlm_mcp_server:mcp_server(
    loader_secret_fixture,
    mcp_server_spec{
        transport:stdio("node",
                        ["server.js", "--token", "TRANSPORT_SECRET_48"]),
        install:process("npm",
                        ["install", "--token", "INSTALL_SECRET_48"],
                        [cwd("/tmp/secret-path-48"),
                         env(["API_KEY=ENV_SECRET_48"])]),
        version:"secret-fixture-1",
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

test(mcp_loader_discovery_redacts_legacy_inline_sensitive_values) :-
    with_security_registry(
        [Registry]>>(
            rlm_load_tools(Registry, mcp, ok(_)),
            tool_invoke(Registry,
                        [tool(mcp_servers)],
                        mcp_servers,
                        _{},
                        [],
                        ok(Execution),
                        _),
            member(Server, Execution.value.servers),
            Server.name == loader_secret_fixture,
            assertion(Server.transport.kind == stdio),
            assertion(Server.transport.argv_count =:= 3),
            assertion(Server.install.kind == process),
            assertion(Server.install.argv_count =:= 3),
            assertion(Server.install.cwd == present),
            assertion(Server.install.environment == supplied),
            assertion(term_does_not_contain(Server, "TRANSPORT_SECRET_48")),
            assertion(term_does_not_contain(Server, "INSTALL_SECRET_48")),
            assertion(term_does_not_contain(Server, "ENV_SECRET_48")),
            assertion(term_does_not_contain(Server, "/tmp/secret-path-48"))
        )).

:- end_tests(rlm_tool_loader_security).
