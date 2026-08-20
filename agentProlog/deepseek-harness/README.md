# DeepSeek Harness PrologAgent path

This directory hosts the DeepSeek Harness GUI and headless surfaces for PrologAgent. DeepSeek Harness provides the shell, transport, session/agent interfaces, and browser client. Prolog-RLM remains the canonical agent runtime.

The official `deepseek-ai/deepseek-harness` repository is pinned at `upstream/` as a git submodule:

- upstream commit: `141eb6fef83422698aef7a981029e843e8161534`
- upstream release: `dsh@0.1.0-rc.8`
- upstream package manager: `pnpm@11.7.0`
- license: MIT

## Developer environment

The repository root declares `pnpm@11.7.0`. A `packageManager` field selects a pnpm version but does not install a `pnpm` executable by itself.

On NixOS, enter the repository development shell:

```sh
nix develop
pnpm --version
```

The checked-in `flake.nix` supplies Node 24, Corepack's pnpm shim, SWI-Prolog, git, pkg-config, and tree-sitter. Corepack reads the root `packageManager` field and resolves pnpm 11.7.0.

If Node/Corepack are already installed and a persistent user-level shim is preferred, create it once in a writable directory already on `PATH`:

```sh
mkdir -p "$HOME/.local/bin"
corepack enable pnpm --install-directory "$HOME/.local/bin"
hash -r
pnpm --version
```

## Normal development commands

Run these from the `prolog-rlm` repository root:

```sh
pnpm run build
pnpm run dev
pnpm run start
pnpm run headless -- "Inspect this project."
```

`pnpm run build` is the one bootstrap/build command. `pnpm run start` launches the built DeepSeek Web GUI. `pnpm run headless` runs the one-shot headless surface. `pnpm run dev` launches the GUI together with DeepSeek's own `dev:web` watcher.

DeepSeek's watcher requires one successful full build first. It incrementally watches the client TypeScript, client bundles, and Web dist; it does not replace the initial build.

For filesystems where native watch events are unreliable, set `AGENTPROLOG_DEV_POLL=true` or a positive millisecond interval such as `AGENTPROLOG_DEV_POLL=500` before `pnpm run dev`.

The `bin/` scripts are implementation details behind these package scripts. Normal development should use the root pnpm commands.

## Build contract

The pinned submodule is the audited source reference, not the build worktree. DeepSeek's root postinstall configures worktree-local Git hooks, which is incompatible with a git submodule's `core.worktree` layout. The build therefore creates a disposable standalone local checkout under AgentProlog state and runs DeepSeek's upstream commands there unchanged:

```sh
pnpm install --frozen-lockfile
pnpm run build:official
```

The build uses DeepSeek's full Host -> Client -> Web graph and validates its `.dsh-build/client-build-environment.json` record. It does not invent a reduced AgentProlog build.

The build checkout defaults to `$XDG_STATE_HOME/prolog-rlm/deepseek-harness/upstream-build`, falling back to `~/.local/state/prolog-rlm/deepseek-harness/upstream-build`. Set `AGENTPROLOG_DSH_HOME` to override the surrounding state directory.

## Runtime surfaces

Both surfaces mount the same Prolog-backed Cordis `AgentFactory`:

```text
DeepSeek Web GUI                 DeepSeek headless
       |                               |
       +-------------+-----------------+
                     |
              dsh-agent registry
                     |
          @prolog-rlm/dsh-agent-factory
                     |
             bridge-client.mjs
                     |
          deepseek_prolog_bridge
                     |
          rlm_conversation + rlm_async
                     |
             Prolog-RLM authority
```

The Web profile retains the DSH services the browser/API structurally requires, but stock model providers, the stock agent loop, stock tool executors, compaction, subagent drivers, workflow drivers, and competing persistence/settings authority are disabled. GUI controls whose semantics are not yet backed by Prolog are hidden rather than wired to a second runtime.

The headless profile keeps only the DSH Agent/Session spine and argv startup needed to drive the same Prolog factory.

A missing or invalid Prolog bridge fails closed. Neither surface may silently fall back to a generic DeepSeek Harness agent.

## Infinite-chat semantics

"Infinite" means the canonical transcript is durable, append-only, and never replaced by a summary. It does not mean sending an unbounded byte string to a finite-context model.

`rlm_conversation` retains every turn. Provider requests receive a bounded working projection, while omitted history remains searchable and sliceable through the RLM context APIs. DeepSeek Harness compaction and pruning are disabled as canonical history semantics.

Persisted settings hard-require:

```json
{
  "driver": "prolog-rlm",
  "history_mode": "lossless_rlm",
  "compaction": false
}
```

## Providers and settings

Provider execution remains in Prolog-RLM. OpenRouter is the default route; direct DeepSeek uses the existing OpenAI-compatible provider boundary when selected. Credentials are resolved from the environment at execution time and are never persisted.

The default settings path is `$XDG_CONFIG_HOME/prolog-rlm/deepseek-harness.json`, falling back to `~/.config/prolog-rlm/deepseek-harness.json`.

## Direct bridge debugging

For bridge debugging only:

```sh
swipl -q -s agentProlog/deepseek-harness/bin/deepseek-prolog-bridge.pl
```

Normal users should not need the bridge or launcher internals.

## Tests

```sh
pnpm run test
pnpm run test:bridge
pnpm run check
```

The SWI suite covers settings, provider routing, sessions, persistence, cancellation, profile fencing, and provenance. The Node suite covers transport correlation, cancellation, the Prolog-backed AgentFactory, resume projection, and the real Node -> SWI boundary. CI installs pnpm 11.7.0 explicitly, verifies the version before building, builds through `pnpm run build`, composes both profiles, and smoke-tests the Web GUI without opening a browser.
