# DeepSeek TUI harness

This is a **frontend harness**, not a second agent runtime. It runs the `agentprolog` CLI with the DeepSeek profile and renders the session with **Bubble Tea v2** and the **Bubbles v2** component library.

Bubble Tea is the most widely starred general-purpose TUI framework among the mainstream choices checked for this recovery. The harness uses the current v2 Charm import paths rather than starting on the legacy v1 API.

The authority/runtime boundary stays:

```text
Bubble Tea TUI
   -> agentprolog CLI
   -> public prolog-rlm runtime
```

The TUI never evaluates model-generated shell text and never owns provider, tool, authority, effect, planning, or verification semantics. AgentProlog is launched with `exec.Command` argument vectors.

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

Override the model with `DEEPSEEK_MODEL`. Override the AgentProlog executable with `AGENTPROLOG_BIN`.

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
