# Scripted HTTP conformance (#510)

The first bounded slice uses `test/support/scripted_http_support.pl` to run the
unchanged production OpenAI-compatible HTTP client and native direct loop against
an isolated IPv4 loopback server. Only remote replies are scripted. No
`model_handler`, provider credential, external network, or paid model is involved.

Run the focused lane with:

```sh
swipl -q -s test/rlm_direct_http_test.pl -g 'run_tests(rlm_direct_http),halt'
```

The suite is included in the canonical deterministic inventory and existing PR
CI. It checks the request path, model, projected tool schema, serialized call
arguments, assistant/tool ordering, correlated result IDs, retained result lookup,
final text and aggregate token usage. The fixture registers the existing typed
counting-write tool, grants a synthetic host context `allow_session`, opens a
temporary durable effect store, and checks a separate mutation counter and value.
The write occurs once; asking again with a fresh call ID fails replay admission.
This is local runtime effect evidence, not generic provider exactly-once evidence.

Negative cases cover missing approval, missing capability, unknown tool, malformed
arguments, invalid schema value, malformed/duplicate call IDs and exhausted tool
budget. HTTP 429/503 with Retry-After produce one bounded request and structured
failure; the current client does not implement automatic Retry-After retries.
Request expectation failures propagate from the server thread to the test thread.
Every server stops and its exact loopback port is independently rebound after
both successful and failed scenarios. The fixture has one HTTP worker, a 16-turn
script limit, a 64 KiB request limit, a two-second transport timeout and a
ten-second scenario deadline. Correctness synchronization uses no sleeps.

Issue #510 remains open. This slice does not claim the issue's full acceptance:
multi-call/interleaved batches, missing results, cancellation and timeout barriers,
disconnects around submission, outcome-unknown handling, real socket SSE with
Unicode/fragmented/truncated/malformed events, duplicate finish/usage checks,
seeded generated scenarios, stress mode and minimized failure transcripts remain
follow-up work. The required manual real-provider release lane is unchanged;
scripted protocol evidence never establishes model quality or product acceptance.
