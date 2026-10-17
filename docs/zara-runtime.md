# Zara runtime adapter (ZARA-RUNTIME/1)

Prolog-RLM can act as an **optional** Zara runtime without making Zara or Prolog-RLM depend on each other at package/runtime level.

This adapter is deliberately thin:

- Prolog-RLM remains authoritative for provider/model calls, planning, RLM execution, budgets, cancellation and trace data.
- Zara remains authoritative for UI, projects/conversations, context sources, plugin discovery/approval and platform integration.
- AgentProlog remains a downstream product/profile over Prolog-RLM. This module does not import or depend on AgentProlog.
- Python is not a Prolog-RLM runtime requirement. A desktop Zara process may use Python to host UI/context/plugins, but it must not run a second model planner when the selected runtime is Prolog-RLM.

The cross-repository architecture authority is lost-rob0t/zara#1046.

## Start the local sidecar

The service binds to loopback only.

```sh
swipl -q -s bin/prolog-rlm-zara.pl -- --port 18765
```

It exposes:

```text
GET  /zara-runtime/v1/discover
GET  /zara-runtime/v1/health
POST /zara-runtime/v1/generate
POST /zara-runtime/v1/cancel
```

The first implementation is buffered HTTP, so discovery reports `supports_streaming=false`. Consumers must honor capability discovery rather than pretending ordered deltas exist. Streaming/SSE is a later ZARA-RUNTIME/1 slice.

## Discover

```json
{
  "runtimes": [
    {
      "id": "prolog-rlm",
      "protocol": "ZARA-RUNTIME/1",
      "locality": "local_sidecar",
      "transport": "loopback_http",
      "provider_control": "runtime",
      "model_control": "runtime",
      "supports_streaming": false,
      "supports_cancel": true
    }
  ]
}
```

Discovery says the runtime itself is available. It does **not** claim that a particular provider credential/model is configured.

## Generate

A minimal OpenRouter-backed request:

```json
{
  "protocol": "ZARA-RUNTIME/1",
  "request_id": "zara-turn-42",
  "mode": "rlm",
  "prompt": "Summarize the supplied context.",
  "inline_context": "bounded host context",
  "budgets": {"max_tokens": 512, "wall_time_ms": 30000}
}
```

Provider/model selection is runtime-owned. Zara may pass operator preferences using a provider object with `kind`, `endpoint`, `model`, and optional `credential_env` fields. Use `no_credential: true` only for a trusted local endpoint that requires none.

**Literal credentials are rejected.** The wire accepts only the name of an environment variable. The sidecar resolves that variable inside its own process.

The response is a stable Zara envelope with normalized assistant text. Raw provider result and trace payloads stay inside the sidecar.

## Cancel

POST a JSON object containing the same `request_id`. Cancellation maps to the canonical `rlm_cancellation_token/1` + `rlm_cancel/1` path. Unknown/already-finished ids return `not_found` and do not cancel another request.

## Bounds

The adapter starts from `default_completion_budget/1`. A client may narrow limits but may not expand past the runtime defaults through this bridge. Inline context and message text are also size-bounded.

Future opaque Zara context handles and host-plugin calls must remain typed capability requests; they must not grant ambient Python, shell, filesystem, plugin-registry or arbitrary Prolog execution.

## Trusted host tool registration

An embedding Prolog host can call `zara_runtime_set_host_tools(Token, Specs)` before serving requests. Each spec is `host_tool(Schema, Handler)`, where `Schema` is an existing `rlm_tool` schema and `Handler` is a trusted Prolog callable. Registration uses the canonical `rlm_tool` registry and its schema, capability, preflight, and read authority rules. This slice admits **read-effect tools only**; write/process/effectful registration fails until approval-resume and durable callback semantics exist. A model or HTTP client cannot register a handler.

Once registered, discovery reports `supports_host_tools=true`. An authenticated generation request may contain `"host_tools": ["tool_name"]`, limited to 16 distinct names already registered by the host. These names grant only the corresponding `tool(name)` capabilities for that request. The runtime passes the server-owned registry into Prolog-RLM completion and does not grant tools to child completions. An unknown, duplicate, or structured grant fails before model execution; an omitted list grants none. When no registry is installed, host tools are unavailable.

The token is private launch configuration, at least 16 characters, and must not appear in source, logs, or a model prompt. While a registry is installed, HTTP generation and cancellation require `Authorization: Bearer <token>`; discovery and health remain observations. Reconfiguration is denied while a generation is active. The trusted in-process `zara_runtime_execute/2` entrypoint does not use HTTP authentication; only code already executing inside the Prolog process may call it.

The packaged sidecar can also configure **read-only Zara callbacks** after startup. Set the same private `ZARA_RUNTIME_HOST_TOKEN` environment variable in the sidecar and Zara host. Zara sends `POST /zara-runtime/v1/host-config` with `Authorization: Bearer <token>` and a bounded JSON body:

```json
{
  "protocol": "ZARA-RUNTIME/1",
  "endpoint": "http://127.0.0.1:19001/zara-host-tool/v1/read",
  "generation": 7,
  "tools": [{
    "name": "file_read",
    "description": "Read a bounded file from the selected repository",
    "arguments": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
    "result": {"type": "object", "properties": {"content": {"type": "string"}}, "required": ["content"]}
  }]
}
```

