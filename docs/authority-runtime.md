# Host authority and pending operations

`prolog-rlm` owns the authority policy, authority state, pending-operation protocol, exact operation identity, and execution resumption contract. Downstream clients own presentation.

There is no authority UI or TUI in core. A terminal, Emacs UI, web UI, or future `agentProlog/` client may list pending operations and call the core approve/deny/edit predicates, but it must not reimplement policy.

## Canonical authority tiers

The only public authority modes are, from strictest to broadest:

```text
approve_diff < allow_once < allow_session < dangerous
```

There is no public `yolo` mode. An unset context reads as `approve_diff`; core never defaults to `dangerous`.

Trusted host/application code owns authority selection. Model-controlled data may request equal or narrower child authority, but may never widen a parent ceiling.

The legal child relation is therefore:

```text
dangerous    -> dangerous | allow_session | allow_once | approve_diff
allow_session -> allow_session | allow_once | approve_diff
allow_once    -> allow_once | approve_diff
approve_diff  -> approve_diff
```

Capabilities and authority are separate boundaries. Child capabilities must be a subset of parent capabilities and child authority must be no broader than the parent authority ceiling. Satisfying one boundary never satisfies the other.

## Authoritative side-effect order

The runtime follows one ordering at mutation boundaries:

```text
operation/tool exists
  -> schema and argument validation
  -> capability check
  -> hard runtime policy / confinement
  -> normalized executable proposal
  -> authority evaluation
  -> execute immediately OR create pending operation
  -> approve / deny / edit when pending
  -> authoritative execution
```

Authority cannot make an invalid operation valid. In particular, `dangerous` bypasses interactive approval only. It does not bypass capabilities, schemas, argument validation, path confinement, process policy, network policy, budgets, lifecycle ownership, tracing, cancellation, or other hard restrictions.

Pure reads normally execute without interactive approval. Hosts may place stricter policy around a client, but MCP or graph involvement alone does not make a read a mutation.

## Exact fingerprints

A pending approval authorizes one normalized executable proposal, not a rendered prompt or UI row. `rlm_operation_fingerprint/3` canonicalizes the security-relevant operation structure and hashes it with its authority context.

Fingerprint identity includes executable fields such as operation name, effect, capability, normalized arguments, and normalized target/details. Incidental correlation metadata such as trace/session/run identifiers is retained for observability but excluded from executable fingerprint identity.

Equivalent canonical proposals therefore produce the same fingerprint. Changing an executable payload changes the fingerprint. Editing an operation creates a new proposal, a new approval ID, and a new fingerprint; approval of the old proposal cannot authorize the edit.

## Pending-operation lifecycle

`approve_diff` never parks an `rlm_async` scheduler worker while a human decides. Core creates a deferred/manual Future and records a pending operation:

```text
validated side effect
  -> authority says approval required
  -> pending operation + deferred Future
  -> original scheduler worker returns
  -> host may wait seconds, hours, or never
  -> approve | deny | edit
  -> resolution Future completes
```

`rlm_pending_approval/3` and `rlm_pending_approvals/2` expose sanitized policy/state records. Trusted continuation callables are held only in private control state and are never exposed as model data.

`rlm_pending_resolution_async/2` returns the deferred resolution Future. `rlm_pending_resolution/2` is the blocking facade over that same Future.

### Approve

Approval transitions the exact pending proposal into execution and schedules only its already-validated trusted continuation. Duplicate approval attempts fail deterministically rather than executing twice.

### Deny

Denial performs no target mutation. It records a structured denial and resolves the pending Future with the denial outcome.

### Edit

Edit re-runs the trusted edit validator and preflight, supersedes the original approval, and creates a new approval ID/fingerprint. Stale approval of the original proposal fails.

## `allow_once`

`allow_once` is a single atomic authorization. Consumption occurs at the authoritative non-read decision boundary, after schema/capability/hard-policy validation and after exact fingerprint construction, immediately before the caller receives permission to execute the side effect.

The transition is mutex-protected. Racing executions of the same authority context cannot both consume the one-shot mode. The first valid execution resets the context to `approve_diff` and records the exact fingerprint as started. Completion records the exact outcome; an exact retry replays that recorded outcome instead of executing the target again.

A request rejected before the authoritative decision boundary does not consume `allow_once`.

## `allow_session`

`allow_session` belongs to a concrete host runtime/session authority context. It is not persistent permission. Runtime/session teardown clears its authority state and owned pending operations. A fresh process or fresh runtime therefore starts from the safe default unless trusted host code selects a new mode.

Agents inherit or narrow the parent ceiling. Agent cancellation cancels/denies owned pending operations where appropriate; runtime destruction clears runtime and child authority state.

## Agents

Root agents default to `approve_diff` unless the trusted runtime configuration explicitly selects another tier. Child spawn performs both capability narrowing and authority narrowing. Model-facing spawn requests cannot widen authority.

Agent public latency-bearing operations preserve the canonical async direction:

```text
execute ABI
  -> async API returns Future
  -> sync API starts the same async operation and awaits it
```

Trusted code already executing inside a canonical async worker calls execute ABIs directly rather than starting and waiting on nested Futures.

## Graphs

Graph handlers are trusted registry callables, never callables reconstructed from model data. When a graph action invokes a normal tool boundary, the tool's schema, capability, hard-policy, and authority checks still apply even though the graph itself is already running inside an async worker.

Graph work should carry an explicit session/authority context when a host wants authority to remain stable across interrupt/resume. A side-effect node may map `approval_required` to a graph interruption, let the graph Future finish, resolve the pending operation later, and then resume the checkpoint. No scheduler worker needs to remain occupied during human latency.

Inline subgraphs continue to call the graph execute ABI directly so authority composition does not create nested-Future waits.

## MCP

MCP uses the same authority infrastructure; there is no MCP-specific approval system.

Imported MCP tools enter the canonical normal tool contract. Owned lifecycle mutations such as install, process-backed run/start, stop, and restart are classified and mediated at the shared authority boundary. Borrowed client connections and pure protocol requests are not treated as lifecycle mutations merely because MCP is involved.

Ownership remains explicit:

```text
owned server lifecycle != borrowed client connection
```

The option-bearing and convenience lifecycle surfaces both preserve canonical async-first execution: async submits the execute ABI; sync awaits that same async operation.

## Cancellation and cleanup

Cancelling an owner denies or cancels its active pending operations as appropriate. A cancelled pending operation cannot later be approved into a target mutation. Runtime/session teardown removes authority state and pending state owned by that lifecycle.

Deferred Futures themselves consume no scheduler worker. Ordinary execution Futures remain bounded by `rlm_async`; agent host-worker pools remain separate only for bounded mailbox/host work.

## Sync/async equivalence

There is one business-logic direction for latency-bearing core operations:

```text
canonical execute semantics
  +-- async API -> Future
  `-- sync API  -> same async operation -> await Future
```

Never implement `async API -> public synchronous API`, and never create a parallel synchronous business-logic tree. Authority decisions, capability decisions, fingerprints, pending records, traces, accounting, outcomes, and cancellation semantics must remain equivalent for the same inputs.

## Presentation boundary

Core deliberately stops at policy/state/protocol:

```text
prolog-rlm owns policy/state/protocol.
Downstream clients own presentation.
```

The future `agentProlog/` TUI may render authority tiers, pending diffs, counters, approve/deny/edit controls, and asynchronous progress, but that UI is downstream of this contract and is not implemented here.
