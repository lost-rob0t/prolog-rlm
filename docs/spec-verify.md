# Spec and Verify

`prolog-rlm` treats desired state, strategy, execution, and observed state as different semantic classes.

```text
Frozen Spec
    |\
    | +--> optional planner --> Plan --> optional execution
    |                                      |
    |                                      v
    +--------------------------------> observations
                                           |
                                           v
                                        Verify
                                           |
                         +-----------------+----------------+
                         |                                  |
                       pass                              reject
                                                            |
                                                            v
                                                   optional replan
```

The central invariant is simple: **the Spec defines what must be true; observations describe what is actually true.** A planner may change strategy and repair may replace a Plan, but neither may silently weaken or rewrite the exact frozen Spec being verified.

The implementation is split across these public modules:

- `rlm_evidence` defines structured observations, trust classes, provenance-shaped data, and narrowing evidence policies;
- `rlm_assertion` defines the trusted assertion-provider boundary and sanitized discovery catalog;
- `rlm_spec` normalizes, validates, freezes, fingerprints, publishes, and resolves Specs;
- `rlm_verify` evaluates supplied observations and separately collects observations when requested;
- `rlm_spec_workflow` provides optional Plan binding/execution and a bounded graph composition for Plan -> Execute -> Observe -> Verify -> repair.

These modules are independently reusable. Loading `rlm_spec` or `rlm_verify` does not require using the full workflow.

## Terms

### Spec

A **Spec** is closed, ground, versioned declarative data describing desired state. It contains a subject, requirements, optional invariants, an optional output contract, and provenance.

A Spec is not a Plan, a graph checkpoint, a tool call, or a source file full of executable Prolog.

### Frozen Spec

A **Frozen Spec** is a validated Spec with a stable content fingerprint and explicit logical version. Its semantic identity includes the effective host-bound assertion and evidence contract. Provenance is retained but does not change the semantic fingerprint.

Changing a requirement creates a different fingerprint. Publishing changed semantic content under the same Spec series also requires a newer logical version.

### Requirement

A **requirement** gives one assertion a stable requirement ID, severity, evidence policy, and provenance. Required requirements must pass for the verification report to pass. Optional failures remain visible but do not reject the report by themselves.

### Assertion

An **assertion** is declarative data such as:

```prolog
assertion(module_exports,
          _{module:rlm_spec,
            symbol:spec_verify/4}).
```

The core does not define programming as the universe. The same representation can describe dataset properties, research evidence, service state, records, graphs, deployment state, or another domain admitted by a trusted provider.

### Assertion registry

An **assertion registry** is trusted host/library configuration. Each admitted assertion kind binds:

- an argument-schema validator;
- a trusted pure evaluator;
- an optional observation collector;
- stable verifier and collector identities with versions;
- a host evidence policy;
- a verifier time limit;
- a latency class for collection.

Model-produced or project-produced data may select a registered assertion kind and provide validated arguments. It may not register a callable, replace a verifier, or provide executable Prolog.

The model-facing catalog is sanitized and omits validator, evaluator, and observer closures.

**Prolog-shaped model output is declarative data, not executable authority.** The Spec path does not expose arbitrary `call/1`, `once/1`, `consult/1`, `assertz/1`, or equivalent execution.

### Observation and evidence

An **observation** is structured evidence about actual state. It preserves:

- requirement and assertion identity;
- status and observed value;
- evidence references;
- source class and trust class;
- provenance;
- verifier and collector identity/version;
- snapshot/state reference when applicable;
- freshness and coherence scope.

Supported terminal and non-terminal states include `passed`, `failed`, `missing`, `pending`, `skipped`, `cancelled`, `error(...)`, `timeout(...)`, `indeterminate(...)`, and `stale(...)`.

A worker saying "tests pass" is a claim. It does not become equivalent to a trusted test observation merely because the sentence is confident.

### Project-KB observation

A **project-KB observation** is evidence supplied by a semantic provider backed by project knowledge. `rlm_spec` and `rlm_verify` do not parse programming languages and do not regex source files to guess whether a symbol exists.

The intended direction is:

```text
source + build/config metadata
            |
            v
language/project parsers and indexers
            |
            v
canonical project KB snapshot
            |
      +-----+-----+
      |           |
      v           v
   planner      verifier
      ^           ^
      +---- Spec --+
```

The final project-KB ontology is deliberately not defined here. Providers translate semantic assertions into queries over the future KB boundary.

### KB snapshot

A **KB snapshot** identifies the observed project state. Future providers can carry project identity, source revision/digest, parser/indexer set and versions, timestamp, and another stable snapshot reference.

Verification can require current evidence and a coherent state reference. Evidence from different source revisions must not silently masquerade as one project state.

After execution changes a project, the intended lifecycle is K1 -> execute -> re-index affected state -> K2 -> verify the unchanged Frozen Spec against K2 and any runtime evidence.

### Verification

**Verification** reconciles a Frozen Spec against observations. `spec_verify/4` does not collect new evidence. It may invoke only the trusted pure evaluator bound by the assertion registry for the assertion kind.

Missing, pending, failed, skipped, cancelled, errored, timed-out, indeterminate, or stale required evidence never counts as a passing required requirement.

