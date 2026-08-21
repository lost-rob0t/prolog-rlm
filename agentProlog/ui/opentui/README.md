# PrologAgent OpenTUI reference client

This is the first renderer for `prolog_agent_ui_v1`. It is intentionally a thin client: Prolog owns execution, tools, authority, verification, session state, sequence numbers, and reconnect semantics. The TypeScript code validates protocol records, maintains bounded presentation state from canonical snapshots/events, sends correlated commands, and renders them.

## Run the deterministic fixture

Requirements: Bun, SWI-Prolog, and the packages pinned in `package.json`.

```sh
cd agentProlog/ui/opentui
bun install
bun run dev
```

The client spawns `agentProlog/bin/prolog-agent-ui-fixture.pl`, negotiates `prolog_agent_ui_v1`, receives the canonical checkpoint snapshot plus ordered resume events, and renders the resulting coding session.

Keys:

- `q` / `Esc`: close the fixture client;
- `c`: request session cancellation;
- `1`/`2`/`3`: select an advertised pending approval choice;
- `1`/`2`: select an advertised pending question choice.

Those keys do not implement authority policy. They send the choice strings already advertised by the authoritative protocol state.

## Checks

```sh
bun run typecheck
bun run test:ci
```

Tests include canonical golden replay, duplicate/gap behavior, required-extension failure, UTF-8 snapshot bounds, request correlation, real child-`swipl` transport, and OpenTUI's in-memory `testRender` path.

The transport is isolated behind `NdjsonTransport`; a future Unix/local socket client should implement that interface without changing protocol/reducer semantics.
