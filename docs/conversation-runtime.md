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

History selectors include `all`, `recent(Count)`, `range(Start, End)`, `before(Sequence)`, `after(Sequence)`, `around(Sequence, Radius)`, and `role(Role)`.

## Managed turns

The public `rlm:conversation_turn/4`:

1. resolves configured existing warm artifacts into candidate context units;
2. derives a synthetic cold-history boundary when history exists outside the guaranteed hot tail;
3. delegates to the durable conversation layer, which persists the current user turn;
4. compiles hot + warm + boundary context under the configured token ceiling;
5. registers an ephemeral opaque context handle over the complete durable transcript;
6. calls `rlm_completion/4`;
7. lets RLM use bounded `peek`, `slice`, or `search` operations when colder history is needed;
8. deletes only the ephemeral handle;
9. persists the assistant result.

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

The effective ceiling is `min(max_context_tokens, provider_context_tokens)`.

A model advertising one million tokens therefore does not grant permission to consume one million tokens when the operator selected a 300k working cap.

Fixed model-visible sections, selected context units, output reserve, and safety margin all enter one token ledger. Host-only metadata is measured separately and is not charged against the provider window.

The synthetic cold-history boundary is a mandatory context unit, so its provider-visible text is charged in the same ledger rather than appearing as invisible prompt overhead.

## Context packing

`rlm_context_budget` uses CLP(FD) to select the highest-utility set of representations that satisfies the hard token ceiling. Mandatory units cannot be silently omitted. Optional units may be omitted or represented in alternate forms.

The same solver therefore accounts for hot conversation turns, warm representations, the cold-history boundary, tool schemas, MCP schemas, project context, skills, and other compiler units instead of creating separate token-budget systems.

## Cold-history boundary

The runtime never edits an old durable message to tell the model that history was evicted. Doing that would corrupt transcript semantics and falsely attribute runtime instructions to a user or assistant.

Instead, when the projected conversation extends beyond `min_recent_turns`, `rlm_conversation_runtime` adds a synthetic mandatory context unit named `managed_cold_history_boundary`. It reports the prefix that lies outside the guaranteed hot tail and tells the planner how to recover original turns through the opaque conversation context.

The rendered instruction includes bounded operations such as:

```prolog
context(input(context), search("query"), Result).
context(input(context), slice(Start, Length), Result).
context(input(context), peek(item(Index)), Result).
```

The boundary deliberately says older sequences *may* be absent from active attention. The solver can still retain extra old material or warm representations when budget and utility justify it. The cold transcript remains authoritative regardless.

Boundary status is exposed on managed pack/turn context as `cold_history_boundary`. For debugging or specialized callers it may be disabled explicitly with `cold_history_boundary(false)`; the default is enabled.

## Warm context is wired in; automatic compaction is not

Warm consumption and warm production are separate concerns. Already-published warm state is integrated into managed turns; creating/publishing new warm state remains explicit.

Publish warm state explicitly with `conversation_warm_publish/5`, then configure its artifact store:

```prolog
context_options([
    policy(Policy),
    warm_store(ArtifactStore),
    warm_signals(Signals),
    warm_options([policy(_{max_candidates:32})])
]).
```

With `warm_store/1` configured, the managed runtime automatically loads, ranks, narrows and converts warm artifacts into multi-representation context units. The shared CLP(FD) solver can choose `verbatim`, `detailed_summary`, `compact_summary`, `facts_only`, or omission under the hard token cap.

A managed turn does **not** choose ranges to compact, invoke a summarization model, publish new warm artifacts, or trigger compaction merely because token pressure rises.

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