Host evidence requirements narrow through Spec validation. Model-produced Spec content may request stricter checks, but it cannot remove a host-required source/trust/freshness condition or replace the host verifier with an easier one.

### Plan

A **Plan** is a proposed strategy for reaching desired state. `rlm_spec_workflow` reuses the existing `rlm_plan` representation and binds a Plan to the exact Frozen Spec reference. No second plan language is introduced.

Planning may be model-generated, host-generated, user-supplied, deterministic, or absent.

### Execution

**Execution** changes state by applying a Plan through existing trusted runtime capabilities. The Spec layer does not grant new effect authority.

Externally effectful work still belongs behind the existing normalization, policy, authority, effect-admission, dispatch, and observation boundaries. Re-verification or repair does not imply retry authorization and must not replay an effect merely because a requirement still fails.

### Repair

**Repair** may replace a Plan after a failed verification. The graph composition passes the same Frozen Spec into repair and rebinds the returned Plan to the same Spec reference.

Changing the goal is not repair. It is explicit Spec supersession: S1 becomes a historical Spec and new requirements freeze as S2.

## Spec only

A caller may stop after freezing:

```prolog
:- use_module(prolog/rlm_spec).

make_spec(Input, Registry, Frozen) :-
    spec_normalize(Input, ok(Spec)),
    spec_validate(Spec, Registry, ok(Validated)),
    spec_freeze(Validated,
                [series(my_task), version(1)],
                ok(Frozen)).
```

No planner, executor, artifact store, observer, or verifier is required by this composition.

Persistence is optional. `spec_publish/5` uses `rlm_artifact` only when durable handoff is wanted; `spec_resolve/3` resolves an exact historical publication.

## Verify supplied observations

`spec_verify/4` accepts observations that already exist:

```prolog
:- use_module(prolog/rlm_verify).

verify_existing(Frozen, Observations, Registry, Report) :-
    spec_verify(Frozen, Observations, Registry, ok(Report)).
```

This path performs no observation collection.

## Project-KB observation and Verify

A project semantic provider can query a future KB adapter and return structured evidence. Tests use a deterministic in-memory provider rather than implementing a language parser merely to prove the boundary:

```prolog
K1 = project_snapshot{project:demo,
                      revision:r1,
                      source_digest:r1,
                      parser_set:[fixture-1],
                      created_at:fixture},
Sources = [project_kb(K1, [exports(foo, foo/1)])],
spec_observe(Frozen, Sources, Registry, [], ok(Observations)),
spec_verify(Frozen, Observations, Registry, ok(Report)).
```

The same Frozen Spec fails when a later K2 snapshot does not contain the required semantic relationship. Planner fixtures also consume the same `project_kb(...)` abstraction. Neither subsystem parses a file.

## Custom non-programming assertion provider

A dataset can use the same core without changing `rlm_spec`:

```prolog
assertion_provider(
    record_count,
    1,
    my_app:validate_record_count_args,
    my_app:evaluate_record_count,
    my_app:observe_record_count,
    _{ verifier:_{id:dataset_semantics, version:1},
       collector:_{id:dataset_snapshot, version:1},
       evidence_policy:_{required_evidence:true,
                         source_classes:[dataset],
                         trust_classes:[observed],
                         freshness:current},
       latency:pure,
       description:"compare a structured dataset count"
     }).
```

The assertion data can then be `assertion(record_count, _{dataset:people, minimum:3})`. The trusted evaluator decides whether the supplied dataset observation satisfies it.

## Observe + Verify

Collection is intentionally separate:

```prolog
spec_observe(Frozen, Sources, Registry, Options, ok(Observations)),
spec_verify(Frozen, Observations, Registry, ok(Report)).
```

Pure/local collectors may execute directly. Blocking collectors use the existing shared `rlm_async` Future runtime. The synchronous surface awaits that same canonical async execution path rather than creating a second scheduler.

## Full Plan / Execute / Verify loop

The convenience workflow compiles onto `rlm_graph`:

```prolog
Config = _{plan:SuppliedPlan,
           observation_sources:InitialSources,
           source_refresher:my_app:refresh_project_state,
           repair:my_app:repair_plan,
           max_repairs:2},

spec_workflow_compile(Frozen, Registry, Config, [], ok(Workflow)),
spec_workflow_run(Workflow, [], Outcome).
```

A supplied Plan can instead be bound and executed independently with `spec_plan_bind/4` and `spec_plan_execute/5`.

The workflow graph ID incorporates the Frozen Spec fingerprint. Durable resume therefore remains bound to the exact Spec used to compile the workflow; a checkpoint cannot be resumed under a different Spec merely because a newer version exists.

## Semantic boundaries

Keep these classes separate:

| Class | Meaning |
| --- | --- |
| Frozen Spec | desired state and acceptance requirements |
| project KB snapshot | structured observed static project knowledge |
| runtime observation | observed dynamic/runtime state |
| artifact | immutable/versioned durable handoff |
| graph checkpoint | workflow execution state |
| authority | permission to perform an operation |
| effect record | admitted/dispatched external operation and its authoritative observation |
| Plan | proposed strategy for changing state |

References between these classes are useful. Collapsing them into a generic fact bucket is not.

The future project parser/indexer should build canonical project knowledge once. Planners and verifiers should query that knowledge through trusted semantic adapters rather than each subsystem learning its own source parser.
