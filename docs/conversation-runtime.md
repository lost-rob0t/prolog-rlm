# Managed conversation runtime

`rlm_conversation` adds durable multi-turn conversation state above the existing stateless `rlm_completion/4` primitive.

The core invariant is simple:

```text
complete transcript
    -> durable, append-only conversation state

active model context
    -> bounded projection chosen for this turn
```

Removing an old message from active context never deletes it from the conversation. Historical turns remain addressable by exact sequence, ranges, search, or export.

## Public API

```prolog
conversation_store_open(+Spec, -Outcome).
conversation_store_close(+Store, -Outcome).

conversation_create(+Store, +Options, -Outcome).
conversation_open(+Store, +ConversationId, -Outcome).

conversation_append(+Conversation, +Message, -Outcome).
conversation_message(+Conversation, +Sequence, -Outcome).
conversation_messages(+Conversation, +Selector, +Options, -Outcome).
conversation_search(+Conversation, +Query, +Options, -Outcome).
conversation_stats(+Conversation, -Outcome).
conversation_export(+Conversation, +Format, -Outcome).

conversation_context_pack(+Conversation, +Options, -Outcome).
conversation_token_ledger(+Conversation, +Options, -Outcome).
conversation_turn(+Conversation, +UserMessage, +Options, -Outcome).
```

Stores currently support:

```prolog
memory
persist(File)
```

The persistent adapter uses the same local SWI persistency style as the artifact runtime. It is an adapter, not a permanent storage-format commitment.

## History selectors

```prolog
all
recent(Count)
range(Start, End)
before(Sequence)
after(Sequence)
around(Sequence, Radius)
role(Role)
```

Search is bounded by `max_results/1` and defaults to case-insensitive matching.

## Managed turns

`conversation_turn/4` persists the user turn, compiles a bounded rolling context, and delegates reasoning to `rlm_completion/4`. The complete transcript is also supplied as opaque RLM term context for this initial slice.

```prolog
conversation_turn(
    Conversation,
    message(user, "continue the parser work"),
    [ context_options([
          policy(context_policy{
              max_context_tokens:300000,
              provider_context_tokens:1000000,
              reserve_output_tokens:32000,
              safety_margin_tokens:8000,
              min_recent_turns:12,
              overflow:deny
          })
      ]),
      completion_options([
          provider(openrouter)
      ])
    ],
    Outcome
).
```

`rlm_completion/4` itself remains stateless. Conversation history is never implicitly attached to unrelated completion calls.

If completion fails, the user message remains durably recorded and no assistant message is fabricated.

## Token budget contract

`rlm_context_budget` separates the provider's physical window from the operator's working cap.

```prolog
context_policy{
    max_context_tokens:300000,
    provider_context_tokens:1000000,
    reserve_output_tokens:32000,
    safety_margin_tokens:8000,
    min_recent_turns:12,
    overflow:deny
}
```

The effective limit is:

```text
min(max_context_tokens, provider_context_tokens)
```

A 1M-token model therefore does not grant permission to consume 1M tokens when the operator selected a 300k working cap.

Fixed provider-visible sections, reserved output, safety margin, and selected context units all contribute to one ledger. Host-only metadata is measured separately and is not charged against the model window.

```prolog
visible_sections([
    section(system, model, SystemPrompt),
    section(local_tools, model, RenderedToolSchemas),
    section(mcp_tools, model, RenderedMcpSchemas),
    section(mcp_connection_config, host, HostOnlyMetadata)
])
```

The ledger reports both the operator and provider ceilings, fixed visible tokens, host-only metadata tokens, selected context tokens, reserves, total, and remaining tokens.

## Token counting

The runtime does not pretend a character estimate is exact.

Without a registered counter:

```prolog
token_count{
    tokens: Tokens,
    method: estimated,
    basis: characters,
    safety_percent: 15
}
```

A trusted caller can supply a model/provider tokenizer callback through `token_counter/1`; successful counts are marked `method:exact`.

Provider renderers should eventually count the final rendered request rather than intermediate Prolog terms. Tool schemas, MCP metadata, skills, conversation context, project context, and rendering overhead should all enter the same ledger.

## Constraint packing

Context selection is not FIFO truncation. `context_pack/4` accepts units with one or more representations:

```prolog
context_unit{
    id: architecture_history,
    section: warm,
    mandatory: false,
    variants: [
        context_variant{kind:verbatim,
                        tokens:18000,
                        utility:100,
                        value:Full},
        context_variant{kind:detailed_summary,
                        tokens:6000,
                        utility:92,
                        value:Detailed},
        context_variant{kind:compact_summary,
                        tokens:2000,
                        utility:76,
                        value:Compact}
    ]
}
```

Optional units automatically gain an `omitted` representation. Mandatory units cannot be silently omitted.

CLP(FD) constrains the total token cost and uses labeling/backtracking to maximize utility under the hard cap. This makes conversation history, warm summaries, retrieved cold turns, skills, and tool/MCP schemas compatible with the same future optimizer rather than separate ad-hoc truncation systems.

The current conversation projection generates `verbatim`/`omitted` variants from transcript messages. Rich warm variants are the next slice.

## Next slices

Issue #101 tracks the remaining work:

1. provider/model tokenizer registry and final rendered-request counting;
2. automatic prompt-compiler integration for local tools, MCP tools/prompts/resources, skills, and project instructions;
3. warm-context extraction with verbatim, detailed-summary, compact-summary, facts-only, and omitted variants;
4. RLM retrieval over cold transcript history without materializing the entire transcript into each managed call;
5. relevance, unresolved-task, entity, dependency, recency, provenance, and explicit-reference utility scoring;
6. candidate narrowing before exact CLP(FD) packing for very large histories/catalogs;
7. async managed-turn/streaming surfaces for AgentProlog and other frontends.

This keeps the complete conversation available indefinitely while bounding the amount of attention consumed by any individual model call.
