# DeepSeek TUI harness

This is a **frontend harness**, not a second agent runtime. It runs the `agentprolog` CLI with the DeepSeek profile and renders the result with [Textual](https://github.com/Textualize/textual).

The authority/runtime boundary stays:

```text
Textual TUI
   -> agentprolog CLI
   -> public prolog-rlm runtime
```

The TUI never executes model-generated shell text and never owns provider, tool, authority, effect, planning, or verification semantics.

## Run

With Nix:

```sh
nix run .#deepseek-harness
```

Or from Python packaging:

```sh
python -m pip install -e harness/deepseek_tui
deepseek-harness
```

Set the DeepSeek credential in the environment:

```sh
export DEEPSEEK_API_KEY=...
```

The default API profile is the current OpenAI-compatible DeepSeek endpoint and model:

```text
endpoint: https://api.deepseek.com
model:    deepseek-v4-flash
```

Override the model with `DEEPSEEK_MODEL`. Override the AgentProlog executable with `AGENTPROLOG_BIN`.

For a dependency/import smoke check without entering full-screen mode:

```sh
deepseek-harness --check
```
