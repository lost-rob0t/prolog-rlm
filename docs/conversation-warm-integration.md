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

## What is deliberately not automatic

A managed turn does **not**:

- choose a transcript range to compact;
- call a model to generate a warm summary;
- publish or version a new warm artifact;
- react to token pressure by silently summarizing history.

Warm production remains an explicit feature/API. Warm consumption is wired into the normal managed runtime once `warm_store/1` is configured.

This separates two independent decisions:

```text
Should existing warm state participate in attention?
    -> yes, automatically when configured

Should the runtime create new warm state?
    -> no, not automatically
```

The complete transcript remains authoritative and cold-addressable regardless of whether warm context exists.
