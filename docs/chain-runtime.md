# Canonical chain runtime

`rlm_chain` is the provider-neutral model abstraction used by agents and RLMs.
It keeps the existing `model_complete/3` compatibility API and adds canonical
messages, prompt templates, structured output, routing, middleware, retries,
usage/tracing, and true provider streaming.

## Public API

The main predicates are:

```prolog
model_complete(+Provider, +Request, -Outcome).
model_stream(+Provider, +Request, +EventHandler, -Outcome).
chain_invoke(+ProviderSpec, +Request, +Options, -Outcome).
chain_stream(+ProviderSpec, +Request, +Options, +EventHandler, -Outcome).

message_normalize(+Input, -Outcome).
messages_normalize(+Inputs, -Outcome).
prompt_compile(+Spec, -Outcome).
prompt_bind(+Compiled, +Bindings, -Outcome).
structured_schema_compile(+Spec, -Outcome).
structured_validate(+Schema, +Value, -Outcome).
structured_decode_validate(+Schema, +Text, -Outcome).
default_retry_policy(-Policy).
```

All operational APIs use explicit `ok(Value)` / `error(Error)` outcomes for
ordinary provider and validation failures. Cancellation and time-limit control
exceptions are not converted into ordinary streaming provider errors by the
OpenAI-compatible transport.

## Providers and routing

A direct provider is an explicit trusted term:

```prolog
provider(openrouter,
         [endpoint('https://openrouter.ai/api/v1/chat/completions'),
          credential(env('OPENROUTER_API_KEY')),
          model('openrouter/free'),
          timeout(30),
          address_family(inet)])
```

Credentials remain environment references in provider configuration. They are
resolved only inside the transport and are redacted from transport errors.
The optional address family is `auto`, `inet`, or `inet6`; OpenRouter defaults
to `inet` so an unusable first IPv6 route cannot stall before SWI-Prolog starts
the configured stream timeout.

`chain_invoke/4` and `chain_stream/5` also accept:

```prolog
route([ProviderA, ProviderB, ...])
```

with a `router(Closure)` option. The router is called as:

```prolog
call(Closure, Request, DeclaredCandidates, SelectedProvider)
```

The selected provider must be a member of the declared candidate list. A route
outside that list fails closed with `invalid_route_selection`; the router cannot
manufacture an undeclared provider target.

## Canonical messages

The canonical shape is:

```prolog
message{role:Role, content:Content}
```

Supported roles are `system`, `user`, `assistant`, and `tool`. Atom/string roles
and atom/string textual content are normalized.

Multimodal content is represented as an ordered list of canonical parts. The
currently supported parts are text and image URL metadata:

```prolog
message{
  role:user,
  content:[
    content_part{type:text, text:"inspect this"},
    content_part{
      type:image_url,
      image_url:image{url:"https://example.test/image.png", detail:high}
    }
  ]
}
```

Image detail is one of `auto`, `low`, or `high`. Providers advertise the
`multimodal_input` capability when this representation can be forwarded.

## Prompt templates

Prompt templates are deliberately small and declarative:

```prolog
prompt_compile(
    prompt([text("Hello "), slot(name), text(" #"), slot(id)]),
    ok(Compiled)),
prompt_bind(Compiled, _{name:"Ada", id:7}, ok("Hello Ada #7")).
```

Missing slots and unsupported binding values return structured prompt errors.
There is no implicit lookup of environment variables or global state.

## Structured output

Supported schema constructors are:

- `any`
- `string`
- `integer`
- `number`
- `boolean`
- `enum(Values)`
- `list(ItemSchema)`
- `object(Fields)`

Object fields use:

```prolog
field(Name, Schema, required)
field(Name, Schema, optional(Default))
```

Example:

```prolog
SchemaSpec = object([
    field(answer, string, required),
    field(score, number, required)
]),
chain_invoke(Provider,
             Request,
             [structured_schema(SchemaSpec)],
             Outcome).
```

The response text is decoded as JSON and validated before the chain returns a
successful completion. Extra object fields are rejected. A structured-output
validation failure may be retried only when the retry policy explicitly allows
`structured_validation`.

