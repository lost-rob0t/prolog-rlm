# AgentProlog

AgentProlog is the runnable agent application shipped **in the prolog-rlm repository** while `prolog/` remains a reusable SWI-Prolog library.

The dependency direction is intentionally one-way:

```text
bundled harnesses / external frontends
          |
          v
   prolog_agent_ui_v1
          |
          v
     AgentProlog app
          |
          v
 public prolog-rlm APIs
          |
          v
   prolog-rlm runtime
```

Nothing in the reusable `prolog/` library imports AgentProlog or frontend code. Shipping the library, application, and harness from one repository does not collapse their dependency boundary.

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

AgentProlog translates its application command surface into the existing `rlm_cli` contract. It does **not** implement another provider, planner, recursion engine, authority system, effect ledger, history store, or trace format.

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

## UI protocol server

`agentprolog-ui` is the persistent application adapter for the reusable `prolog_agent_ui_v1` protocol.

```sh
nix run .#agentprolog-ui
```

It accepts UTF-8 NDJSON on stdin and emits canonical protocol frames on stdout. The first implemented application commands are:

- `run.submit` — start one canonical AgentProlog/RLM run;
- `session.poll` — inspect the active asynchronous run without inventing frontend state;
- `session.cancel` — cancel the canonical `rlm_async` Future and its linked child work.

The adapter stores only application session state and an opaque Future handle. Provider calls, planning, recursion, tools, authority, effects, verification, and canonical result semantics remain in `prolog-rlm`.

## Programmable configuration

The recovered `agentprolog_config` module is the Prolog-first trusted operator configuration runtime. It supports executable XDG `config.prolog`, JSON import, explicit project trust, generation-aware reloads, and privileged atomic writes.

See [`docs/agentprolog-config.md`](../docs/agentprolog-config.md).

Configuration remains product/operator policy. It does not grant tool capability or effect authority.

## DeepSeek TUI

The bundled reference terminal frontend lives under [`harness/deepseek_tui`](../harness/deepseek_tui) and uses Bubble Tea v2.

```sh
nix run .#deepseek-harness
```

The TUI keeps a persistent `agentprolog-ui` child, negotiates `prolog_agent_ui_v1`, submits correlated commands, polls the canonical Future, and forwards cancellation. It does not scrape one-shot CLI stdout or become an alternate execution path.

## Packaging invariant

The repository exposes distinct roles from one source tree:

```text
packages.prolog-rlm       reusable SWI-Prolog library
packages.agentprolog      bundled application + UI protocol adapter
packages.deepseek-harness bundled Bubble Tea frontend

apps.agentprolog
apps.agentprolog-ui
apps.deepseek-harness
```

Changing the application or frontend layers must not break clean SWI-pack / flake consumption of `prolog-rlm` as a library.
