# Managed-turn cleanup verification

Verified locally on 2026-10-18 with SWI-Prolog 9.2.9 installed into an isolated
workspace toolchain (Debian packages, library index generated). This is not a
Nix build or a live-provider result.

- Full deterministic corpus: 104 suites, 1290 tests, 1290 passed, zero failed,
  timed out, blocked or fixme.
- Runtime version and static module-load checks passed.
- Deterministic benchmark: 16/16 passed. Deep experiment: 15/15 passed.
  Benchmark model usage is fixture data, not paid-provider measurement.
- CLI `demo --json` passed; `git diff --check` passed.
- Reproduced before fixes: partial warm ranges skipped an uncovered prefix;
  managed native strategy was ignored; inconsistent provider totals undercounted
  known components; unknown usage could mask a known aggregate overrun.
- New tests cover native managed history, partial-summary gaps, no compaction
  spending for 300 short messages, actual context-pressure publication,
  cumulative 8797/8192 execution accounting, and partial usage/cost enforcement.
- Existing 40000-message cold retrieval fixture passes. Complete durable source
  history remains available independently of the bounded solver projection.

Live OpenRouter, Nix packaging, and concurrent warm-publication races were not
verified here. Context counts are estimates unless a trusted counter is supplied;
output caps are not exact input-plus-output token reservations. The pending new
user message is not included in the pre-turn compaction pressure check.
