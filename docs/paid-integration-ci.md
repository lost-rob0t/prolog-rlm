# Explicit paid integration testing

Both `Paid OpenRouter` and the `CI` workflow's REAL OpenRouter job run provider
integration tests only on `workflow_dispatch`. Pushes and pull requests do not
admit paid calls. Their shared concurrency group prevents overlapping jobs in
this repository. Keep the existing live suites: deterministic fake providers
are useful regressions but are not live-provider evidence.

Before dispatching either workflow, configure:

- secret `OPENROUTER_API_KEY`: a dedicated CI key with a finite provider credit
  cap, no periodic limit reset, and BYOK spending included in the limit;
- variable `OPENROUTER_TEST_MODEL`: an explicit paid model identifier;
- variable `OPENROUTER_TEST_BUDGET_USD`: the positive finite spending allowance
  for this invocation. The key's remaining credits must not exceed it.

The shared `scripts/openrouter_ci_preflight.py` checks configuration and reads
`https://openrouter.ai/api/v1/key` before any generation tests. Missing, invalid,
unlimited, resetting, exhausted, or unverifiable caps fail the job. The script
never creates credentials or raises a provider limit. Existing per-test token,
call, and cost budgets remain in force; they do not represent a workflow-wide
spending cap. Provider-side accounting/enforcement governs the key cap, and this
preflight does not promise an exact-dollar bound on in-flight final charges.
Do not use the dedicated key concurrently outside these serialized CI jobs.

Run the preflight regression tests without credentials or network:

```sh
python3 test/openrouter_ci_preflight_test.py
```

An undispatched or unconfigured live lane is **unrun**, not passing. Applicable
live merge gates in AGENTS.md still require successful live evidence for the
reviewed head. Changing the trigger does not waive that gate. Record the exact
head and workflow run when live validation is available.
