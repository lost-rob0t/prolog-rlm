# Model providers

`rlm_chain` exposes provider-neutral model completion through:

```prolog
model_complete(+Provider, +Request, -Outcome).
```

`Outcome` is either `ok(model_response{...})` or `error(provider_error{...})`.
Provider and transport failures are data; callers do not need to parse raw HTTP
exceptions.

## OpenRouter

OpenRouter is the first production OpenAI-compatible backend.

```prolog
?- rlm_chain:openrouter_provider('openrouter/free', Provider).
Provider = provider(openrouter,
                    [endpoint('https://openrouter.ai/api/v1/chat/completions'),
                     credential(env('OPENROUTER_API_KEY')),
                     model('openrouter/free'),
                     timeout(30),
                     address_family(inet),
                     app_title('prolog-rlm'),
                     app_referer('https://github.com/lost-rob0t/prolog-rlm')]).
```

The provider term stores only the environment-variable reference. The key is
resolved with `getenv/2` at request execution time and is never added to model
responses, errors, traces, fixtures, or logs.

App attribution is descriptive identity, never authority: every OpenRouter
request from `openrouter_provider/2` carries
`X-OpenRouter-Title: prolog-rlm` and
`HTTP-Referer: https://github.com/lost-rob0t/prolog-rlm` so the runtime is
identifiable in OpenRouter rankings and per-generation analytics. Downstream
products may set their own identity by building a provider term with
`app_title(Title)` and `app_referer(Referer)` (nonempty atom or string;
invalid values fail closed as a `configuration_error` before any network
I/O). Generic OpenAI-compatible endpoints send no attribution headers unless
a host opts in with the same keys.

If `OPENROUTER_TEST_MODEL` is unset or empty, `default_openrouter_model/1`
returns `openrouter/free`.

OpenRouter uses IPv4 explicitly. SWI-Prolog applies its HTTP timeout only after
the TCP connection is established, so automatic address selection can hang on
a non-functional IPv6 route without reaching the configured timeout. Generic
OpenAI-compatible provider terms default to `address_family(auto)`; trusted
callers may add `address_family(inet)` or `address_family(inet6)` when their
network requires a specific family.

A minimal request is:

```prolog
Request = model_request{
              messages:[message{role:user, content:"Reply with OK."}],
              options:_{max_tokens:32}
          },
rlm_chain:model_complete(Provider, Request, Outcome).
```

The initial generation-option allow-list includes `max_tokens`,
`max_completion_tokens`, `temperature`, `top_p`, `seed`, `stop`, `tools`,
`tool_choice`, and `response_format`.

### Provider/model tool-choice compatibility

Provider configuration may declare a host-owned restriction such as:

```prolog
provider(openrouter,
         [ endpoint(...),
           credential(env('OPENROUTER_API_KEY')),
           model('vendor/model'),
           tool_choice_modes([auto])
         ])
```

`tool_choice_modes/1` is compatibility data, not an authority grant. Its value
must be a non-empty unique subset of `none`, `auto`, and `required`. If the
option is absent, the runtime preserves historical OpenAI-compatible behavior.

When a trusted profile permits only `auto`, a simple request for `required` is
normalized to `auto` before either streaming or non-streaming HTTP dispatch.
Providers whose profile includes `required` preserve it exactly. Other
unsupported requests, including a specific-function selector under an
`[auto]`-only profile, fail with a structured pre-dispatch capability error
rather than silently weakening the caller's intent. Malformed compatibility
configuration likewise fails before credential resolution or network effects.

This profile is supplied by trusted host/provider configuration. Model-produced
request data cannot select it, widen it, or gain tool capability, execution
authority, or effect permission from it.

## Other OpenAI-compatible endpoints

Use `openai_compatible_provider/4`:

```prolog
rlm_chain:openai_compatible_provider(
    'https://example.invalid/v1/chat/completions',
    env('EXAMPLE_API_KEY'),
    'example/model',
    Provider).
```

For a local endpoint that requires no credential, pass `none`. Resolved/raw
credentials are intentionally rejected as configuration. Model-provider HTTP
requests use `User-Agent: prolog-rlm/0.1` by default. A host can identify its
own integration by adding `user_agent(Name)` to the provider configuration:

```prolog
Provider = provider(openai_compatible,
                    [endpoint(Endpoint),
                     credential(env('EXAMPLE_API_KEY')),
                     model(Model),
                     user_agent('agentProlog/1.0')]).
```

`user_agent/1` applies to non-streaming and streaming Chat Completions and to
the Responses and Anthropic Messages adapters. It must be a nonempty atom
or string without control characters; invalid values fail before network I/O.
This descriptive identity grants no capability or authority.

## Z.AI Coding Plan

`zai_coding_provider/3` selects the dedicated Coding Plan endpoint for each
supported wire protocol while retaining the same provider-neutral
`model_complete/3` result contract:

```prolog
zai_coding_provider(chat_completions, 'glm-5.3', ChatProvider),
zai_coding_provider(responses, 'glm-5.3', CodexProvider),
zai_coding_provider(anthropic_messages, 'glm-5.3', ClaudeProvider).
```