The sidecar accepts only literal IPv4 loopback at the fixed `/zara-host-tool/v1/read` path. It converts the JSON descriptors into canonical read-effect `rlm_tool` schemas. No capability, effect class, handler, Prolog source, or shell command may be supplied on this wire. Generate requests still grant existing names explicitly through `host_tools`, and all generation/cancel calls require the bearer token while callback tools are configured.

For each admitted read tool invocation, Prolog-RLM sends a bounded authenticated POST to Zara's configured endpoint with `protocol:"ZARA-HOST-TOOL/1"`, `request_id`, a fresh `tool_call_id`, `generation`, `name`, and schema-validated `args`. Zara must return HTTP 200 with the same protocol and exact identity fields plus either `status:"ok", value:<schema-valid result>` or `status:"denied"`. The sidecar disables proxies and redirects, limits response bytes and time, and rejects mismatched identities. Zara remains responsible for principal/project/repository lease checks and its canonical plugin authorization before reading. A denied or invalid callback returns a tool failure to the planner.

An effectful callback also needs an operator-selected durable journal path in `ZARA_RUNTIME_EFFECT_STORE`. The sidecar opens this store at startup and rejects effectful host configuration without it. A stock sidecar without a configured token and descriptors still advertises `supports_host_tools=false`.

### Effectful Zara host callbacks and approval

An authenticated `host-config` request may add an `effect_endpoint` at the fixed literal loopback path `/zara-host-tool/v1/effect` and descriptors with `effect:"write"` or `effect:"process"`. The descriptor set replaces the previous complete set atomically while idle, including the read descriptors. Reconfiguration fails while generate is active or an approval is retained. Each generate request still grants only explicit `host_tools` names. The model cannot select an effect class, endpoint, handler, Prolog source, or authority tier.

Prolog's native `approve_diff` mode returns `status:"approval_required"` with `request_id`, `generation`, and bounded approval records containing `id`, `name`, `effect`, `args`, `fingerprint` (authority fingerprint), `attempt_id`, `effect_fingerprint`, and `idempotency_key`. The sidecar retains that request's registry. Zara must bind its post-approval callback lease to the exact request, generation, attempt, effect fingerprint, idempotency key, name, and arguments before invoking the approval endpoint. The authority fingerprint and effect fingerprint are distinct. Zara can inspect and resolve the pending operation using the same bearer token:

- `POST /zara-runtime/v1/host-pending` with `{protocol,request_id,generation}`;
- `POST /zara-runtime/v1/host-approval` with those fields plus `approval_id` and `decision:"approve"|"deny"`;
- `POST /zara-runtime/v1/host-approval-status` with those fields plus `approval_id`.

The approval endpoint calls `rlm_authority` directly; there is no second approval authority. Wrong request, generation, or approval ID returns `not_found`. Approval schedules the existing pending continuation. Status reports `running`, `completed` with a value, `failed`, or `indeterminate`; a terminal status releases the retained registry after all approvals for that request have resolved. Approval records exist only in the running sidecar process. A restart discards unapproved continuations, so old approval IDs cannot dispatch. The durable effect journal retains already dispatched attempts and requires reconciliation for uncertainty.

After native approval and durable dispatch, the adapter sends a bounded authenticated request to Zara's fixed effect endpoint:

```json
{
  "protocol": "ZARA-HOST-EFFECT/1",
  "request_id": "generate request id",
  "tool_call_id": "durable attempt id",
  "generation": 7,
  "attempt_id": "durable attempt id",
  "idempotency_key": "durable attempt idempotency key",
  "effect_fingerprint": "normalized executable fingerprint",
  "name": "file_write",
  "args": {"path": "src/main.py", "content": "..."}
}
```

Zara must authenticate the bearer, check its active turn lease and generation, and use `idempotency_key` to deduplicate the write. It must echo `protocol`, `request_id`, `tool_call_id`, `generation`, `attempt_id`, and `effect_fingerprint`. `status:"observed"` requires a schema-valid, byte-bounded `value`; `in_progress` and `indeterminate` are also accepted. A missing response, identity mismatch, invalid result, or transport timeout leaves the attempt indeterminate. The sidecar does not resubmit it. No remote reconciliation callback is implemented yet, so an uncertain write cannot be resolved automatically after restart. Zara's effect handler and idempotency store must be implemented and tested before enabling write descriptors in production.

## Android deployment

The Android app must not bundle SWI-Prolog merely because this adapter exists. A Prolog-RLM installation may run this service from Termux or another separately installed local runtime package. Zara discovers it as a local sidecar and talks over loopback.

Arbitrary LAN endpoints are not "installed local runtimes" and must not be auto-discovered.

## Conformance

`test/rlm_zara_runtime_test.pl` is part of the deterministic corpus. It locks the protocol descriptor, provider/runtime authority split, fail-closed protocol and mode handling, literal-secret rejection/redaction, budget bounds and idempotent cancellation of unknown requests.

Real provider execution is intentionally **not** faked by these tests. Live provider smoke remains a separate credentialed gate.
