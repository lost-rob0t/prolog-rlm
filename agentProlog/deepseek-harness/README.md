# DeepSeek Harness PrologAgent path

This directory contains the parallel DeepSeek Harness frontend/host path for
PrologAgent. It deliberately does **not** create a second coding-agent runtime.

The official `deepseek-ai/deepseek-harness` repository is pinned at
`upstream/` as a git submodule. The current pin is:

- upstream commit: `99f6f02fecdb7dff40c3fbc9470f5907c29f74ca`
- upstream release: `dsh@0.1.0-rc.7`
- license: MIT, with upstream attribution retained by the submodule

## Authority boundary

DeepSeek Harness is used for its host, client, and UI ecosystem. Prolog-RLM is
the canonical agent runtime.

```text
DeepSeek Harness UI / host
          |
          | NDJSON bridge now
          | Cordis Agent provider next
          v
deepseek_prolog_bridge
          |
          v
rlm_conversation
          |
          v
rlm_completion / plans / tools / authority / effects / tracing
```

The frontend must not execute tools, decide permissions, compact conversation
history, or run an independent think-act loop.

### Infinite-chat semantics

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
are intentionally small for the first slice:

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
{"request_id":"4","command":"session/turn","payload":{"session_id":"demo","content":"Inspect this project."}}
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

`session/turn` is the important boundary: it calls
`rlm_conversation:conversation_turn/4`, which in turn drives the canonical
Prolog-RLM completion runtime. There is no generic DeepSeek Harness agent loop
behind that command.

## Status and next slice

This first slice establishes the pinned upstream, lossless session contract,
persistent settings, OpenRouter/DeepSeek route selection, and the Prolog NDJSON
authority bridge.

The next integration slice is the out-of-tree DeepSeek Harness Cordis provider
that implements its `Agent` seam by spawning this bridge, projects PrologAgent
events into the Harness session/UI vocabulary, and disables the stock
`agent-loop`, `compaction-basic`, `command-compact`, and tool-result-pruning
rows for Prolog-backed profiles. Until that provider lands, do not ship a
profile that silently falls back to the stock Harness agent loop.
