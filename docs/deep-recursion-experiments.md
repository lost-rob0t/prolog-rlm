# Depth >1 recursion experiments

Depth greater than one remains **experimental** in prolog-rlm. The production default is still depth 1.

This document describes the experiment boundary added for issue #20. It is deliberately conservative: deeper recursion is an option to measure, not a presumed improvement.

## Explicit opt-in

The supported public facade is `prolog/rlm.pl`.

A caller that requests a recursion budget above depth 1 must also pass:

```prolog
experimental_deep_recursion(true)
```

For example:

```prolog
rlm_completion(Query,
               Context,
               [ experimental_deep_recursion(true),
                 budget(_{max_recursion_depth:2})
               ],
               Outcome).
```

Supplying only `max_recursion_depth:2` is rejected before planner execution with `experimental_deep_recursion_required`.

The flag is **not a capability grant**. It does not add `rlm`, model, tool, context, parallel, retry, graph, or agent authority. All normal capability narrowing and budget checks still apply.

The adaptive recursion policy keeps its independent deeper-recursion gates as well: deep routing remains disabled unless both its deep-recursion policy switch and deep-recursion capability signal are enabled.

## Shared tree budgets

Nested typed `rlm(...)` plans execute through the existing `rlm_plan` state machine. They do not receive a fresh counter set at each level.

The plan validator recursively estimates the whole tree and applies global limits for:

- plan steps;
- plan depth;
- model calls;
- tool calls;
- context operations;
- parallel width.

The executor then carries one remaining runtime state across nested `rlm(...)` nodes for steps, model calls, tool calls, context operations, and output bytes.

Completion-level provider usage is aggregated after execution and checked against the completion call/token/cost ceilings. Provider-reported token or dollar usage is inherently known after a provider call; the experiment does not claim a stronger pre-request accounting guarantee than the provider runtime actually offers.

## Capability narrowing

A recursive child plan is validated under the explicitly narrowed `child_capabilities` set. A grandchild does not regain the root capability set merely because it is deeper.

The issue #20 acceptance tests include a depth-2 plan whose grandchild attempts to call a root-only tool. Validation rejects it before tool execution.

## Cancellation

Nested typed-plan recursion executes in the parent completion's supervised execution context. A completion cancellation token therefore covers work in a grandchild as well.

The issue #20 acceptance suite starts a trusted slow tool in a depth-2 grandchild, waits until that tool is actually running, cancels the root completion token, and requires the grandchild work to terminate with the structured cancellation outcome.

Delegated agents use their existing supervision tree. Cancelling the experiment root must cancel its child as well.

## Three composition strategies

The deterministic experiment compares three architectural shapes instead of assuming nested RLM is always correct.

### Nested RLM

A typed plan embeds `rlm(ChildPlan, Bind)` nodes. This preserves one plan state and is useful when the child result is part of one bounded symbolic execution tree.

### Delegated subagent

A supervised logical child is spawned with a narrowed capability set. This is useful when work needs lifecycle, mailbox, failure, or cancellation supervision independent of the parent's immediate plan stack.

The experiment executes the real agent runtime and verifies:

- child capability narrowing;
- attempted widening is denied;
- explicit checkpoint handoff works;
- parent cancellation propagates.

### Fresh-root artifact handoff

One reasoning root publishes a compact durable artifact and another fresh root consumes only that artifact reference. No conversational transcript is inherited.

The experiment executes the real artifact runtime and verifies publication, fresh-root consumption, provenance trace, and absence of transcript/message fields in the handoff entry.

## Running the deterministic experiment

```sh
swipl -q -s benchmark/run.pl -- deep-experiment
```

Write the canonical benchmark JSON to a file:

```sh
swipl -q -s benchmark/run.pl -- deep-experiment /tmp/deep-recursion.json
```

The same experiment is available from Prolog:

```prolog
?- use_module(prolog/rlm).
?- deep_experiment_run([experimental_deep_recursion(true)], Outcome).
```

Calling `deep_experiment_run/2` without the explicit flag fails closed.

## What the deterministic benchmark proves

The depth fixtures execute real nested typed plans at depth 0, 1, and 2. The delegated-agent and fresh-root cases execute their real runtime implementations. A dedicated safety case proves that nested static model-call and step estimates are enforced against one whole-tree budget.

The fixture `quality`, token, call, and cost figures are intentionally synthetic comparison data. They exist to exercise classification and reporting behavior. They are **not** OpenRouter measurements and must not be represented as model economics.

Measured wall-clock orchestration latency is real for that local deterministic run, but it is not a provider-latency benchmark.

The fixture set is designed to produce all three possible outcomes:

- **helps** — enough quality gain to justify the deeper candidate in that fixture;
- **hurts** — no meaningful quality gain while modeled cost increases, or quality regresses;
- **neutral** — a small positive change that does not meet the experiment's help threshold.

This is intentional. The harness must be capable of saying "do not recurse deeper."

## Promotion rule

`deep_experiment_promotion/2` encodes the graduation rule. Depth >1 is eligible for production consideration only when evidence satisfies **all** of these defaults:

```text
live trials                 >= 20
independent fixtures        >= 3
quality delta               >= +0.05
cost ratio vs baseline      <= 1.50
latency ratio vs baseline   <= 2.00
budget violations           == 0
capability violations       == 0
cancellation failures       == 0
```

The deterministic experiment reports `live_trials:0`, so it **cannot promote depth >1 by itself** even when every structural test passes.

Example:

```prolog
Evidence = promotion_evidence{
    live_trials:24,
    independent_fixtures:4,
    quality_delta:0.08,
    cost_ratio:1.30,
    latency_ratio:1.60,
    budget_violations:0,
    capability_violations:0,
    cancellation_failures:0
},
deep_experiment_promotion(Evidence, Decision).
```

Any failed requirement produces `status:hold` plus explicit reasons. There is no automatic runtime switch from experimental to production.

## Research relationship

This implementation follows the approved direction in:

- `RLM-RESEARCH-008` — adaptive recursion, depth ceilings, progress/duplicate guards, and evidence before deeper production recursion;
- `RLM-RESEARCH-005` — supervised logical agents, narrowed authority, bounded workers/mailboxes, and cancellation propagation;
- `RLM-RESEARCH-009` — fresh reasoning roots share compact durable artifacts rather than inherited transcript state.

## Known fingerprint edge

Issue #42 tracks a Prolog term-API edge discovered while writing the depth-2 capability test: an anonymous-tag SWI dict inside a nested plan can make the existing direct `term_hash/2` recursive fingerprint non-ground and cause a false cycle rejection. The #20 tests use named-tag data so that capability/cancellation invariants are isolated from that separate fingerprint bug. The follow-up must canonicalize fingerprints without weakening genuine duplicate/cycle protection.
