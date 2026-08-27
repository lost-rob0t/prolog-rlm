# AgentProlog

AgentProlog is the runnable agent application shipped **in the prolog-rlm repository** while `prolog/` remains a reusable SWI-Prolog library.

The dependency direction is intentionally one-way:

```text
DeepSeek Textual harness
          |
          v
     AgentProlog CLI
          |
          v
 public prolog-rlm APIs
          |
          v
   prolog-rlm runtime
```

Nothing in the reusable `prolog/` library imports AgentProlog or its frontend code. `packages.default` remains the library package; AgentProlog and the DeepSeek harness are separate runnable flake outputs.

## CLI

From the source tree:

```sh
swipl -q -s bin/agentprolog.pl -- help
swipl -q -s bin/agentprolog.pl -- ask "Explain this repository"
```

With Nix:

```sh
nix run .#agentprolog -- ask "Explain this repository"
```

AgentProlog translates its application command surface into the existing `rlm_cli` contract. It does **not** implement another provider, planner, recursion engine, authority system, effect ledger, or trace format.

### Provider profiles

Use the normal configured profile, or choose one explicitly:

```sh
agentprolog ask "..." --provider openrouter
agentprolog ask "..." --provider deepseek
```

The DeepSeek profile uses:

```text
endpoint:       https://api.deepseek.com
model:          deepseek-v4-flash
credential env: DEEPSEEK_API_KEY
```

All normal `prolog-rlm` options such as `--model`, `--max-tokens`, `--reasoning-effort`, `--context`, `--json`, and tracing options remain available and explicit user options override profile defaults.

For raw access to the reusable runtime CLI:

```sh
agentprolog runtime demo
agentprolog runtime rlm "..." --context "..."
```

## Programmable configuration

The recovered `agentprolog_config` module remains the programmable Prolog-first configuration runtime from PR #132. It supports trusted executable `config.prolog`, JSON import, explicit project trust, generation-aware reloads, and privileged atomic writes.

See [`docs/agentprolog-config.md`](../docs/agentprolog-config.md).

Configuration remains product/operator policy. It does not grant tool capability or effect authority.

## DeepSeek TUI

The reference terminal frontend lives under [`harness/deepseek_tui`](../harness/deepseek_tui) and uses Textual.

```sh
nix run .#deepseek-harness
```

The TUI is deliberately thin: it launches the AgentProlog CLI with `--provider deepseek --json`, renders the returned structured result, and never becomes an alternate execution path.

## Packaging invariant

The repository exposes three independent roles:

```text
packages.prolog-rlm       reusable SWI-Prolog library
packages.agentprolog      CLI application using that library
packages.deepseek-harness Textual frontend using the CLI
```

Changing or removing the application layers must not break clean SWI-pack / flake consumption of `prolog-rlm` as a library.
