# Managed conversation runtime

`rlm_conversation` owns durable multi-turn state above the stateless `rlm_completion/4` primitive. The public `rlm` facade routes managed packing and turns through `rlm_conversation_runtime`, which combines hot transcript context, already-published warm context, and lazy cold-history retrieval.

The canonical contract is:

```text
complete durable transcript
        |
        +--> bounded rolling hot context
        |
        +--> existing warm artifacts
        |      ranked + representation-selected
        |
        `--> lazy cold RLM context
             peek / slice / search on demand
```

Old turns leaving active attention are never deleted. Creating new warm state is explicit; consuming existing warm state is integrated into the normal managed runtime when a warm store is configured.

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

The public `rlm:conversation_turn/4`:

1. resolves configured existing warm artifacts into candidate context units;
2. delegates to the durable conversation layer, which persists the current user turn;
3. compiles the bounded hot + warm active context under the configured token ceiling;
4. registers an ephemeral opaque context handle over the complete durable transcript;
5. calls `rlm_completion/4`;
6. lets RLM use bounded `peek`, `slice`, or `search` operations when colder history is needed;
7. deletes only the ephemeral handle;
8. persists the assistant result.

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

The same solver therefore accounts for hot conversation turns, warm representations, tool schemas, MCP schemas, project context, skills, and other compiler units instead of creating separate token-budget systems.

## Warm context is wired in; automatic compaction is not

Warm context has two separate concerns:

```text
consume already-published warm state
    -> integrated into managed turns

create/publish new warm state
    -> explicit API, not automatic
```

Publish warm state explicitly with `conversation_warm_publish/5`. Then configure its artifact store on normal managed context options:

```prolog
context_options([
    policy(Policy),
    warm_store(ArtifactStore),
    warm_signals(Signals),
    warm_options([policy(_{max_candidates:32})])
]).
```

With `warm_store/1` configured, the public managed runtime automatically:

- loads the current warm artifacts for the conversation;
- ranks them using `warm_signals/1` and the warm policy;
- narrows them to a bounded candidate set;
- converts them to multi-representation context units;
- lets the shared CLP(FD) solver choose `verbatim`, `detailed_summary`, `compact_summary`, `facts_only`, or omission under the hard token cap;
- removes optional hot source turns covered by the selected warm candidates so the same history is not paid for twice.

Callers do not need to manually feed warm `context_units/1` into the public `rlm` facade. Explicit context units remain supported and override an automatically loaded warm unit with the same id.

A managed turn does **not** choose ranges to compact, invoke a summarization model, publish new warm artifacts, or trigger compaction merely because token pressure rises. That remains an explicit feature and can be revisited later if telemetry justifies automation.

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
5. async managed-turn and streaming surfaces for AgentProlog/frontends;
6. bounded model-visible adapter metadata.
