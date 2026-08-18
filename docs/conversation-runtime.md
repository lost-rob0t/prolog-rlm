# Managed conversation runtime

`rlm_conversation` owns durable multi-turn state above the stateless `rlm_completion/4` primitive. The public `rlm` facade routes managed packing and turns through `rlm_conversation_runtime`, which combines hot transcript context, already-published warm context, a synthetic cold-history boundary, and lazy cold-history retrieval.

The canonical contract is:

```text
complete durable transcript
        |
        +--> bounded rolling hot context
        |
        +--> existing warm artifacts
        |      ranked + representation-selected
        |
        +--> synthetic cold-history boundary
        |      tells the model how to recover omitted history
        |
        `--> lazy cold RLM context
             peek / slice / search on demand
```

Old turns leaving active attention are never deleted or rewritten. The cold-history boundary exists only in the provider-visible projection. Creating new warm state is explicit; consuming existing warm state is integrated into the normal managed runtime when a warm store is configured.

## Public API

```prolog
conversation_store_open(+Spec, -Outcome).
conversation_store_close(+Store, -Outcome).
conversation_create(+Store, +Options, -Outcome).
conversation_open(+Store, +ConversationId, -Outcome).
conversation_list(+Store, +Options, -Outcome).
conversation_append(+Conversation, +Message, -Outcome).
conversation_message(+Conversation, +Sequence, -Outcome).
conversation_messages(+Conversation, +Selector, +Options, -Outcome).
conversation_search(+Conversation, +Query, +Options, -Outcome).
conversation_stats(+Conversation, -Outcome).
conversation_export(+Conversation, +Format, -Outcome).
conversation_context_pack(+Conversation, +Options, -Outcome).
conversation_token_ledger(+Conversation, +Options, -Outcome).
conversation_cold_context(+Conversation, +Options, -Outcome).
conversation_turn(+Conversation, +UserMessage, +Options, -Outcome).
```

Stores currently support `memory` and `persist(File)`.

## Managed turns

The public `rlm:conversation_turn/4` resolves configured warm artifacts, derives the synthetic cold-history boundary when needed, persists the user turn, compiles hot + warm + boundary context under the hard token ceiling, registers an ephemeral opaque cold-history handle, runs `rlm_completion/4`, deletes only the handle, and persists the assistant result.

`rlm_completion/4` remains stateless and independently reusable.

## Token budget contract

The provider's physical context window and the operator's working cap are separate:

```prolog
context_policy{
    max_context_tokens:300000,
    provider_context_tokens:1000000,
    reserve_output_tokens:32000,
    safety_margin_tokens:8000,
    min_recent_turns:12,
    overflow:deny
}.
```

The effective ceiling is `min(max_context_tokens, provider_context_tokens)`. The synthetic cold-history boundary is a mandatory provider-visible context unit and is charged in the normal token ledger.

## Cold-history boundary

Durable transcript messages are never edited to carry runtime instructions. When the projected conversation extends beyond `min_recent_turns`, `rlm_conversation_runtime` adds a synthetic mandatory `managed_cold_history_boundary` unit.

It tells the planner that older sequences may be absent from active attention, that they were not deleted, and that original history should be retrieved before guessing. It exposes the bounded retrieval forms:

```prolog
context(input(context), search("query"), Result).
context(input(context), slice(Start, Length), Result).
context(input(context), peek(item(Index)), Result).
```

The boundary reports the prefix outside the guaranteed hot tail. Warm context or spare budget may still retain additional older material. Boundary status is exposed as `cold_history_boundary`, and specialized callers may disable it with `cold_history_boundary(false)`.

## Warm context is wired in; automatic compaction is not

Already-published warm state is integrated into managed turns when `warm_store/1` is configured. Creating/publishing new warm state remains explicit. A managed turn does not choose ranges to compact, invoke a summarizer, or publish new warm artifacts merely because token pressure rises.

## Cold history and unbounded conversations

The complete transcript stays in durable storage behind a small opaque context handle. Historical payload is projected only through bounded context operations. The provider window therefore limits active attention, not total addressable conversation history.

## Remaining work

1. provider/model tokenizer registry and final rendered-request counting;
2. prompt-compiler accounting for tools, MCP, skills, project instructions, and rendering overhead;
3. bounded hot-candidate selection for very large histories;
4. indexed cold-history retrieval;
5. async managed-turn and streaming surfaces;
6. bounded model-visible adapter metadata.
