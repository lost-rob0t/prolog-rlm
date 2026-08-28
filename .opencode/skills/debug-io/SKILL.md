---
name: debug-io
description: Debug prolog-rlm provider HTTP IO — OpenRouter requests, attribution headers, live test credentials, and fetching per-generation completion data by generation id. Use when investigating provider errors, 401/timeout failures, request/response payloads, or OpenRouter usage and cost data.
---

# Debugging provider IO in prolog-rlm

## Credentials

- Live-provider tests and scripts need `OPENROUTER_API_KEY`.
- The git-ignored `.env` at the repository root holds it locally; `.envrc`
  loads it via direnv (`direnv allow` once after checkout).
- Never print, commit, or log the key. Errors and traces never contain it.
- A **management-only** key returns `401 "User not found."` on
  `/chat/completions` even though `/auth/key` succeeds; use an
  inference-capable key for live lanes.

## Attribution headers (what OpenRouter sees)

Every `openrouter_provider/2` request sends:

- `X-OpenRouter-Title: prolog-rlm`
- `HTTP-Referer: https://github.com/lost-rob0t/prolog-rlm`
- `User-Agent: prolog-rlm/0.1`

Downstream hosts override identity with `app_title(Title)` /
`app_referer(Referer)` provider-term keys (see `docs/providers.md`).
Deterministic header coverage lives in
`test/rlm_chain_app_attribution_test.pl` using a local HTTP server —
extend that file when changing transport headers.

## Fetch completion data from OpenRouter

Generation ids come from `model_response.response_id` (a `gen-...` string)
visible in completion results, traces, and live-test logs.

```sh
scripts/openrouter_completion.sh <gen-id>            # usage, cost, latency, app_id, origin
scripts/openrouter_completion.sh <gen-id> --content  # stored prompt/completion text
scripts/openrouter_completion.sh --key               # key limits and usage
scripts/openrouter_completion.sh --credits           # remaining credits
```

The script resolves the key from `$OPENROUTER_API_KEY` or `.env` and never
echoes it. `app_id` non-null plus `origin` prove attribution headers arrived.

## Reproducing provider IO deterministically

1. Start from `test/rlm_chain_app_attribution_test.pl` or
   `test/support/completion_final_handoff_support.pl` as the local-server
   pattern: `thread_httpd` server, handler captures headers/payloads, then
   assert on what the transport actually sent.
2. For end-to-end live checks run one focused suite, not the whole paid lane:

```sh
swipl -q -s test/live_openrouter_test.pl -g "run_tests(live_openrouter),halt"
```

3. Fetch the failing generation by id with the script above to see the
   provider-side view (native token counts, finish reason, routed provider,
   moderation/fallback attempts).

## Common failure signatures

- `401 User not found.` → management-only key used for inference.
- `no textual final model output` → final value resolved to a textless
  response channel; inspect `transitions` and the final step expression.
- `plan_parse_failed` with `no_json_object` → truncated or non-JSON root
  output; compare `planner_max_tokens` against completion token counts in
  the generation data.
- `tool_result_envelope_field(Key, Bind)` → one-hop field over a registry
  tool binding; the result nests under the envelope `value` key.
