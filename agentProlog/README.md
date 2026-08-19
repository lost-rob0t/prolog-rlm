# PrologAgent

`PrologAgent` is the planned downstream coding-agent application built on `prolog-rlm`.

It is intentionally separate from the reusable runtime. Core owns model execution, agents, graphs, authority, async work, effects, MCP, traces, and durable state. `agentProlog/` owns the coding workflow, application-facing UI protocol, programmable configuration convention, and terminal/editor UX that combine those pieces into an OpenCode-style tool.

The implementation roadmap lives in [`docs/prolog-agent-roadmap.md`](../docs/prolog-agent-roadmap.md). The renderer-independent frontend contract is documented in [`docs/prolog-agent-ui-v1.md`](../docs/prolog-agent-ui-v1.md). AgentProlog configuration is documented in [`docs/agentprolog-config.md`](../docs/agentprolog-config.md).

## Target experience

A user opens a repository and gives the agent a normal coding task:

```sh
swipl -q -s agentProlog/bin/agent-prolog.pl -- \
  "Fix the failing authority tests and show me the final diff"
```

The coding workflow should then:

1. inspect project instructions and relevant source/tests;
2. search and read files through bounded project tools;
3. propose or perform capability-gated edits;
4. surface mutations through the existing authority boundary;
5. run configured verification;
6. repair failures when allowed;
7. return changed files, verification results, usage, and a trace reference.

The later full-screen terminal client must expose the same workflow through `prolog_agent_ui_v1` rather than implementing a second execution path.

```text
> add a timeout to the MCP request path

Reading project instructions...
Searching MCP transport...
Editing 2 files

Diff ready: +24 -7
[a] allow once  [s] allow session  [p] allow project  [d] deny

Focused tests       PASS
Deterministic gate  PASS

Done. Trace: run_42
```

## Architecture

```text
JS TUI / CL / Nim / Emacs / Lem
              |
              v
       prolog_agent_ui_v1
 snapshots + ordered events + commands
              |
              v
      AgentProlog UI facade
              |
              v
         coding workflow
              |
        +-----+-----------------------+
        |                             |
 project tool pack            authority / verify
              |
              v
        prolog-rlm runtime
```

Prolog remains authoritative. Frontends render bounded canonical snapshots, consume ordered semantic events, negotiate presentation capabilities, and issue correlated commands. They do not execute tools, implement permissions, reconstruct domain state from raw traces, or become alternate agent runtimes.

The first reference transport is one-record-per-line UTF-8 NDJSON over a child `swipl` process. Transport is intentionally abstract from protocol semantics so a Unix/local socket can be added without changing the records.

The deterministic fixture server can be exercised with:

```sh
swipl -q -s agentProlog/bin/prolog-agent-ui-fixture.pl
```

The golden polyglot session is `agentProlog/fixtures/prolog_agent_ui_v1_session.ndjson`.

## Configuration

AgentProlog has one configuration runtime with two inputs: executable XDG `config.prolog` and JSON. Prolog is primary and deliberately programmable, closer to an Emacs init file than a static preferences document.

The user default is:

```text
$XDG_CONFIG_HOME/prolog-rlm/agentProlog/config.prolog
```

A user config may define ordinary Prolog helpers and rules:

```prolog
preferred_model("openrouter/free").
setting(model, Model) :- preferred_model(Model).
```

It may also import JSON with `json/1` or `include_json/1`, then override those values in Prolog.

Project configuration uses `<project-root>/.agentprolog/config.prolog` with a JSON fallback. Repository-local executable config is discovered but **not executed until that explicit structured project identity is trusted**. Once trusted, it is real Prolog host extension code too.

AgentProlog-mediated config writes are privileged file mutations. Frontends must cross the normal authority path before editing them, and AgentProlog rewrites leave config files at mode `0600`.

## Security boundary

Trusted executable configuration is host code and has the privileges of the AgentProlog process. Project-config trust is therefore a real code-trust decision, not a decorative preference toggle.

That does not turn registered tools into ambient authority. Loading coding tools does not grant their capabilities, and tool invocation still uses the canonical schema, authority, confinement, cancellation, budget, and durable-effect boundaries.

No ambient shell is required for the first release. File edits should use confined write/patch tools, and test commands should come from trusted configured profiles rather than arbitrary model-generated shell strings.

Persistent project approval, when implemented, is a bounded remembered operator decision. It is not persistent `allow_session`, not `dangerous`, and never bypasses capability, confinement, budget, cancellation, or effect accounting.

The UI protocol does not weaken this boundary. A client command is a request to the authoritative runtime, not permission to invoke a mutation handler directly.

## Status

The core agent/runtime substrate exists. `agentProlog/` is not yet a complete runnable coding agent or rich TUI.

The `prolog_agent_ui_v1` foundation defines the renderer-independent snapshot/event/command boundary, deterministic replay semantics, request correlation, reconnect behavior, NDJSON encoding, a child-process fixture server, golden fixtures, and stress coverage.

The AgentProlog configuration track is split under #126. #127 establishes executable Prolog-first configuration, JSON import, project trust, config-generation provenance, and `0600` writes. #128-#131 cover hooks/extensions, config-defined tools, error/loop detectors, and DeepSeek Harness configuration integration.

The headless coding workflow and concrete project tool pack still remain product dependencies. Update the roadmap in the same PR whenever implementation materially changes readiness or dependencies.
