# DeepSeek Harness PrologAgent path

This path keeps DeepSeek Harness as the headless host substrate while Prolog-RLM remains the only semantic agent runtime.

Pinned upstream:

- `deepseek-ai/deepseek-harness` commit `141eb6fef83422698aef7a981029e843e8161534`
- `dsh@0.1.0-rc.8`
- MIT license

## Run it

From the repository root:

```sh
export OPENROUTER_API_KEY='...'
bin/agentProlog "Inspect this repository and report the failing tests."
```

The first run initializes the pinned git submodule if needed, installs the upstream workspace with its committed pnpm lockfile, builds that exact Harness revision, mounts the source-controlled `agentProlog` profile, and launches the DeepSeek headless CLI. Later runs reuse the build while the pinned upstream SHA is unchanged.

Useful non-model commands:

```sh
bin/agentProlog --help
bin/agentProlog --dump-config
```

`AGENTPROLOG_DSH_HOME` overrides the generated Harness state directory. Otherwise it lives under `$XDG_STATE_HOME/prolog-rlm/deepseek-harness`, falling back to `~/.local/state/prolog-rlm/deepseek-harness`.

Requirements are Node >= 22.19, Corepack, SWI-Prolog, and Git.

## Runtime boundary

The active DeepSeek Harness profile is deliberately tiny:

```text
DeepSeek headless argv startup
            |
            v
DSH Agent registry + Session event log
            |
            v
@prolog-rlm/dsh-agent-factory
            |
            v
NDJSON bridge -> Prolog-RLM
            |
            v
rlm_conversation + rlm_async
            |
            v
providers / context / tools / authority / effects / tracing
```

The profile keeps only three upstream runtime rows enabled: `agent`, `session`, and `headless-startup`. The stock DSH headless runner is disabled and replaced by `@prolog-rlm/dsh-agent-factory/headless`.

Everything that could become a second semantic owner is disabled, including DSH model routing, prompts, tools, filesystem effects, permissions, skills, commands, compaction, pruning, session persistence, titles, subagents, workflows, web search, telemetry, and the stock agent loop. Provider execution remains inside Prolog-RLM.

The deterministic profile test reads the pinned upstream `dsh-base` and `dsh-headless` bundle patches and proves every row except the three allowed spine rows is disabled. A later Harness upgrade therefore fails closed if it introduces another runtime row.

## Conversation and provider semantics

The canonical transcript is append-only and lossless. DeepSeek Harness Session events are only a projection for the host surface; Prolog owns durable conversation state.

Persisted Prolog settings require:

```json
{
  "driver": "prolog-rlm",
  "history_mode": "lossless_rlm",
  "compaction": false
}
```

The default route is `openrouter` / `openrouter/free`, resolved through `OPENROUTER_API_KEY`. Direct DeepSeek routing remains available through the existing OpenAI-compatible Prolog provider and `DEEPSEEK_API_KEY`. Credentials are never persisted in the Harness profile.

## Bridge

The lower-level NDJSON bridge remains available for debugging:

```sh
swipl -q -s agentProlog/deepseek-harness/bin/deepseek-prolog-bridge.pl
```

It exposes settings, session create/open/list/messages/search/stats, synchronous and asynchronous turns, run status/result, and real cancellation. The Node host client only frames requests and projects DSH events; it does not execute model or tool semantics.

## Verification

`.github/workflows/deepseek-harness.yml` now gates the same runnable path as users:

1. verifies the executable launcher and exact rc.8 source packages;
2. runs Node transport, factory, and headless-runner tests;
3. runs the real Node -> SWI-Prolog bridge integration;
4. runs the deterministic Prolog suite;
5. invokes `bin/agentProlog --dump-config` to compose the actual headless profile;
6. invokes `bin/agentProlog --help` without provider credentials;
7. verifies the pinned submodule gitlink and checked-out SHA.

Streaming, approvals/questions, steering, tools, subagents, verification, and richer events remain future adapter work. They must first exist as canonical Prolog semantics before the DeepSeek adapter can expose them.
