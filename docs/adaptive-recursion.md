# Adaptive recursion routing

`rlm_recursion_policy` chooses among bounded execution forms instead of treating recursion as the default. `rlm_recursion_runtime` executes exactly one selected route through an explicit caller-supplied handler.

The design goal is:

```text
choose the cheapest bounded execution form with enough expected utility
```

not:

```text
recurse until a configured depth is exhausted
```

## Routes

The canonical route set is:

| Route | Intended use |
| --- | --- |
| `direct_continuation` | Short/tractable work where another harness layer would add overhead |
| `deterministic_context` | Filtering, indexing, extraction, or other symbolic context operations |
| `cheap_submodel` | Bounded semantic subproblem suitable for an explicitly available cheaper model |
| `recursive_rlm` | Complex long-context decomposition that benefits from isolated recursive context |
| `delegated_subagent` | Branching/tool-heavy work that benefits from supervised actor execution |

A route being representable does not make it executable. Runtime execution requires a supplied handler for that route.

## Default policy

```prolog
default_recursion_policy(
    recursion_policy{
        max_candidates:5,
        max_recursion_depth:1,
        allow_deep_recursion:false,
        deep_recursion_capability:false,
        min_progress:0.05,
        cost_weight:0.55,
        native_context_chars:120000,
        cheap_submodel_available:false,
        delegated_subagent_available:false,
        deterministic_context_available:true,
        artifact_context_available:false,
        candidate_generator:none,
        candidate_selector:none
    }).
```

The coefficients are policy defaults, not API guarantees. The stable contract is the normalized signals/candidates/decision and the bounded execution semantics.

## Signals

`recursion_route/3` accepts a dict containing any of these signals:

```prolog
_{ task_complexity:0.8,
   context_chars:180000,
   uncertainty:0.7,
   branch_diversity:0.3,
   progress:1.0,
   duplicate:false,
   current_depth:0,
   remaining_calls:4,
   remaining_tokens:8000,
   deterministic_context_available:true,
   cheap_submodel_available:false,
   delegated_subagent_available:false,
   artifact_context_available:true
 }.
```

Scores are normalized to `[0,1]`. Context pressure is derived from `context_chars / native_context_chars` and capped at `1.0`.

## Expected utility vs. cost

Each route candidate is normalized as:

```prolog
recursion_candidate{
    route:Route,
    expected_utility:Utility,
    estimated_cost:Cost,
    expected_value:Value,
    rationale:Rationale
}.
```

The default deterministic scorer uses:

```text
expected_value = expected_utility - cost_weight * estimated_cost
```

Candidates are sorted by expected value with deterministic route tie-breaking, then hard-bounded by `max_candidates`.

## Decision API

```prolog
recursion_route(+Signals, +Options, -Outcome).
recursion_candidates(+Signals, +Options, -Outcome).
```

A successful route returns:

```prolog
recursion_decision{
    policy:Route,
    reason:Reason,
    signals:NormalizedSignals,
    budget_remaining:recursion_budget{
        depth:RemainingDepth,
        calls:RemainingCalls,
        tokens:RemainingTokens
    },
    expected_utility:Utility,
    estimated_cost:Cost,
    expected_value:Value,
    candidates:Candidates,
    trace:Trace
}.
```

The trace repeats the selected policy, reason, normalized signals, remaining budgets, utility/cost/value, and candidate count. Consumers do not need hidden policy state to explain a choice.

## Deep recursion gate

Production depth is capped at one even if a caller raises the numeric maximum:

```prolog
[max_recursion_depth(4)]
```

still permits no depth-2 recursive call.

Depth greater than one requires both:

```prolog
allow_deep_recursion(true)
deep_recursion_capability(true)
```

For example:

```prolog
[ max_recursion_depth(4),
  allow_deep_recursion(true),
  deep_recursion_capability(true)
]
```

This makes deeper recursion an explicit experimental capability rather than an accidental budget change.

## Duplicate and no-progress protection

Create a stable fingerprint for a ground recursive subject:

```prolog
recursion_fingerprint(+Subject, -Fingerprint).
```

Validate it before recursive execution:

```prolog
recursion_guard(+Fingerprint,
                +PreviousFingerprints,
                +Progress,
                +Options,
                -Outcome).
```

A repeated fingerprint fails with `duplicate_subcall(Fingerprint)`. Progress below `min_progress` fails with `no_progress(Actual, Required)`.

The normalized routing signals also contain `duplicate` and `progress`. If either already shows a stalled recursive path, the recursive candidate is omitted so another route can be selected.

## Bounded model-assisted hooks

Candidate generation can be extended with:

```prolog
candidate_generator(Closure)
```

where `Closure` is called as:

```prolog
call(Closure, Signals, BaseCandidates, GeneratedCandidates)
```

Generated candidates must use canonical routes and valid utility/cost scores. Any supplied `expected_value` is ignored; the policy recomputes it with the configured cost weight.

Selection can be extended with:

```prolog
candidate_selector(Closure)
```

called as:

```prolog
call(Closure, Signals, BoundedCandidates, Selected)
```

The selector may return a candidate or route, but the route must already exist in the normalized **bounded** candidate set. It cannot create an unbounded route during selection.

## Executable routing

Policy selection has no provider/tool/agent side effects. Execution is separate:

```prolog
recursion_execute(+Signals,
                  +Request,
                  +Options,
                  -Outcome).
```

A request is conceptually:

```prolog
_{ subject:GroundSubject,
   direct_continuation:DirectHandler,
   deterministic_context:ContextHandler,
   cheap_submodel:CheapHandler,
   recursive_rlm:RecursiveHandler,
   delegated_subagent:AgentHandler,
   selector:SelectorOrNone,
   generator:GeneratorOrNone
 }.
```

Handlers are optional. Missing handlers remove the corresponding capability signal or force deterministic redirection if a non-executable route was otherwise selected.

Each handler is called as:

```prolog
call(Handler, Decision, Subject, Result)
```

and may return `ok(Value)`, `error(Error)`, or a plain value. Cancellation/time-limit control exceptions are rethrown rather than converted to ordinary route failures.

## Execution result

Successful execution returns:

```prolog
recursion_execution{
    selected_policy:Route,
    decision:Decision,
    result:Value,
    fingerprint:Fingerprint,
    next_fingerprints:FingerprintHistory,
    next_depth:Depth,
    trace:[PolicyTrace, ExecutionTrace]
}.
```

Only recursive execution increments depth and adds the current subject fingerprint to history.

## Provider and agent boundaries

The policy layer does not know OpenRouter wire details, model names, MCP methods, or actor mailbox internals. A caller that has a cheap provider may expose a `cheap_submodel` handler. A caller with supervised actors may expose a `delegated_subagent` handler. A caller with neither simply does not expose those routes.

This preserves the existing architecture:

```text
signals + budgets + capabilities
  -> adaptive recursion policy
  -> bounded route decision
  -> explicit route handler
  -> existing provider / context / RLM / agent subsystem
```

## Regression expectations

The deterministic suite verifies:

- trivial work stays direct;
- complex long-context work selects depth-1 recursion;
- deterministic context work can beat model recursion;
- cheap-model and delegated-agent routes are capability-gated;
- duplicate/no-progress recursion is rejected or redirected;
- depth >1 requires both experimental gates;
- candidate generation is hard-bounded;
- generated value claims are rescored;
- selector hooks cannot escape the bounded set;
- route execution invokes only the selected handler;
- recursive execution advances depth/fingerprint state;
- time-limit/cancellation control exceptions propagate.
