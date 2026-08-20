# DeepSeek Harness PrologAgent path

This directory contains the DeepSeek Harness host path for PrologAgent. It deliberately does **not** create a second coding-agent runtime.

The official `deepseek-ai/deepseek-harness` repository is pinned at `upstream/` as a git submodule:

- upstream commit: `141eb6fef83422698aef7a981029e843e8161534`
- upstream release: `dsh@0.1.0-rc.8`
- upstream package manager: `pnpm@11.7.0`
- license: MIT, with upstream attribution retained by the submodule

## Build it

Build/bootstrap is explicit:

```sh
bin/build-agentProlog
```

The build command deliberately follows DeepSeek Harness's own built-artifact path instead of inventing a reduced AgentProlog build graph:

1. initialize the pinned DeepSeek Harness submodule;
2. verify the exact audited upstream SHA;
3. select the upstream-pinned `pnpm@11.7.0` through Corepack when available;
4. run the upstream immutable install (`pnpm install --frozen-lockfile`);
5. run the upstream official complete build (`pnpm run build:official`);
6. require DeepSeek's `.dsh-build/client-build-environment.json` record to identify the pinned commit and `official` artifact profile;
7. mount the source-controlled `agentProlog` runtime profile under `DSH_HOME`; and
8. link the local Prolog-backed AgentFactory against the exact pinned DSH core packages.

DeepSeek's complete build owns the Host -> Client -> Web ordering, Typert generation, tsdown output, Vite output, and build-record digest. AgentProlog does not prune that build simply because its runtime profile is headless. Headless is a composition decision at launch time, not a fork of DeepSeek's build system.

The upstream root `postinstall` configures contributor-local Git hooks. This checkout is a pinned submodule rather than a DeepSeek contributor worktree, so dependency installation sets `CI=true`, matching the upstream CI/release behavior where that hook installer intentionally no-ops. Dependency package scripts still run normally.

Building may download Node dependencies and builds the same complete artifact graph used by upstream's official CI/release path. Launching never builds or installs anything.

Set `AGENTPROLOG_DSH_HOME` to override the build/runtime state directory. The default is `$XDG_STATE_HOME/prolog-rlm/deepseek-harness`, falling back to `~/.local/state/prolog-rlm/deepseek-harness`.

## Run it

After building:

```sh
bin/agentProlog "Inspect this project."
```

`bin/agentProlog` is intentionally a thin runtime launcher. It validates the pinned SHA, the upstream official build record, and the AgentProlog profile, then executes the DeepSeek Harness CLI in the `agentProlog` profile. It does not initialize git submodules, run a package manager, install dependencies, create build artifacts, or repair an incomplete build. If prerequisites are missing or stale it fails with an instruction to run `bin/build-agentProlog`.

It accepts normal DSH launcher flags before the task:

```sh
bin/agentProlog --dump-config
bin/agentProlog --help
```

## What remains from DeepSeek Harness

The **runtime** profile is deliberately headless. It retains only the DSH spine needed to host the Prolog-backed agent:

```text
DeepSeek Harness CLI / profile boot
        |
        +-- dsh-session
        +-- dsh-agent registry
        +-- dsh-headless argv startup
        |
        v
@prolog-rlm/dsh-agent-factory
        |
        v
host/bridge-client.mjs
        |
        v
deepseek_prolog_bridge
        |
        v
rlm_conversation + rlm_async
        |
        v
Prolog-owned model / context / tools / authority / effects
```

The stock DSH model route, tool registry, sandbox/permission stack, skills, prompt policy, compaction, pruning, persistence, title generation, subagents, workflows, web search, code runtime, stock agent loop, and stock headless runner are disabled in `profile/cordis.patch.yml`.

The official DeepSeek build still produces its normal complete artifact set. Those browser/web artifacts are simply not mounted by the AgentProlog runtime profile. There is no HTTP server, browser UI, or web bundle in the AgentProlog composition.

## Authority boundary

DeepSeek Harness supplies the host/profile/session/agent interfaces. Prolog-RLM is the canonical agent runtime.

The Harness side must not execute tools, decide permissions, select model context, compact canonical history, or run an independent think-act loop. The replacement Cordis AgentFactory maps the Harness Agent interface onto canonical Prolog sessions and Prolog-owned async runs.

The transport client is intentionally boring. It correlates NDJSON requests and maps a host `AbortSignal` to `run/cancel`. The run itself is an `rlm_async` Future owned by Prolog, so cancellation reaches the actual operation instead of merely hiding its output.

## Infinite-chat semantics

"Infinite" means the canonical conversation transcript is durable, append-only, and never replaced by a summary. It does **not** mean sending an unbounded byte string to a finite-context model.

`rlm_conversation` keeps every turn. For each provider request it compiles a bounded working set and exposes omitted history through the RLM context handle, where it remains searchable and sliceable. DeepSeek Harness compaction plugins are disabled for this profile.

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

- `openrouter` reuses the existing `openrouter_provider/2` implementation and resolves `OPENROUTER_API_KEY` only at request execution time.
- `deepseek` uses the existing OpenAI-compatible provider boundary and resolves `DEEPSEEK_API_KEY` only when selected.

No API key is stored in the settings document. The default route is OpenRouter `openrouter/free`.

## Persistent settings

The default settings path is `$XDG_CONFIG_HOME/prolog-rlm/deepseek-harness.json`, or `~/.config/prolog-rlm/deepseek-harness.json` when `XDG_CONFIG_HOME` is not set.

The default durable canonical conversation store is under `$XDG_STATE_HOME`, falling back to `~/.local/state/prolog-rlm/`.

Supported persisted fields remain intentionally small:

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

Unknown keys are rejected, including attempts to persist API keys.

## Direct bridge debugging

The launcher should be used for normal execution. For bridge debugging only:

```sh
swipl -q -s agentProlog/deepseek-harness/bin/deepseek-prolog-bridge.pl
```

The bridge protocol is one JSON object per line and supports settings, canonical session create/open/list/messages/search/stats, synchronous and asynchronous turns, run status/result, and cancellation.

## Tests

The SWI suite covers settings, provider routing, bridge sessions, persistence across close/reopen, async run cancellation, cleanup, the fail-closed Harness profile, and provider/model provenance.

The Node suite covers NDJSON correlation, cancellation, the Prolog-backed AgentFactory, lossless resume projection, and the real Node -> SWI process boundary.

`.github/workflows/deepseek-harness.yml` checks the explicit build command, verifies that `bin/agentProlog` remains build-free, requires the upstream-pinned pnpm version, runs `build:official`, validates DeepSeek's official build record, tests the exact pinned rc.8 packages and gitlink, composes the headless profile, and boots `bin/agentProlog --help`.

The profile contract test reads the pinned DeepSeek base/headless bundle manifests and verifies that the profile explicitly disables every inherited row except the required DSH spine. A future Harness bump therefore fails closed if upstream adds a new runtime component without an explicit decision here.
