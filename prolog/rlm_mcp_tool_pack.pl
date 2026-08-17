:- module(rlm_mcp_tool_pack,
          [ load_mcp_tool_pack/2
          ]).

/** <module> Inert MCP external tool category

This module is the loader-facing MCP category adapter. Loading it registers only
sanitized discovery tools in an ordinary `rlm_tool` registry. It never installs,
starts, connects to, or imports tools from an MCP server and never grants the
capabilities needed to invoke the registered discovery tools.

Remote tool import remains an explicit host action through `rlm_mcp_tool` after
a server has been explicitly started/connected. Lifecycle mutation remains in
`rlm_mcp_server` and therefore keeps the shared authority boundary.
*/

:- use_module(rlm_mcp_server).
:- use_module(rlm_tool).
:- use_module(rlm_tool_loader).

:- multifile rlm_tool_loader:tool_pack/2.
:- multifile rlm_tool_loader:tool_pack_manifest/2.

rlm_tool_loader:tool_pack(mcp_core,
                          rlm_mcp_tool_pack:load_mcp_tool_pack).
rlm_tool_loader:tool_pack_manifest(
    mcp_core,
    tool_pack_manifest{
        library:prolog_rlm_mcp,
        category:mcp,
        tools:[tool_export{name:mcp_servers,
                           capability:tool(mcp_servers),
                           effect:read},
               tool_export{name:mcp_server_inspect,
                           capability:tool(mcp_server_inspect),
                           effect:read}]
    }).

load_mcp_tool_pack(Registry, Outcome) :-
    mcp_servers_schema(ListSchema),
    tool_register(Registry,
                  ListSchema,
                  rlm_mcp_tool_pack:mcp_servers_handler,
                  ListOutcome),
    load_after_list(ListOutcome, Registry, Outcome).

load_after_list(error(Error), _, error(Error)) :- !.
load_after_list(ok(_), Registry, Outcome) :-
    mcp_server_inspect_schema(InspectSchema),
    tool_register(Registry,
                  InspectSchema,
                  rlm_mcp_tool_pack:mcp_server_inspect_handler,
                  InspectOutcome),
    (   InspectOutcome = ok(_)
    ->  Outcome = ok(tool_pack{pack:mcp_core,
                               registered:[mcp_servers,mcp_server_inspect]})
    ;   Outcome = InspectOutcome
    ).

mcp_servers_schema(
    tool_schema{
        name:mcp_servers,
        description:"List sanitized declarative MCP server definitions",
        capability:tool(mcp_servers),
        effect:read,
        arguments:_{type:object,
                    required:[],
                    additional_properties:false,
                    properties:_{}},
        result:_{type:any},
        limits:_{time_limit:1.0, max_output_bytes:65536}
    }).

mcp_server_inspect_schema(
    tool_schema{
        name:mcp_server_inspect,
        description:"Inspect one sanitized declarative MCP server definition",
        capability:tool(mcp_server_inspect),
        effect:read,
        arguments:_{type:object,
                    required:[server],
                    additional_properties:false,
                    properties:_{server:_{type:string}}},
        result:_{type:any},
        limits:_{time_limit:1.0, max_output_bytes:65536}
    }).

mcp_servers_handler(_, _{servers:Sanitized}) :-
    mcp_server_definitions(Definitions),
    maplist(sanitize_server_definition, Definitions, Sanitized).

mcp_server_inspect_handler(Args, Sanitized) :-
    text_atom(Args.server, Server),
    mcp_server_definition(Server, Outcome),
    inspect_outcome(Outcome, Sanitized).

inspect_outcome(ok(Spec), Sanitized) :-
    !,
    sanitize_server_definition(Spec, Sanitized).
inspect_outcome(error(Error), _) :-
    throw(error(mcp_server_inspection_failed(Error), _)).

sanitize_server_definition(Spec,
                           mcp_server_info{name:Spec.name,
                                           transport:Transport,
                                           install:Install,
                                           version:Spec.version,
                                           capabilities:Spec.capabilities,
                                           options:Spec.options}) :-
    sanitize_transport(Spec.transport, Transport),
    sanitize_install(Spec.install, Install).

sanitize_transport(stdio(Executable, Args),
                   mcp_transport_info{kind:stdio,
                                      executable:Executable,
                                      argv:Args}) :- !.
sanitize_transport(streamable_http(Endpoint),
                   mcp_transport_info{kind:streamable_http,
                                      endpoint:Endpoint}) :- !.
sanitize_transport(fixture(Kind, _),
                   mcp_transport_info{kind:fixture,
                                      transport_kind:Kind}) :- !.
sanitize_transport(existing(_),
                   mcp_transport_info{kind:existing}) :- !.
sanitize_transport(_, mcp_transport_info{kind:unknown}).

sanitize_install(none, none) :- !.
sanitize_install(process(Executable, Args, Options),
                 mcp_install_info{kind:process,
                                  executable:Executable,
                                  argv:Args,
                                  options:SafeOptions}) :-
    !,
    maplist(sanitize_install_option, Options, SafeOptions).
sanitize_install(_, unsupported).

sanitize_install_option(cwd(Directory), cwd(Directory)) :- !.
sanitize_install_option(env(_), env_reference(supplied)) :- !.
sanitize_install_option(env_refs(Names), env_refs(Names)) :- !.
sanitize_install_option(_, omitted).

text_atom(Value, Value) :- atom(Value), !.
text_atom(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
text_atom(Value, _) :- throw(error(type_error(text, Value), _)).
