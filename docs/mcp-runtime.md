# Canonical MCP runtime

`rlm_mcp` is the version-neutral Model Context Protocol boundary for prolog-rlm.
Agent, graph, and RLM code consume canonical Prolog terms. JSON-RPC envelopes,
wire method names, protocol dates, HTTP headers, and transport session state are
owned by the selected protocol adapter.

The first implemented adapter is MCP `2025-11-25`.

## Module boundaries

- `rlm_mcp_model.pl` — canonical commands, capabilities, tools, resources,
  prompts, content, notifications, and JSON-compatible metadata.
- `rlm_mcp_transport.pl` — persistent stdio and Streamable HTTP request/response
  transport plus deterministic fixture transports.
- `rlm_mcp_transport_send.pl` — send-only notification path. In particular,
  stdio notifications are written without waiting for a response.
- `rlm_mcp_v2025_11_25.pl` — JSON-RPC codec, initialization lifecycle,
  capability negotiation, protocol/session headers, result normalization, and
  bounded session recovery for the `2025-11-25` protocol.
- `rlm_mcp.pl` — public canonical client/server facade, ordered traces, dispatch,
  and bounded re-initialization/replay.

Protocol-specific code must not be added to `rlm_agent.pl`, `rlm_graph.pl`, or
other consumers. Conformance tests reject known MCP wire strings in those
modules.

## Canonical commands

The public command vocabulary is deliberately independent of MCP wire method
strings:

```prolog
list_tools
list_tools(Cursor)
call_tool(Name, Arguments)

list_resources
list_resources(Cursor)
read_resource(Uri)

list_prompts
list_prompts(Cursor)
get_prompt(Name, Arguments)
```

Normalize external command data with:

```prolog
mcp_command_normalize(+Input, -Outcome).
```

Successful normalization returns a ground `mcp_command{}` dict. Tool and prompt
names are canonical atoms; URIs and cursors are canonical text values.

Each command maps to a capability class (`tools`, `resources`, or `prompts`).
The 2025 adapter refuses a command when the server did not negotiate the
corresponding capability.

## Canonical entities and results

Entity normalizers are exported through `rlm_mcp`:

```prolog
mcp_tool_normalize(+WireLikeDict, -Outcome).
mcp_resource_normalize(+WireLikeDict, -Outcome).
mcp_prompt_normalize(+WireLikeDict, -Outcome).
mcp_notification_normalize(+Input, -Outcome).
```

The canonical result types are:

```prolog
mcp_tools_page{tools:Tools, next_cursor:Cursor}
mcp_tool_result{content:Content, structured:Structured, is_error:Boolean}
mcp_resources_page{resources:Resources, next_cursor:Cursor}
mcp_resource_result{contents:Contents}
mcp_prompts_page{prompts:Prompts, next_cursor:Cursor}
mcp_prompt_result{description:Description, messages:Messages}
```

Canonical content supports text, image, audio, embedded resources, and resource
links. Tool `structuredContent` is preserved as canonical JSON-compatible data.

Canonical server-to-client notification terms currently include:

```prolog
tools_list_changed
resources_list_changed
prompts_list_changed
resource_updated(Uri)
```

The canonical terms do not contain strings such as `tools/list`, JSON-RPC ids,
or a protocol date.

## Client API

Open a negotiated client with:

```prolog
mcp_client_connect(+TransportSpec,
                   +ClientInfo,
                   +ClientCapabilities,
                   +Options,
                   -Outcome).
```

Example fixture client:

```prolog
mcp_client_connect(
    fixture(streamable_http, my_fixture),
    _{name:"my-client", version:"1.0"},
    _{roots:_{listChanged:false}},
    [],
    ok(Client0)).
```

Execute canonical operations with:

```prolog
mcp_client_command(+Client0, +Command, -Client, -Outcome).
```

The returned client handle carries the new request id, adapter state, session,
and trace. Treat client handles as immutable state values: pass the returned
handle to the next operation.

Decode an incoming canonical notification with:

```prolog
mcp_client_notification(+Client, +WireNotification, -Outcome).
```

Inspect lifecycle evidence with:

