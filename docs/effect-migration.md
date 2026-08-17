# Migrating pre-v2 effect stores

PR #83 deliberately refuses to open a non-empty PR #78 effect journal that has
no durable store namespace. The error is

```text
legacy_effect_store_requires_migration
```

Do not work around it by adding metadata to the old file. A namespace changes
identity construction for new calls and attempts. A blind rewrite can also
lose an old provider idempotency key, detach an observation, authorize an
abandoned attempt, or select the wrong adapter for uncertain remote work.

## Operator workflow

Stop every process that may have the store attached. Migration acquires the
same `<ledger>.lock` exclusive advisory lock used by the runtime and returns
`lock_conflict` if a runtime or another migration owns it.

The recommended operation writes a new file:

```sh
swipl -q -s bin/prolog-rlm.pl -- effect-store migrate \
  --source effects.db \
  --output effects.v2.db \
  --json
```

Review the JSON report, configure the runtime to use `effects.v2.db`, and keep
the source until operational verification is complete.

In-place replacement is explicit and requires a new backup path:

```sh
swipl -q -s bin/prolog-rlm.pl -- effect-store migrate \
  --source effects.db \
  --in-place \
  --backup effects.pre-v2.backup \
  --json
```

The backup is a byte-for-byte copy whose SHA-256 digest is verified before the
source path is replaced. To roll back, stop the runtime and restore that backup
to the original source path. A backup is restoration material, not a writable
clone.

## Compatibility model

Migration reads the real PR #78 persistency predicates and preserves:

- every legacy call ID and executable fingerprint;
- every attempt ID, revision, parent, sequence, and mode;
- every original provider idempotency key;
- immutable observations, including usage and provenance;
- lifecycle events and their projection order.

It adds a schema-v2 namespace, deterministic migration ID, source-file digest,
canonical destination path, and optional immutable adapter bindings. It does
not reinterpret legacy IDs as namespace-derived v2 IDs.

Legacy records remain available for status, replay, accounting, and trusted
reconciliation. A legacy ticket cannot admit a new attempt. A normal prepare
after migration uses the v2 namespace/epoch constructor and receives new call,
attempt, and provider identities. An `abandoned` attempt stays terminal;
migration never creates retry authority.

Legacy attempt IDs are also fenced at the dispatch predicate. Even a preserved
legacy `admitted` record cannot be turned into a new external submission after
migration; the operator must prepare and authorize a normal v2 operation.

The canonical destination path is checked on ordinary runtime open. Copying a
migrated journal to another path therefore fails with
`migrated_effect_store_copy` instead of silently creating a second writable
store with the same namespace. This slice has no clone operation. Restore a
backup only to its documented destination path; initialize independent stores
normally.

## Adapter-binding manifest

Observed attempts replay locally and need no callback. Unresolved legacy
attempts may lack the code-owned adapter identity introduced by PR #83.
Migration never guesses it from provider names, requests, endpoints,
correlation metadata, or executable kind.

An optional manifest has exactly this versioned JSON shape:

```json
{
  "schema": "prolog-rlm.effect-migration-manifest.v1",
  "source_digest": "sha256:...",
  "bindings": [
    {
      "attempt_id": "effect-attempt:...",
      "adapter": "code_owned_adapter"
    }
  ]
}
```

Generate `source_digest` with a SHA-256 tool while the store is offline,
enumerate unresolved attempt IDs through an operator-reviewed inspection, and
obtain adapter atoms from code-owned adapter configuration. The manifest holds
identity decisions only; never put credentials, request bodies, or observation
bodies in it.

The parser rejects unknown keys, invalid/non-ground values, invalid adapter
atoms, duplicate/conflicting bindings, nonexistent attempts, a digest for a
different journal, and conflicts with an existing trusted adapter identity.
Missing bindings are reported in `attempts_requiring_adapter_bindings`; those
attempts remain fail-closed and reconciliation invokes no adapter. Caller
metadata cannot override a migrated binding.

## Crash and publication behavior

Migration holds the source lock, validates the complete legacy reference and
revision graph, copies an in-place backup when required, and writes a temporary
journal in the destination filesystem. The temporary journal is compacted,
reopened, and compared with the source snapshot before publication. The file is
synced, renamed atomically, and the destination directory is synced before
success is reported.

The source is never modified out-of-place. Before in-place publication it
remains the legacy journal and the verified backup exists. A crash after
publication leaves a complete v2 journal; rerunning reports
`already_migrated`. Stale `.migrating` files are not runtime stores and are
replaced only while canonical locks are held.

The report schema is `prolog-rlm.effect-migration-report.v1`. Status values are
`migrated`, `already_migrated`, `incompatible`, `corrupt`,
`ambiguous_adapter`, `lock_conflict`, `interrupted`, and `validation_failed`.
Default reports contain counts and identity metadata, not request or
observation bodies.

## Non-goals

Migration performs no submit, cancel, or reconcile callback. It does not
implement #79 canonical provider/tool/MCP/process adoption, rewrite #53
authority, change #54 Future execution, provide distributed consensus, or
claim protocol-independent exactly-once execution.
