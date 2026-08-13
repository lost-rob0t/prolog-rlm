# Canonical MCP runtime

`rlm_mcp` is the version-neutral Model Context Protocol boundary for
`prolog-rlm`. Agent, graph, chain, completion, and plan code consume canonical
Prolog terms. JSON-RPC envelopes, protocol dates, method strings, HTTP routing
headers, and legacy session state end at the MCP negotiation/adapter boundary.

Supported protocol generations:

- `2025-11-25` — legacy initialize/initialized lifecycle with optional
  Streamable HTTP sessions;
- `2026-07-28` — stateless, self-describing requests with `server/discover`.

The architectural invariant is:

> Version-specific MCP behavior ends at the adapter boundary.

## Module boundaries

- `rlm_mcp_model.pl` — canonical commands, capabilities, tools, resources,
  prompts, content, notifications, and JSON-compatible metadata.
- `rlm_mcp_transport.pl` — stdio, Streamable HTTP, and deterministic fixture
  transports. It moves envelopes and headers but never selects a protocol.
- `rlm_mcp_transport_send.pl` — send-only legacy notification transport path.
- `rlm_mcp_v2025_11_25.pl` — 2025 JSON-RPC codec, initialize lifecycle,
  session headers, capability negotiation, and bounded 404 recovery.
- `rlm_mcp_v2026_07_28.pl` — 2026 self-describing request codec,
  `server/discover`, routing metadata, `resultType`, and standardized version
  errors. It contains no session lifecycle.
- `rlm_mcp_compat.pl` — replaceable endpoint compatibility cache containing only
  protocol-selection evidence.
- `rlm_mcp.pl` — canonical client/server facade, bounded negotiation/fallback,
  protocol routing, traces, and canonical dispatch.

Static regression tests reject protocol dates, MCP wire methods, routing headers,
and JSON-RPC branching in `rlm_agent.pl`, `rlm_graph.pl`, `rlm_chain.pl`,
`rlm_completion.pl`, and `rlm_plan.pl`.

## Canonical commands

The public command vocabulary is independent of MCP wire method strings:

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

Successful normalization returns a ground `mcp_command{}` value. The canonical
model also normalizes tools, resources, prompts, content, notifications, and
capabilities. Formal extension advertisement is represented by the canonical
`extensions` capability; deprecated `roots` and `sampling` fields remain in the
model only for compatibility with older peers.

The canonical result families are:

```prolog
mcp_tools_page{tools:Tools, next_cursor:Cursor}
mcp_tool_result{content:Content, structured:Structured, is_error:Boolean}
mcp_resources_page{resources:Resources, next_cursor:Cursor}
mcp_resource_result{contents:Contents}
mcp_prompts_page{prompts:Prompts, next_cursor:Cursor}
mcp_prompt_result{description:Description, messages:Messages}
```

Tool `structuredContent` is preserved as canonical JSON-compatible data. The
2026 wire-level `resultType` discriminator is adapter-owned and is not exposed
as protocol branching in callers.

## Client API

Open a negotiated client with:

```prolog
mcp_client_connect(+TransportSpec,
                   +ClientInfo,
                   +ClientCapabilities,
                   +Options,
                   -Outcome).
```

By default the client uses `protocol(auto)`. It first consults verified endpoint
compatibility, otherwise probes the 2026 discovery path and performs at most one
legacy protocol fallback. Explicit pins are also available:

```prolog
protocol('2025-11-25')
protocol('2026-07-28')
```

`cache_max_age(GenerationCount)` controls deterministic compatibility-cache
staleness. The default is 32 connection generations.

Execute canonical operations with:

```prolog
mcp_client_command(+Client0, +Command, -Client, -Outcome).
```

Inspect protocol and ordered evidence with:

```prolog
mcp_client_protocol(+Client, -Protocol).
mcp_client_trace(+Client, -Events).
```

Close the transport with:

