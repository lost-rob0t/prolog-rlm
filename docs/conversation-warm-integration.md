# Warm context in managed conversations

Warm context is part of the managed conversation pipeline, but automatic compaction is not.

The canonical public `rlm` facade routes `conversation_context_pack/3`, `conversation_token_ledger/3`, and `conversation_turn/4` through `rlm_conversation_runtime`.

```text
complete durable transcript
        |
        +--> rolling hot context
        |
        +--> existing warm artifacts
        |      ranked + representation-selected
        |
        `--> lazy cold RLM context
               peek / slice / search
        |
        v
shared token-budget solver
```

## Configuring warm reuse

Publish warm context explicitly:

```prolog
conversation_warm_publish(Conversation,
                          ArtifactStore,
                          range(1, 40),
                          WarmOptions,
                          Outcome).
```

Then configure the same artifact store on normal managed context options:

```prolog
conversation_turn(
    Conversation,
    message(user, "continue the work"),
    [ context_options([
          policy(context_policy{
              max_context_tokens:300000,
              provider_context_tokens:1000000,
              reserve_output_tokens:32000,
              safety_margin_tokens:8000,
              min_recent_turns:12,
              overflow:deny
          }),
          warm_store(ArtifactStore),
          warm_signals(Signals),
          warm_options([policy(_{max_candidates:32})])
      ]),
      completion_options(CompletionOptions)
    ],
    Outcome
).
```

No `context_units/1` plumbing is required for published warm artifacts. The managed runtime discovers the current warm artifacts, ranks them, converts them to ordinary context units, and gives them to the same CLP(FD) token solver as hot conversation context.

Explicit caller `context_units/1` still work. If an explicit unit has the same id as an automatically loaded warm unit, the explicit unit wins so it is not duplicated.

## Opt-in bounded auto-production in managed turns

The default remains unchanged: no warm artifacts are created automatically.

A managed turn can opt in by supplying `auto_warm/1` and a compatible
`warm_store/1` inside its `context_options`:

```prolog
context_options([
    warm_store(ArtifactStore),
    auto_warm([
        min_batch_messages(24),
        max_batch_messages(48),
        keep_recent_messages(12)
    ])
])
```

Before persisting the next user message, the runtime checks estimated context
pressure, scans the latest published warm ranges, and fills the earliest
uncovered interval (including gaps before a partial summary). Once enough
old source messages are eligible, it calls the existing `conversation_warm_publish/5`
API. Existing generation options `generator/1`, `completion_options/1` and
`token_options/1` can be included inside `auto_warm/1` for bounded custom
generators or runtime model generation.

Source history is immutable. A newly published artifact participates in the
**same turn's** managed context pack; already-covered ranges are not
republished on normal subsequent turns. The turn's
`context.auto_warm` field reports whether a range was published or why
the threshold was not reached. Missing stores, invalid limits or failed
publication return structured errors **before** the next user turn is appended.

The default trigger is token pressure in the current context projection.
`trigger(message_count)` explicitly selects the former message-count behavior.
Batch sizes bound one publication, never the lifetime transcript. A context
projection that fits retains all unsummarized messages, including beyond the
normal 256 cold-candidate solver window. When it does not fit, the bounded
solver window and opaque cold-history retrieval remain available.
Generation usage is returned separately in `context.auto_warm.generation`;
it is not charged again to the user completion.
Multi-writer concurrent publication coordination and project semantic KB
indexing are separate follow-up work. Do not interpret these warm summaries
as trusted executable Prolog clauses.

## What is deliberately not automatic

A managed turn does **not**:

- choose a transcript range to compact;
- call a model to generate a warm summary;
- publish or version a new warm artifact;
- react to token pressure by silently summarizing history.

Warm production remains explicit **unless** the caller opts in using `auto_warm/1` as described above. Warm consumption is always wired into the managed runtime once `warm_store/1` is configured.

This separates two independent decisions:

```text
Should existing warm state participate in attention?
    -> yes, automatically when configured

Should the runtime create new warm state?
    -> no, not automatically
```

The complete transcript remains authoritative and cold-addressable regardless of whether warm context exists.

## Managed native turns and execution accounting

`strategy(native)` on `conversation_turn/4` runs the canonical `rlm_direct/4`
provider-native tool loop over the same managed query, cold handle, immutable
user/assistant records and context ledger. The default `strategy(symbolic)`
uses the existing supervisor. Invalid strategies fail before appending a user
message. Callers remain responsible for granting narrowed capabilities.

The execution-token budget counts cumulative provider-reported prompt plus
completion usage across model calls. It is independent of the 131072-token
context policy. Known usage cannot be hidden by a later response with missing
usage; inconsistent totals cannot undercut their known components. Output
limits constrain generated tokens, not prompt costs. A provider can therefore
report an overrun on its last response; the runtime rejects the result and
admits no further work. No exact pre-dispatch token guarantee is claimed for
providers lacking an authoritative tokenizer/reservation API.

Compaction defaults to the runtime completion budget unless a caller supplies
separate bounded `completion_options`. Its usage remains attributable to the
warm generation, separate from the user turn. Context-pressure estimates do
not include the pending user message; an unusually large new message can
still fail the context gate. Live provider and concurrent publication tests
are required before broader guarantees.