The named conveniences select the protocol used by the corresponding coding
tool:

```prolog
zai_codex_provider('glm-5.3', CodexProvider),
zai_claude_provider('glm-5.3', ClaudeProvider).
```

All constructors retain `credential(env('ZAI_API_KEY'))`; the secret is
resolved only when an HTTP request executes. They use Z.AI's documented Coding
Plan endpoints:

| Constructor protocol | Wire protocol | Request endpoint |
| --- | --- | --- |
| `chat_completions` | OpenAI Chat Completions | `https://api.z.ai/api/coding/paas/v4/chat/completions` |
| `responses` | OpenAI Responses (Codex) | `https://api.z.ai/api/v1/responses` |
| `anthropic_messages` | Anthropic Messages (Claude) | `https://api.z.ai/api/anthropic/v1/messages` |

Chat Completions reuses the existing completion and SSE implementation.
Responses and Anthropic Messages currently support non-streaming completion,
including canonical function tools, correlated tool results, usage, errors,
reasoning controls, and provider-native reasoning/thinking block replay.
Calling `model_stream/4` with `zai_codex` or `zai_claude` fails explicitly with
`capability_denied`; their distinct streaming event protocols are not emulated
from a completed response.

Anthropic requires `max_tokens`; `zai_claude_provider/2` supplies a host-owned
default of 4096 when neither canonical max-token option is present. A manually
constructed provider can change it with `default_max_tokens/1`. The adapter
rejects interspersed system messages, malformed tool history, unsupported
protocol options, and non-object Anthropic tool arguments before network I/O.

Z.AI controls Coding Plan entitlement, supported models, and quota. Use a key
issued for the applicable Individual or Team Coding Plan and confirm that the
intended client/integration is permitted by the current Z.AI plan terms. The
deterministic suite validates wire behavior against loopback HTTP fixtures; it
does not claim live account or quota conformance.

## Claude API

The official [Anthropic Messages API](https://platform.claude.com/docs/en/api/messages/create)
uses a Console API key, `X-Api-Key`, and `anthropic-version`. Construct it with:

```prolog
?- rlm_chain:claude_api_provider('your-claude-model', Provider).
Provider = provider(claude_api,
                    [endpoint('https://api.anthropic.com/v1/messages'),
                     credential(env('ANTHROPIC_API_KEY')),
                     model('your-claude-model'),
                     timeout(30),
                     default_max_tokens(4096)]).
```

The key is resolved only at dispatch and sent as `X-Api-Key`. The provider
shares the Anthropic Messages request and response adapter with Z.AI's Claude
protocol, while keeping a distinct provider identity and credential source.
Non-streaming text and tool calls are supported. `model_stream/4` returns
`capability_denied` until Anthropic's native event stream is implemented.
Model-specific options still depend on the selected model. This constructor
does not use a Claude subscription, and deterministic loopback tests do not
establish live Claude account conformance.

## CI test classes

Normal CI runs deterministic PlUnit tests with both OpenRouter environment
variables blank. These tests exercise validation, normalization, provider
capability denial, structured HTTP/provider failures, timeout classification,
and secret redaction without making network requests.

The separate `REAL OpenRouter integration` job runs only for trusted same-repo
pull requests, pushes to `main`, and manual workflow dispatch. It receives the
repository secret `OPENROUTER_API_KEY` and repository variable
`OPENROUTER_TEST_MODEL`. The full live runner includes the 40,000-message scale
acceptance, which requires that variable to name a pinned paid model and
rejects `openrouter/free` and `*:free`. A missing credential or paid model pin
is a hard failure on that trusted path.

The live smoke test performs a real HTTPS request through the production
`rlm_chain` path. It has no fake-provider fallback. Its log prints only safe
evidence: provider, requested model, selected model, HTTP status, whether a
response was received, and whether usage metadata was present.

The managed-conversation scale acceptance additionally prints root and child
generation IDs plus aggregate token and cost accounting. Operators can audit
either generation without exposing the key:

```sh
scripts/openrouter_completion.sh <gen-id>
scripts/openrouter_completion.sh <gen-id> --content
```

`rlm_direct/4` uses the standard OpenAI-compatible native tool fields:
`options.tools`, `tool_choice`, assistant `tool_calls`, and `role:tool` messages
with the provider's original `tool_call_id`. Runtime calls are normalized to
provider-neutral data before execution. Provider IDs are correlation only and
never become capabilities, authority permits, or durable effect identities.

Native schemas are deterministic and compiled once per loop, but they are still
part of each Chat Completions request and may consume input tokens. Stable
`all_tools` profiles can improve provider prefix-cache reuse; query-compiled
profiles reduce cold schema tokens. Cache hits remain provider/model behavior.

Routine paid evidence runs once: pull-request updates and pushes to `main` use
the pinned `Paid OpenRouter` workflow. The equivalent live lane in the general
CI workflow is manual-dispatch only, avoiding duplicate provider calls for the
same commit while retaining an operator-triggered diagnostic path.
