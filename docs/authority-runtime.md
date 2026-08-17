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
dangerous     -> dangerous | allow_session | allow_once | approve_diff
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
  -> authoritative execution claim
  -> side effect
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
  -> bounded execution scheduling when approved
  -> resolution Future completes
```

`rlm_pending_approval/3` and `rlm_pending_approvals/2` expose sanitized policy/state records. Trusted continuation callables are held only in private control state and are never exposed as model data.

`rlm_pending_resolution_async/2` returns the deferred resolution Future. `rlm_pending_resolution/2` is the blocking facade over that same Future.

### Approve

Approval does not directly call the continuation. Core creates a short-lived private execution gate, submits the already-validated trusted continuation to `rlm_async`, attaches the returned execution Future to authority control state, and only then arms the gate.

The resulting pre-execution states are:

```text
pending
  -> approved
  -> scheduled
  -> execution claim
  -> executing
```

The gate is only an internal scheduling handshake. It is not a human wait and it is never a second approval system. A worker can briefly wait for the scheduling handshake, but human latency always remains represented by the deferred pending-resolution Future and consumes no shared worker.

Duplicate approval attempts fail deterministically rather than executing twice.

### Deny

Denial performs no target mutation. It records a structured denial and resolves the pending Future with the denial outcome.

### Edit

Edit re-runs the trusted edit validator and preflight, supersedes the original approval, and creates a new approval ID/fingerprint. Stale approval of the original proposal fails. The superseded record immediately drops its trusted continuation and edit-validator references.

## Cancellation / execution linearization

Approval and owner cancellation have one explicit linearization point: the authority execution claim under the `rlm_authority` mutex.

```text
approved operation
  -> execution Future attached
  -> gate armed
  -> exactly one wins:
       cancellation before claim -> terminal cancelled, no continuation call
       execution claim first     -> executing; later cancellation is best-effort
```

Before the claim, cancellation removes executable control state, cancels the attached Future when one exists, resolves the public pending-resolution Future, and prevents the continuation from crossing the side-effect boundary. A queued scheduler task may still be dequeued later, but its cancelled Future cannot claim execution and therefore cannot mutate the target.

After the claim, the operation has already crossed the authoritative execution boundary. Owner cancellation transitions the record through `cancelling` and interrupts the execution Future through normal `rlm_async` cancellation. That interruption is deterministic at the Future/protocol level, but host side effects that completed after the claim and before interruption are not rolled back. Authority is a permission boundary, not a transaction manager.

Runtime and agent teardown use the same owner-cancellation path. There is no separate teardown-only confirmation or cancellation mechanism.

## Bounded terminal retention

Active executable control state and terminal inspection history are separate concerns.

Active states may retain the trusted continuation, edit validator, pending-resolution Future, execution Future, and private execution gate only while those resources can still participate in execution.

Terminal states are:

```text
resolved
denied
superseded
cancelled
```

When a record becomes terminal, core immediately drops its trusted continuation, validator, execution-Future reference, and gate. The sanitized public record and its already-resolved deferred resolution Future may remain queryable for bounded inspection.

The current retention limit is **64 terminal records per authority context**. Active operations do not count against this limit and are never pruned merely to make room for history.

When terminal history exceeds the limit, the oldest terminal record is removed and its retained resolution Future is destroyed. After pruning:

- `rlm_pending_approval/3` no longer finds that approval ID;
- `rlm_pending_resolution_async/2` raises `existence_error(rlm_pending_operation, Id)`;
- stale approve/deny/edit attempts cannot revive the operation.

`rlm_pending_approvals/2` therefore returns all active operations plus at most the bounded retained terminal history for that context. It is not an unbounded audit log. `rlm_authority_events/2` remains the policy/event stream; downstream durable audit storage, if desired, belongs outside executable pending control state.

Context/runtime teardown destroys all remaining active and retained resolution Futures and removes the context authority registries deterministically.

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

Cancelling an owner denies a still-pending proposal or cancels an approved/scheduled/executing operation according to the execution-claim semantics above. A cancellation that wins before execution claim makes later target mutation impossible through that pending continuation.

Deferred Futures themselves consume no scheduler worker. Ordinary execution Futures remain bounded by `rlm_async`; agent host-worker pools remain separate only for bounded mailbox/host work.

Terminal pending history is bounded and does not retain executable callables. Context teardown destroys the remaining bounded resolution Futures and cancels/destroys active execution Futures.

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