```prolog
mcp_client_close(+Client, -Outcome).
```

Client state values are immutable handles: pass the returned handle to the next
operation.

## Negotiation policy

The selection policy is deterministic and bounded:

1. A non-stale verified cache entry may select its previously verified protocol.
2. Explicit mutual 2026 support is preferred.
3. With unknown compatibility, the client sends `server/discover` using the
   2026 request format.
4. A successful discovery that includes `2026-07-28` selects 2026.
5. A legacy endpoint that rejects or cannot service discovery falls back once
   to the 2025 initialize lifecycle.
6. If a selected 2026 peer later returns the standardized unsupported-version
   error and advertises `2025-11-25`, the client invalidates the cache,
   initializes 2025, and replays the command once.
7. Protocol fallback never loops; the protocol retry budget is one.

Every selection, discovery, rejection, and fallback is recorded in the canonical
trace.

## Endpoint compatibility cache

`rlm_mcp_compat.pl` stores only:

- endpoint identity;
- transport kind;
- verified supported versions;
- selected version;
- verification source;
- deterministic generation.

It never stores session identifiers or agent/graph state. Malformed entries are
removed and treated as misses. Entries older than the caller-provided generation
window are deterministically invalidated. A rejected selected protocol is also
invalidated before fallback.

This module is intentionally replaceable; protocol selection does not depend on
a specific persistence implementation.

## MCP 2025-11-25 lifecycle

The legacy adapter retains the existing state machine:

```text
new
  -> initialize request/response
initialized_pending
  -> notifications/initialized
ready
```

The initialize request carries protocol version, client implementation metadata,
and capabilities. For Streamable HTTP, post-initialize requests include
`MCP-Protocol-Version: 2025-11-25`. When a server returns an
`MCP-Session-Id`, later requests carry that session id.

A `404` for an established legacy session invalidates it. The client permits
exactly one re-initialization and replay. A second invalidation fails with
`reinitialize_exhausted`.

For stdio, HTTP headers are absent but the legacy initialize lifecycle remains.
The initialized notification is send-only and does not wait for a response.

## MCP 2026-07-28 lifecycle

The 2026 adapter is stateless. It does **not** send `initialize`, does not send
`notifications/initialized`, does not allocate an MCP session id, and does not
reuse legacy 404 session recovery.

Every request carries request-scoped `_meta` data:

- `io.modelcontextprotocol/protocolVersion`;
- `io.modelcontextprotocol/clientCapabilities`;
- `io.modelcontextprotocol/clientInfo` when available.

Servers implement `server/discover`. The canonical server response advertises
supported versions and server capabilities and places server implementation
metadata in result `_meta`.

Successful 2026 results include `resultType: "complete"`. Missing or unsupported
result types fail closed rather than being silently interpreted as a 2025
result.

### Streamable HTTP routing metadata

Every 2026 POST includes:

- `Accept: application/json, text/event-stream`;
- `MCP-Protocol-Version: 2026-07-28`;
- `Mcp-Method: <JSON-RPC method>`.

`tools/call`, `resources/read`, and `prompts/get` additionally send `Mcp-Name`
from the request name or URI. Values unsafe for a direct HTTP routing header are
UTF-8/Base64 encoded using the MCP `:(b64):` sentinel form.

The server verifies that body protocol metadata and HTTP protocol/method/name
routing metadata agree before canonical dispatch.

### Standard 2026 protocol errors

The adapter emits the standardized JSON-RPC errors used by the 2026 protocol:

- `-32020` — request/header metadata mismatch;
- `-32022` — unsupported protocol version, with `supported` and `requested`
  version data.

These map to HTTP 400 on the server path. A recognized `-32022` response drives
bounded version selection rather than an unbounded retry loop.

## Dual-version server routing

Create one canonical server with:

```prolog
mcp_server_new(+TransportKind,
               +ServerInfo,
               +ServerCapabilities,
               +Options,
               -Outcome).
```