## Retry policy

The canonical policy is a dict:

```prolog
retry_policy{
  max_attempts:3,
  base_delay:0.25,
  max_delay:2.0,
  retry_kinds:[provider_error, structured_validation]
}
```

Retries are bounded by `max_attempts`. Delay uses bounded exponential backoff:
`base_delay * 2^(attempt-1)`, capped at `max_delay`.

Every retry emits a `retry_scheduled` trace event containing the failed attempt,
next attempt, retry kind, and selected delay. Usage is accumulated across all
provider responses, including responses later rejected by structured-output
validation.

A custom `sleep_handler(Closure)` can be supplied for deterministic tests. It is
called as `call(Closure, Delay)`.

## Middleware

Middleware is an ordered list:

```prolog
middleware(Stage, Closure)
```

Supported stages, in lifecycle order, are:

1. `request`
2. `model_response`
3. `tool_call`
4. `completion`

A handler is called as:

```prolog
call(Closure, Context, Input, Output)
```

Handlers at the same stage execute in declaration order. Each handler receives
the previous handler's transformed value. Predicate failure short-circuits the
chain as `middleware_failed`; exceptions become structured middleware errors.
Tool-call middleware runs once for each canonical tool call in list order.

The context is a `chain_context{}` dict containing the stage, attempt number,
and selected provider where applicable. Middleware does not branch on internal
provider transport implementation.

## Trace and usage

Successful `chain_invoke/4` returns a `chain_result{}` containing at least:

```prolog
chain_result{
  provider:Provider,
  request:CanonicalRequest,
  response:ModelResponse,
  structured:StructuredOrNone,
  attempts:AttemptCount,
  usage:chain_usage{
    prompt_tokens:Prompt,
    completion_tokens:Completion,
    total_tokens:Total,
    cost:Cost
  },
  trace:Events
}
```

Trace events have monotonically increasing `sequence` values and a canonical
shape:

```prolog
chain_event{sequence:N, type:Type, fields:Fields}
```

A `trace_handler(Closure)` option can observe events as they are emitted.

## Streaming contract

`model_stream/4` and `chain_stream/5` perform a real streaming provider request.
For OpenAI-compatible chat completions the transport sends `stream:true` and
`stream_options:{include_usage:true}`, opens the HTTP response as a SWI-Prolog
stream with `http_open/3`, and consumes SSE `data:` lines incrementally.

The relevant primary documentation is:

- SWI-Prolog `http_open/3`: https://www.swi-prolog.org/pldoc/doc_for?object=http_open%2F3
- OpenAI Chat Completions streaming: https://platform.openai.com/docs/api-reference/chat/create

The normalized event protocol is:

```prolog
stream_event{type:text, choice_index:I, delta:Text}
stream_event{type:reasoning, choice_index:I, delta:Text}
stream_event{type:reasoning, choice_index:I, details:Details}
stream_event{type:tool_call, choice_index:I, tool_index:J, delta:RawDelta}
stream_event{type:finish, choice_index:I, finish_reason:Reason}
stream_event{type:usage, usage:Usage}
stream_event{type:done}
```

Tool-call fragments are aggregated by tool index into the final canonical tool
calls. Text and reasoning deltas are concatenated in arrival order. The final
usage chunk is normalized when supplied. `[DONE]` terminates the stream and is
represented by the final `done` event.

A stream that ends before `[DONE]` is rejected as `invalid_stream`; this avoids
silently treating truncated output as a successful completion.

The `EventHandler` passed to `chain_stream/5` is invoked while provider bytes are
being consumed, not after a completed response has been chunked. If the handler
fails, the stream fails structurally rather than silently dropping an event.

Streaming is single-attempt after bytes begin to flow. Retrying an already
observable stream would duplicate externally visible deltas, so the canonical
stream lifecycle does not replay a partial provider stream. Callers that need
failover must do so before exposing stream events or start a new explicit chain
operation.

The final successful chain stream result additionally contains:

```prolog
stream_events:Events
```

and its `response` field is the canonical response aggregated from the actual
incremental events.
