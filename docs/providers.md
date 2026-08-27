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
credentials are intentionally rejected as configuration.

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
