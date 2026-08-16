# Declarative MCP servers and lifecycle

MCP configuration is ordinary trusted Prolog data. Declaring a server is inert:
it does not install software, launch a process, connect a client, import tools,
or grant capabilities.

## Server definition

External configuration may contribute definitions with `multifile` clauses:

```prolog
:- multifile rlm_mcp_server:mcp_server/2.

rlm_mcp_server:mcp_server(
    filesystem,
    mcp_server_spec{
        transport:stdio(npx,
                        ['-y',
                         '@modelcontextprotocol/server-filesystem',
                         '/srv/allowed-root']),
        install:none,
        version:external,
        capabilities:[tools]
    }).
```

A remote Streamable HTTP endpoint is also declarative:

```prolog
rlm_mcp_server:mcp_server(
    remote_search,
    mcp_server_spec{
        transport:streamable_http('https://mcp.example.invalid'),
        install:none,
        version:external,
        capabilities:[tools, resources]
    }).
```

Inspect a definition without starting it:

```prolog
mcp_server_definition(filesystem, Outcome).
mcp_server_definitions(Definitions).
```

## Explicit lifecycle

Installation and runtime lifecycle are separate operations:

```prolog
rlm_install_mcp_server(filesystem, InstallOutcome).
rlm_run_mcp_server(filesystem, RunOutcome).
```

A successful run returns an owned `mcp_runtime_handle{}`. Connection is explicit
and borrows the owned transport:

```prolog
RunOutcome = ok(Handle),
rlm_connect_mcp_server(Handle,
                       ClientInfo,
                       ClientCapabilities,
                       [],
                       ConnectOutcome).
```

Closing the resulting MCP client closes the protocol connection view but does
not take ownership of the declared server process. Stop and restart remain
explicit lifecycle operations:

```prolog
rlm_stop_mcp_server(Handle, Outcome).
rlm_restart_mcp_server(Handle, Outcome).
```

## Canonical async direction

Every latency-bearing lifecycle operation uses the shared bounded `rlm_async`
scheduler:

```text
canonical execute predicate
          |
          +--> async API -> Future
          |
          +--> sync API  -> same async API -> await Future
```

The implemented pairs cover install, run, stop, restart, connect, client
command, client close, and canonical server request handling. Stateful async MCP
commands return updated client/server state inside the Future result rather than
pretending worker-thread output variables can be unified back into the caller.

Useful Future metadata includes operation kind, MCP subject/server, trace id,
session id, and the scheduler-owned parent task relationship.

## Tool import

Tool import is a separate explicit step and requires an already connected MCP
client:

```prolog
mcp_import_tools(Registry,
                 filesystem,
                 Client,
                 [],
                 Outcome).
```

Imported remote tools are namespaced as ordinary `rlm_tool` entries and execute
through the same canonical tool contract. Loading or importing does not grant
the resulting `tool(Name)` capability.

Consequently an imported MCP tool retains the core enforcement order:

```text
registry lookup
  -> capability gate
  -> argument schema validation
  -> canonical handler execution
  -> result validation/output limit
  -> canonical trace
```

The remote MCP call itself uses the MCP execute ABI directly because the tool
handler is already running inside a canonical async worker. It does not submit a
nested Future and wait on it.

## Cancellation and ownership

Cancellation control exceptions pass through the tool layer, MCP facade,
notification-send path, and transport boundary instead of being normalized into
ordinary tool/MCP errors. Owned lifecycle handles stop their owned transport;
borrowed client views never kill the owner.

## Authority remains separate

This lifecycle slice does not implement an approval UI. The authority tiers
remain `approve_diff`, `allow_once`, `allow_session`, and `dangerous`.
`dangerous` can bypass approval prompts only. It does not bypass capabilities,
schemas, filesystem confinement, budgets, network restrictions, tool
validation, or tracing.

## Installation boundary still intentionally narrow

Current declarations support `install:none` and a direct process recipe without
shell interpolation. Host-registered installer/package-manager policy,
environment/config secret references, richer package/version metadata, and
production concrete MCP tool packs remain follow-up work under issue #52 and the
external tool-library issues. Definitions are never auto-installed or auto-run.
