# Managed conversation runtime

`rlm_conversation` adds durable multi-turn state above the stateless `rlm_completion/4` primitive.

The default contract is deliberately simple:

```text
complete durable transcript
        |
        +--> bounded rolling hot context
        |
        `--> lazy cold RLM context
             peek / slice / search on demand
```

Old turns leaving active attention are not deleted and are not automatically summarized.

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

History selectors include `all`, `recent(Count)`, `range(Start, End)`, `before(Sequence)`, `after(Sequence)`, `around(Sequence, Radius)`, and `role(Role)`.

## Managed turns

`conversation_turn/4`:

1. persists the current user turn;
2. compiles the bounded active context under the configured token ceiling;
3. registers an ephemeral opaque context handle over the complete durable transcript;
4. calls `rlm_completion/4`;
5. lets RLM use bounded `peek`, `slice`, or `search` operations when older history is needed;
6. deletes only the ephemeral handle;
7. persists the assistant result.

`rlm_completion/4` remains stateless and can still be used independently.

If completion fails, the user message remains durable and no assistant message is fabricated.

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

The effective ceiling is:

```text
min(max_context_tokens, provider_context_tokens)
```

A model advertising one million tokens therefore does not grant permission to consume one million tokens when the operator selected a 300k working cap.

Fixed model-visible sections, selected context units, output reserve, and safety margin all enter one token ledger. Host-only metadata is measured separately and is not charged against the provider window.

The stage ledger records observed, charged, and cumulative tokens for each compilation step so callers can see where the window went.

## Context packing

`rlm_context_budget` uses CLP(FD) to select the highest-utility set of representations that satisfies the hard token ceiling. Mandatory units cannot be silently omitted. Optional units may be omitted or represented in alternate forms.

The same solver can therefore account for conversation turns, tool schemas, MCP schemas, project context, skills, or explicit derived context without creating separate token-budget systems.

## Warm context is optional

`rlm_conversation_warm` remains a supported feature for callers that explicitly want derived summaries, facts, decisions, or other compressed representations.

It is **not wired into the default conversation path**:

- `conversation_turn/4` does not automatically derive warm artifacts;
- `conversation_turn/4` does not automatically load warm artifacts;
- token pressure does not trigger hidden summarization/model calls;
- leaving the hot window means cold retrieval, not compulsory compaction.

A caller may explicitly derive warm records and pass their resulting context units into `conversation_context_pack/3`. Those units then compete under the same hard token budget as everything else.

Automatic compaction should only be reconsidered if telemetry shows repeated retrieval of the same old ranges creates enough token or latency cost to justify the added complexity.

## Cold history and unbounded conversations

The complete transcript is represented to RLM by a small opaque handle plus safe metadata, not copied into every provider request.

Historical content is projected only when a bounded context operation asks for it. This makes conversation length independent from the provider context window: the window limits active attention, not total durable history.

Current local stores may still scan their own records while servicing a cold search. That is a persistence/indexing optimization and can later be replaced by an indexed backend without changing the RLM contract.

## Remaining work

The main remaining conversation-runtime work is:

1. provider/model tokenizer registry and counting of the final rendered provider request;
2. automatic prompt-compiler accounting for local tools, MCP tools/prompts/resources, skills, and project instructions;
3. bounded hot-candidate selection for very large histories;
4. indexed cold-history retrieval;
5. async managed-turn and streaming surfaces for AgentProlog/frontends.
