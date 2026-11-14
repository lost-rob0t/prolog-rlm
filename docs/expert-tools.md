# Experts as tools

`expert_tool_register/5` (also exported by `rlm`) projects a trusted expert from
`rlm_expert` into `rlm_tool`. It does not create a second expert registry,
scheduler, model loop or permission system. Existing direct-mode registry
projection and typed-plan tool bindings can invoke the resulting ordinary tool.

```prolog
expert_tool_register(Tools, Experts, echo,
    expert_tool{name:echo_tool, goal:echo/1, description:"Echo a value",
                limits:limits{time_limit:1.0, max_output_bytes:16384,
                              inferences:100000}},
    ok(Schema)).

tool_invoke(Tools, [tool(echo_tool)], echo_tool,
            json{arguments:[hello]}, [], Outcome, Trace).
```

`Experts` must already contain a host-registered contract accepting `echo/1`.
The tool call contains **only the positional argument list**. The host freezes
the expert registry, identity, accepted goal functor/arity and generation when
registering the projection. Input does not supply a callable, context,
capabilities, registry or expert selection policy.

## Authority and budgets

Registration grants nothing. Invocation requires `tool(echo_tool)` **and every
capability listed in the expert contract's `requires`**. The tool schema's new
optional `requires` list is enforced before preflight/dispatch. Existing schemas
without that list retain their previous behavior. The expert receives only this
minimal fixed subset, not arbitrary additional caller capabilities.

The canonical tool runtime owns wall time, byte ceilings, tracing, async
execution and cancellation. An inference limit bounds the whole expert call,
including nested reasoning. Defaults are 1 second, 16 KiB and 100,000
inferences. Normal per-call tool options can tighten time/bytes, never widen
them. Existing expert depth, invocation-count, cycle and capability-narrowing
checks still apply. Cancellation and time/inference interrupts cross expert
wrappers rather than becoming successful ordinary tool results.

Changing *any* entry in the source expert registry invalidates existing
projections. Invocation fails closed; hosts must recreate the tool registry and
project the new version. The generation pin is checked again when the expert
run starts. This is deliberately conservative rather than automatic rebinding.

Success retains the complete `expert_outcome` inside the normal
`tool_execution.value`, including evidence, version, invocation identity and
zero-provider usage. Expert domain-level blocked/error outcomes remain explicit
inside that value, not invented successful findings. Tool admission/budget
failures use ordinary tool errors.

## Boundaries

This slice accepts only declared provider-free/read-only experts (`effects:[]`,
`fallback:none` or `no_fallback`). Host handlers are trusted code, not sandboxed
arbitrary Prolog. Model-backed/effectful experts need the separate shared model
metering and durable effect contracts and are rejected here. No specialist
expert brain is added; canonical domain definitions remain in dotfiles.

There is no autonomous expert registration, natural-language expert ranking,
`/auto` adoption, live provider test, or end-to-end IDE claim in this slice.
These are separate work under #377/#459. The older #427/#464 branches use a
previous expert ABI and cannot replace the current registry without migration.

Verification:

```sh
swipl --on-error=status -q -s test/rlm_expert_tool_test.pl -g run_tests -t halt
swipl -q -s test/run_tests.pl
```
