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

The response is a stable Zara envelope with normalized assistant text and a JSON-safe encoded Prolog-RLM result/trace payload.

## Cancel

POST a JSON object containing the same `request_id`. Cancellation maps to the canonical `rlm_cancellation_token/1` + `rlm_cancel/1` path. Unknown/already-finished ids return `not_found` and do not cancel another request.

## Bounds

The adapter starts from `default_completion_budget/1`. A client may narrow limits but may not expand past the runtime defaults through this bridge. Inline context and message text are also size-bounded.

Future opaque Zara context handles and host-plugin calls must remain typed capability requests; they must not grant ambient Python, shell, filesystem, plugin-registry or arbitrary Prolog execution.

## Android deployment

The Android app must not bundle SWI-Prolog merely because this adapter exists. A Prolog-RLM installation may run this service from Termux or another separately installed local runtime package. Zara discovers it as a local sidecar and talks over loopback.

Arbitrary LAN endpoints are not "installed local runtimes" and must not be auto-discovered.

## Conformance

`test/rlm_zara_runtime_test.pl` is part of the deterministic corpus. It locks the protocol descriptor, provider/runtime authority split, fail-closed protocol and mode handling, literal-secret rejection/redaction, budget bounds and idempotent cancellation of unknown requests.

Real provider execution is intentionally **not** faked by these tests. Live provider smoke remains a separate credentialed gate.
