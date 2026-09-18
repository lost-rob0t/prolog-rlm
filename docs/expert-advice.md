# Expert-guided symbolic advice

`rlm_expert_advice` composes three existing authorities:

1. `rlm_expert` — trusted deterministic Prolog experts;
2. `rlm_prompt_compiler` — bounded relevance selection over inert metadata;
3. `rlm_tool` / `rlm_chain` — the normal capability/tool and provider boundaries.

It does **not** create another expert registry, tool executor, scheduler, or model
loop.

## Expert/tool identity

A first-class leaf expert is registered once:

```prolog
expert_register(Registry, ExpertContract, TrustedHandler, Outcome).
```

`rlm_expert` simultaneously projects that same handler as a normal read-only
registered tool. The expert system therefore decides over real expert contracts,
while direct/planned/model-facing tool execution reuses the same canonical
handler.

The public expert catalog never contains handlers.

## Direction

```text
trusted expert contracts
        |
        +---- projected as ordinary registered read tools
        |
        v
prompt-compiler relevance search over sanitized schemas
        |
        v
canonical expert_select(goal, capabilities, priority)
        |
        +--> expert_applicable signal -> /auto
        |
        v
bounded expert_advice
        |
        v
exactly one canonical model request
        |
        v
answer OR selected expert-tool proposal
        |
        v
existing rlm_tool execution boundary
```

The advisory layer never executes the provider's returned tool call.

## Public API

```prolog
expert_tool_candidates(+Registry, -Outcome).
expert_tool_select(+Registry, +Query, +Context, -Outcome).
expert_mode_signal(+Selection, -Signal).
expert_advice_build(+Selection, +Evidence, -Outcome).
expert_advice_model_request(+Advice, +Query, +Options, -Outcome).
expert_advice_model_step(+Provider, +Advice, +Query, +Options, -Outcome).
```

### Candidate projection

`expert_tool_candidates/2` begins with `expert_catalog/2`, then obtains the
sanitized tool schema associated with each expert. Plain registered tools that
have no expert contract are not candidates.

A candidate is inert:

```prolog
expert_candidate{
    id:expert(Name),
    name:Name,
    goal:Goal,
    version:Version,
    priority:Priority,
    description:Description,
    required_capability:tool(Name),
    effect:read,
    limits:Limits,
    schema:SanitizedSchema,
    contract:InertExpertContract,
    source:expert_registry
}
```

No callable is present.

### Selection

`expert_tool_select/4` accepts a trusted context containing exactly a
`capabilities` field.

It performs two stages:

1. the prompt compiler ranks sanitized registered-tool metadata against the
   natural-language query;
2. results are filtered to actual expert contracts and the matching expert
   goal is passed into canonical `expert_select/4`.

The second stage owns expert priority, ambiguity, and capability applicability.
A model does not choose the expert and cannot claim a capability.

For example, if a normal non-expert tool has excellent matching keywords, it is
still excluded from expert selection.

A context containing authority, budget, provider, handler, or other unexpected
fields fails closed.

### Auto mode

```prolog
expert_mode_signal(Selection, reasoning_task_context{expert_applicable:true}).
```

The signal is ground data and plugs directly into
`reasoning_mode_select/4`. It changes reasoning strategy only.

An applicable expert therefore makes `/auto` prefer `symbolic`.
An expert plus trusted decomposable/recursion signals may make the mode selector
choose `symbolic-recursive`.

### One-step model advice

`expert_advice_build/3` creates closed bounded advice containing the selected
expert/tool identity, goal, version, normal capability/effect metadata,
deterministic selection rationale, at most 16 bounded evidence strings, and
`stop_condition:one_model_step`.

`expert_advice_model_request/4` renders only the selected expert-tool schema
into one provider request.

`expert_advice_model_step/5` calls `rlm_chain:model_complete/3` exactly once.
It does not loop and it does not execute returned tool calls.

If the model proposes the expert-tool, the supervising symbolic runtime submits
that proposal through ordinary `rlm_tool` execution. Capability and authority
are rechecked there. Expert selection therefore cannot make a denied tool
executable.

## Loop policy

The intended symbolic loop is deliberately incremental:

```text
observe state
-> apply local deterministic experts/rules
-> choose one next expert/tool
-> if model judgment is useful, advise exactly one model step
-> validate/propose/execute through canonical boundaries
-> observe new state
-> repeat under the enclosing runtime budget
```

A deterministic expert may also be invoked locally through `expert_invoke/7`
with zero model calls. Model advice is a fallback/operator, not mandatory
reasoning glue.

## Remaining #377 work

The merged/integration slice is still a bounded **leaf** expert runtime.
Recursive expert cooperation, aggregate nested expert budgets,
evidence-aware applicability predicates, richer invocation lineage,
per-expert unregister, and fully metered recursive/model fallback remain
separate #377 work.
