# DeepSeek TUI harness

This is the bundled **frontend harness**, not a second agent runtime. It uses **Bubble Tea v2** and talks to the persistent `agentprolog-ui` process over the existing renderer-independent `prolog_agent_ui_v1` NDJSON protocol.

The runtime boundary is:

```text
Bubble Tea TUI
   -> prolog_agent_ui_v1
   -> agentprolog-ui application adapter
   -> AgentProlog command/config composition
   -> public prolog-rlm runtime
```

The TUI does not own provider, tool, authority, effect, planning, history, recursion, or verification semantics. It submits explicit correlated commands and renders canonical results/events produced by Prolog.

## Runtime behavior

The frontend keeps one `agentprolog-ui` child process alive for the session.

A turn is:

```text
negotiate
-> run.submit
-> run_started event
-> session.poll ...
-> run_finished event
```

`Esc` while a run is active sends `session.cancel`. The AgentProlog adapter cancels the canonical `rlm_async` Future, so cancellation reaches the Prolog execution tree instead of merely stopping UI waiting.

Request IDs correlate command results. Runtime events retain their own server-owned sequence numbers and may carry `caused_by` request correlation according to `prolog_agent_ui_v1`.

## Run

With Nix:

```sh
nix run .#deepseek-harness
```

From a development shell:

```sh
nix develop
go run ./harness/deepseek_tui
```

Set the DeepSeek credential in the environment:

```sh
export DEEPSEEK_API_KEY=...
```

The default API profile is:

```text
endpoint: https://api.deepseek.com
model:    deepseek-v4-flash
```

Override the model with `DEEPSEEK_MODEL`.

Override the protocol-server executable with:

```sh
export AGENTPROLOG_UI_BIN=/path/to/agentprolog-ui
```

For a non-interactive binary/dependency smoke check:

```sh
deepseek-harness --check
```

Pinned direct Go dependencies:

```text
charm.land/bubbletea/v2 v2.0.8
charm.land/bubbles/v2   v2.1.1
charm.land/lipgloss/v2  v2.0.5
```
