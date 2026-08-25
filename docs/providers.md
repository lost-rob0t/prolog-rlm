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
                     address_family(inet)]).
```

The provider term stores only the environment-variable reference. The key is
resolved with `getenv/2` at request execution time and is never added to model
responses, errors, traces, fixtures, or logs.

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
repository secret `OPENROUTER_API_KEY` and optional repository variable
`OPENROUTER_TEST_MODEL`. A missing secret is a hard failure on that trusted
path.

The live smoke test performs a real HTTPS request through the production
`rlm_chain` path. It has no fake-provider fallback. Its log prints only safe
evidence: provider, requested model, selected model, HTTP status, whether a
response was received, and whether usage metadata was present.
