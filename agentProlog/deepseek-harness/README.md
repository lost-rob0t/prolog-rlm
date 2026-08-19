# DeepSeek Harness PrologAgent path

This directory contains the parallel DeepSeek Harness frontend/host path for
PrologAgent. It deliberately does **not** create a second coding-agent runtime.

The official `deepseek-ai/deepseek-harness` repository is pinned at
`upstream/` as a git submodule:

- upstream commit: `99f6f02fecdb7dff40c3fbc9470f5907c29f74ca`
- upstream release: `dsh@0.1.0-rc.7`
- license: MIT, with upstream attribution retained by the submodule

## Authority boundary

DeepSeek Harness is used for its host, client, and UI ecosystem. Prolog-RLM is
the canonical agent runtime.

```text
DeepSeek Harness UI / Cordis host
              |
              v
host/bridge-client.mjs
  NDJSON framing + cancellation propagation only
              |
              v
deepseek_prolog_bridge
  sessions + Prolog-owned async run handles
              |
              v
rlm_conversation + rlm_async
              |
              v
completion / plans / tools / authority / effects / tracing
```

The frontend must not execute tools, decide permissions, select context,
compact conversation history, or run an independent think-act loop.

The Harness-side transport client is intentionally boring. It correlates NDJSON
requests and maps a host `AbortSignal` to `run/cancel`. The run itself is an
`rlm_async` Future owned by Prolog, so cancellation reaches the actual operation
instead of merely hiding its output.

## Infinite-chat semantics

"Infinite" means the canonical conversation transcript is durable, append-only,
and never replaced by a summary. It does **not** mean sending an unbounded byte
string to a finite-context model.

`rlm_conversation` keeps every turn. For each provider request it compiles a
bounded working set and exposes omitted history through the RLM context handle,
where it remains searchable and sliceable. The DeepSeek Harness compaction
plugins are therefore not part of the canonical Prolog-backed session path.

The settings validator hard-requires:

```json
{
  "driver": "prolog-rlm",
  "history_mode": "lossless_rlm",
  "compaction": false
}
```

Any attempt to persist `compaction: true` is rejected.

## Providers

Provider execution remains in Prolog-RLM.

- `openrouter` reuses the existing `openrouter_provider/2` implementation and
  resolves only `OPENROUTER_API_KEY` at request execution time.
- `deepseek` uses the existing OpenAI-compatible provider boundary with
  `https://api.deepseek.com/chat/completions` and `DEEPSEEK_API_KEY`.

No API key is stored in the settings document.

The default route is OpenRouter `openrouter/free`. A DeepSeek configuration can
use, for example:

```json
{
  "provider": "deepseek",
  "model": "deepseek-v4-pro"
}
```

## Persistent settings

The default settings path is:

```text
$XDG_CONFIG_HOME/prolog-rlm/deepseek-harness.json
```

or `~/.config/prolog-rlm/deepseek-harness.json` when `XDG_CONFIG_HOME` is not
set.

The default durable conversation store is under `$XDG_STATE_HOME`, falling back
to `~/.local/state/prolog-rlm/`.

Settings are materialized on first bridge startup. Supported persisted fields
are intentionally small:

```json
{
  "schema_version": 1,
  "driver": "prolog-rlm",
  "history_mode": "lossless_rlm",
  "compaction": false,
  "persist_sessions": true,
  "provider": "openrouter",
  "model": "openrouter/free",
  "conversation_store": "/home/me/.local/state/prolog-rlm/deepseek-harness-conversations.db"
}
```

Unknown keys are rejected. This also prevents somebody from casually adding an
`api_key` field and leaking a credential into a settings file or trace.

## Running the bridge

Initialize the pinned upstream:

```sh
git submodule update --init agentProlog/deepseek-harness/upstream
```

Run the Prolog bridge:

```sh
swipl -q -s agentProlog/deepseek-harness/bin/deepseek-prolog-bridge.pl
```

or select a settings document explicitly:

```sh
swipl -q -s agentProlog/deepseek-harness/bin/deepseek-prolog-bridge.pl -- \
  --settings /path/to/settings.json
```

The protocol is one JSON object per line. Requests may carry a `request_id` and
receive the same ID back.

```json
{"request_id":"1","command":"hello","payload":{}}
{"request_id":"2","command":"session/create","payload":{"id":"demo","metadata":{}}}
{"request_id":"3","command":"session/messages","payload":{"session_id":"demo","limit":"all"}}
{"request_id":"4","command":"session/turn/start","payload":{"session_id":"demo","content":"Inspect this project."}}
{"request_id":"5","command":"run/status","payload":{"run_id":"<run-id>"}}
{"request_id":"6","command":"run/cancel","payload":{"run_id":"<run-id>"}}
{"request_id":"7","command":"run/result","payload":{"run_id":"<run-id>"}}
```

Current bridge commands:

- `hello`
- `settings/get`
- `settings/set`
- `session/create`
- `session/open`
- `session/list`
- `session/messages`
- `session/search`
- `session/stats`
- `session/turn`
- `session/turn/start`
- `run/status`
- `run/result`
- `run/cancel`

`session/turn` and `session/turn/start` both enter the canonical
`rlm_conversation` runtime. The asynchronous form additionally registers the
work with `rlm_async`, giving the host a real cancellable run handle without
moving scheduling into JavaScript.

## Harness profile fence

`profile/cordis.patch.yml` is applied after the normal Harness bundles. It
explicitly disables:

- `agent-loop`
- `compaction-basic`
- `command-compact`
- `tool-result-pruner`

That overlay is deliberately fail-closed. Until the Prolog-backed Cordis
`AgentFactory` is mounted, a Prolog profile must fail agent creation rather than
fall back to the stock Harness loop or history rewriting.

## Tests

The normal SWI suite covers settings, provider routing, bridge sessions,
persistence across close/reopen, async run cancellation, run cleanup, and the
fail-closed Harness profile.

`.github/workflows/deepseek-harness.yml` adds a separate host composition gate:

1. Node-only NDJSON correlation and cancellation tests;
2. a real Node -> `swipl` bridge process test that negotiates the Prolog runtime
   and performs session/settings operations without a model call;
3. verification that the DeepSeek Harness gitlink remains pinned to the audited
   upstream revision.

## Next integration slice

The next slice is the out-of-tree Cordis `AgentFactory` package. DeepSeek
Harness profiles explicitly support out-of-tree plugin dependencies, so this
can live beside the pinned upstream rather than modifying it.

That factory will:

- spawn/own `host/bridge-client.mjs`;
- create or resume the canonical Prolog session for each Harness agent;
- use `session/turn/start` and the Prolog Future for the driver lifetime;
- map `Agent.cancel()` to `run/cancel` and make `whenIdle()` follow actual
  Prolog quiescence;
- project canonical `prolog_agent_ui_v1` events into Harness session/UI events;
- route approval/question/steer/inject operations back to Prolog commands;
- never call Harness LLM, tool, permission, compaction, or pruning services for
  a Prolog-backed session.

Streaming, approval/question interaction, steering and injection must be backed
by the canonical PrologAgent event/command boundary before the factory claims
those capabilities. Unsupported semantics fail loudly; they are not simulated
in TypeScript.
