# AGENTS.md

These instructions apply to the entire repository unless a more specific nested `AGENTS.md` overrides them.

## Repository mission

`prolog-rlm` is a reusable SWI-Prolog RLM/agent runtime. Keep core domain-neutral. The language model may choose semantic strategy; Prolog owns execution semantics, validation, budgets, authority, persistence, cancellation, tracing, and effect accounting.

Do not turn core into a coding-agent product, a concrete tool catalog, or an ambient shell/network/filesystem runtime.

## Before changing code

1. Start from the latest `main` and inspect the actual repository state before trusting old prompts or issue text.
2. Read the relevant issue, all issue comments, recent related PRs/commits, applicable docs/research, source, and tests.
3. Search for existing architecture before inventing a parallel subsystem. Reuse established modules and public contracts.
4. When an ADR/ADARD/research/design record exists for the area, treat it as design input and reconcile it with current executable code/tests.
5. Keep the change to one coherent issue slice. Do not opportunistically absorb unrelated backlog.

## Development workflow

Use test-driven development for behavioral changes:

1. add or strengthen a test that expresses the required invariant or reproduces the bug;
2. confirm the test is meaningful and fails for the intended reason when practical;
3. implement the smallest coherent runtime change;
4. run focused tests repeatedly while developing;
5. run the complete deterministic suite before considering the slice complete;
6. inspect failures as evidence and fix root causes rather than weakening tests or substituting an easier check.

Tests must exercise externally meaningful behavior, not merely internal implementation details. For concurrency/race tests use deterministic barriers, queues, mutexes, or other synchronization. Do not use sleeps as correctness synchronization.

For crash/restart semantics, prefer fresh SWI-Prolog process fixtures. When a side effect is under test, use an externally observable counter/state so duplicate execution is detectable independently of the local ledger.

## Core architectural invariants

Preserve these unless the task explicitly changes them with tests and design evidence:

- SWI-Prolog is the runtime; Python is not a production runtime dependency.
- Model output never gains unrestricted `call/1`, arbitrary executable Prolog, ambient shell, filesystem, network, process, or repository authority.
- Tool/schema availability is separate from capability possession. Loading tools or MCP declarations does not grant permission to invoke them.
- Child capabilities and verifier requirements narrow by default; they do not silently widen.
- Reuse the existing `rlm_async` scheduler. Do not create a second scheduler or one-thread-per-Future design.
- Canonical latency-bearing execution direction is `*_execute -> Future -> synchronous facade awaits the same Future`. Code already running inside a bounded async worker calls the trusted execute ABI directly rather than nesting Future waits.
- Reuse the existing #53 authority boundary. The canonical authority tiers are exactly `approve_diff`, `allow_once`, `allow_session`, and `dangerous`. Do not invent `authority_v2`, persist `allow_session`, or let `dangerous` bypass hard validation/capability/confinement/accounting rules.
- Durable artifacts, graph checkpoints, MCP configuration, context observations, effect observations, and trusted operator policy are distinct semantic classes. Do not collapse them into one generic fact bucket merely because Prolog makes that temptingly easy.
- Preserve structured outcomes, provenance, usage, trace lineage, and cancellation semantics across wrappers.

## External-effect invariant

Externally effectful canonical execution must use the durable effect boundary rather than relying on Prolog control flow for once-only behavior.

The intended order is:

```text
normalize executable operation
-> schema / capability / hard policy
-> host authority decision
-> durable effect attempt admission
-> durable dispatch intent
-> external adapter boundary
-> authoritative observation OR conservative uncertainty
```

Ordinary Prolog backtracking, repeated awaits, callbacks, wrapper reconstruction, or process restart must not implicitly resubmit an admitted external attempt.

A retry or resample is an explicit new linked attempt with fresh authority semantics as required. A changed executable payload requires fresh normalized identity. `abandoned` is terminal state, not retry authorization.

Adapter identity, store namespace, execution epoch, logical-call identity, attempt lineage, and provider idempotency identity are trusted runtime data. Caller/model metadata must not override them.

Transport failure after durable dispatch is not proof that the remote effect did not happen. If reconciliation cannot prove an outcome, remain conservative/indeterminate instead of silently submitting again.

Do not claim generic provider-level exactly-once behavior unless the external protocol actually supplies the required idempotency/reconciliation guarantee.

## Effect-store compatibility

Never silently migrate a non-empty legacy effect journal.

Legacy PR-#78 journals require the explicit offline migration flow documented in `docs/effect-migration.md`. Migration must remain non-effectful: it must not submit, cancel, or reconcile provider work, and it must never guess unresolved adapter identity. In-place replacement requires the documented verified backup behavior.

## Verification commands

Baseline deterministic commands from a clean checkout:

```sh
swipl -q -s test/check_runtime.pl
swipl -q -s test/load_all.pl
swipl -q -s test/run_tests.pl
swipl -q -s benchmark/run.pl -- deterministic
swipl -q -s benchmark/run.pl -- deep-experiment
swipl -q -s bin/prolog-rlm.pl -- demo --json
git diff --check
```

Also run any focused fixtures introduced or touched by the change, including fresh-process restart/crash fixtures where relevant.

GitHub Actions is the canonical full gate. It also runs static loading, deterministic conformance, CLI/trace smoke, persistent graph/artifact restart checks, and the credentialed REAL OpenRouter lane. Fake providers never count as live-provider evidence.

Do not edit CI to hide a product failure, remove a required gate, or convert a failing required check into an informational success unless the issue explicitly requires a justified CI-contract change.

## Git and PR discipline

- Canonical branch: `main`.
- Create issue-scoped work from the current `main` unless the task explicitly says otherwise.
- Keep commits reviewable and semantically coherent.
- Do not rewrite `main` or force-push shared history.
- Never commit credentials, provider secrets, generated private data, or local environment artifacts.
- Update docs when public behavior, guarantees, migration requirements, or operator workflow changes.
- PR descriptions must state the runtime invariant implemented, important non-goals, tests/evidence, and remaining follow-up scope.
- Do not close a parent issue merely because a substrate landed if canonical adoption remains unfinished.
- If the task explicitly says to merge on green, merge only the exact reviewed head after all required deterministic and live gates are green and review blockers are resolved. Otherwise stop at the requested branch/PR boundary.

## Completion standard

A plan, partial implementation, local-only happy path, or worker self-report is not completion when an observable gate exists.

Completion means the requested behavior exists in the canonical architecture, adversarial/edge cases are covered, required deterministic checks pass, required live/provider checks pass when applicable, docs accurately state the guarantee boundary, and no known failing review/CI blocker is being hand-waved into tomorrow.