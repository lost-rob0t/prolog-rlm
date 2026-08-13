# prolog-rlm examples

Run these from the repository root.

## 1. Credential-free runtime walkthrough

```sh
swipl -q -s bin/prolog-rlm.pl -- demo
```

This exercises opaque context, a capability-gated tool, adaptive recursion, supervised agents, graph checkpoint/resume, and the version-neutral MCP facade.

## 2. External context

```sh
swipl -q -s bin/prolog-rlm.pl -- demo context --view
```

Or use external context in a real RLM call:

```sh
export OPENROUTER_API_KEY='...'

swipl -q -s bin/prolog-rlm.pl -- rlm \
  "What token is present?" \
  --context "The token is EXAMPLE_CONTEXT_42."
```

## 3. Capability-gated tool use

```sh
swipl -q -s bin/prolog-rlm.pl -- demo tool --json
```

The demo invokes the production `project_read` tool under `tool(project_read)` and reads only the repository test fixture.

## 4. Adaptive recursion

```sh
swipl -q -s bin/prolog-rlm.pl -- demo recursion --view
```

For a credentialed recursive model call:

```sh
swipl -q -s bin/prolog-rlm.pl -- rlm \
  "Answer using the supplied context." \
  --context "42 is the answer in this example." \
  --trace /tmp/rlm-example.json
```

## 5. Graph resume

```sh
swipl -q -s bin/prolog-rlm.pl -- graph \
  --trace /tmp/graph-example.json

swipl -q -s bin/prolog-rlm.pl -- trace-view /tmp/graph-example.json
```

The graph interrupts for approval, persists an in-memory checkpoint, resumes, and exposes history events.

## 6. MCP interoperability

```sh
swipl -q -s bin/prolog-rlm.pl -- mcp --json
```

This exercises the version-neutral canonical command surface shared by the 2025 and 2026 MCP adapters.

## 7. Hosted OpenRouter direct completion

```sh
export OPENROUTER_API_KEY='...'

swipl -q -s bin/prolog-rlm.pl -- direct \
  "Reply with HOSTED_OK" \
  --model openrouter/free
```

## 8. Local OpenAI-compatible completion

No credential:

```sh
swipl -q -s bin/prolog-rlm.pl -- direct \
  "Reply with LOCAL_OK" \
  --endpoint http://127.0.0.1:8000/v1/chat/completions \
  --model local-model \
  --no-credential
```

Credential from an environment variable:

```sh
export LOCAL_LLM_KEY='...'

swipl -q -s bin/prolog-rlm.pl -- direct \
  "Reply with LOCAL_OK" \
  --endpoint https://llm.example/v1/chat/completions \
  --model hosted-compatible-model \
  --credential-env LOCAL_LLM_KEY
```

## 9. JSONL trajectory export

```sh
swipl -q -s bin/prolog-rlm.pl -- demo agent \
  --trace /tmp/agent-example.jsonl \
  --trace-format jsonl

swipl -q -s bin/prolog-rlm.pl -- trace-view /tmp/agent-example.jsonl \
  --trace-format jsonl
```

See `docs/cli-demo-traces.md` for the trace schema, budgets, capability boundaries, and failure semantics.