The server keeps independent adapter state: legacy 2025 session state and a
stateless 2026 adapter. Detection/routing occurs before canonical command
dispatch:

```text
transport
  -> protocol detection / negotiation
  -> selected version adapter
  -> canonical mcp_command{}
  -> canonical Dispatch
  -> selected version adapter
  -> transport reply
```

A legacy `initialize` is routed to 2025. A self-describing request carrying 2026
protocol metadata is routed to 2026. Legacy post-initialize requests continue to
use the existing 2025 state/session validator.

`Dispatch` never receives protocol dates or wire method strings.

## Compatibility matrix

Deterministic tests cover these paths:

| Client | Server | Expected path |
| --- | --- | --- |
| prolog-rlm | 2025-only | discovery rejection -> 2025 initialize/session |
| prolog-rlm | 2026-only | discovery -> stateless 2026 |
| prolog-rlm | dual | prefer verified 2026 |
| 2025-only | prolog-rlm | 2025 adapter/session lifecycle |
| 2026-only | prolog-rlm | 2026 stateless adapter |
| dual | prolog-rlm | request metadata selects the correct adapter |

The suite also covers response-id mismatch, required 2026 `resultType`, routing
header/body mismatch, unsupported-version advertisement, bounded fallback,
cache staleness, malformed cache entries, and time-limit propagation.

## Transport specifications

### Fixture

```prolog
fixture(stdio, Handler)
fixture(streamable_http, Handler)
```

The deterministic handler receives the outgoing wire dict and transport
metadata and returns an `mcp_transport_response{}`. Legacy send-only fixture
notifications may return `null`.

### stdio

```prolog
stdio(Executable, Arguments)
```

The transport owns persistent stdin/stdout/stderr pipes. JSON-RPC requests are
encoded one per line and responses are decoded one per line.

### Streamable HTTP

```prolog
streamable_http(Endpoint)
```

The transport uses SWI-Prolog HTTP streams and accepts ordinary JSON responses
or SSE responses carrying a JSON-RPC result event. It does not interpret
protocol versions or MCP capabilities.

## Trace contract

Client and server events are ordered `mcp_trace{}` values:

```prolog
mcp_trace{
    sequence:Sequence,
    type:Type,
    protocol_version:Protocol,
    transport:Transport,
    detail:Detail
}
```

Important negotiation events include `discover_sent`, `protocol_selected`,
`protocol_rejected`, and `protocol_fallback`. Legacy lifecycle traces retain
`initialize_sent`, `initialized_negotiated`, `ready`, and
`session_invalidated`. Commands use `command_sent` and `command_completed`.
Server traces distinguish discovery and command completion while retaining the
legacy lifecycle evidence.

Sequence numbers are monotonic within a client/server state value.

## Failure and control-exception contract

Ordinary validation, negotiation, transport, remote, capability, cache, and
session failures return structured `error(Error)` outcomes. Cancellation and
time-limit control exceptions are rethrown and are never converted to ordinary
MCP failures.

Fail-closed cases include malformed request metadata, mismatched routing
headers, unsupported versions, unnegotiated capabilities, response-id mismatch,
missing 2026 `resultType`, malformed capability advertisement, malformed cache
state, incorrect legacy session ids, and exhausted retry/recovery budgets.

## Model inference remains provider-native

MCP interoperability is for tools, resources, prompts, and applicable
extensions. `prolog-rlm` does not redesign its model-completion architecture
around MCP Sampling. The provider/OpenRouter completion path remains the model
inference path; deprecated legacy Sampling/Roots behavior is not promoted into
the core RLM architecture.

## Primary protocol references

Wire behavior is implemented against the official Model Context Protocol
`2025-11-25` and `2026-07-28` specification/schema in the
`modelcontextprotocol/modelcontextprotocol` repository and the official
2026-07-28 release documentation. Secondary SDK behavior is not treated as the
protocol source of truth.