```prolog
mcp_client_protocol(+Client, -Protocol).
mcp_client_trace(+Client, -Events).
```

Close a real transport with:

```prolog
mcp_client_close(+Client, -Outcome).
```

## Server API

Create a canonical server state with:

```prolog
mcp_server_new(+TransportKind,
               +ServerInfo,
               +ServerCapabilities,
               +Options,
               -Outcome).
```

`TransportKind` is `stdio` or `streamable_http`. For deterministic server tests,
`session_id(Session)` may be supplied in `Options`.

Process a protocol message with:

```prolog
mcp_server_handle(+Server0,
                  +Wire,
                  +RequestMeta,
                  +Dispatch,
                  -Server,
                  -Outcome).
```

`Dispatch` never receives a JSON-RPC method. It is called with a canonical
`mcp_command{}` value (or a canonical notification wrapper). A successful
command dispatch returns a canonical result dict, which the adapter serializes
back to the selected wire protocol.

## MCP 2025-11-25 lifecycle

The `rlm_mcp_v2025_11_25` adapter implements the protocol lifecycle as a state
machine:

```text
new
  -> initialize request/response
initialized_pending
  -> notifications/initialized
ready
```

The initialize request declares protocol version `2025-11-25`, client
implementation metadata, and client capabilities. The response must negotiate
that supported protocol version and provide server implementation metadata and
capabilities. Unsupported versions fail closed.

For Streamable HTTP:

- initialization advertises JSON and SSE response media types;
- later operations include `MCP-Protocol-Version: 2025-11-25`;
- when the server supplies an `MCP-Session-Id`, later operations include it;
- a response is correlated with its expected JSON-RPC request id;
- a `404` on an established session invalidates that session;
- the canonical client permits exactly one re-initialization and command replay;
- a second invalidation fails with `reinitialize_exhausted`.

For stdio, protocol and session HTTP headers are absent. Initialization and
canonical commands still use the same adapter state machine. The initialized
notification is send-only, so a stdio client never blocks waiting for a response
to a JSON-RPC notification.

## Transport specifications

### Fixture

```prolog
fixture(stdio, Handler)
fixture(streamable_http, Handler)
```

The deterministic handler is called with the outgoing wire dict and transport
metadata and returns an `mcp_transport_response{}` (or `null` for a send-only
fixture notification).

### stdio

```prolog
stdio(Executable, Arguments)
```

The transport owns persistent stdin/stdout/stderr pipes for the child process.
Each JSON-RPC request is encoded as one JSON line and each response is decoded
from one JSON line. Notification sends do not read stdout.

### Streamable HTTP

```prolog
streamable_http(Endpoint)
```

The transport uses SWI-Prolog HTTP streams and accepts an ordinary JSON response
or an SSE response containing a JSON-RPC result event. Transport code only moves
envelopes and metadata; it does not choose MCP methods or interpret protocol
capabilities.

## Trace contract

Client and server lifecycle events use ordered `mcp_trace{}` values:

```prolog
mcp_trace{
    sequence:Sequence,
    type:Type,
    protocol_version:Protocol,
    transport:Transport,
    detail:Detail
}
```

Client traces cover connection, initialize send, negotiated initialization,
ready state, command send/completion, and session invalidation. Server traces
cover creation, initialization, ready state, command completion, and canonical
notification receipt.

Sequence numbers are monotonic within a client/server state value.

## Failure contract

Ordinary validation, negotiation, transport, remote, capability, and session
failures return structured `error(Error)` outcomes. The runtime does not turn
cancellation or time-limit control exceptions into ordinary MCP failures.

Important fail-closed cases include:

- unsupported protocol version;
- use of an MCP capability that was not negotiated;
- JSON-RPC response id mismatch;
- missing/incorrect HTTP protocol header after initialization;
- missing/incorrect established session id;
- unknown wire method or notification;
- malformed canonical entity/result data;
- exhausted 404 session recovery budget.

## Primary protocol references

Implementation details are based on the official Model Context Protocol
`2025-11-25` specification, especially Lifecycle, Transports, Client, and Server
sections on `modelcontextprotocol.io`.
