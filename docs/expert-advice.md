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
        +--> PURE SYMBOLIC: expert_invoke/7 -> deterministic result
        |                    model/provider calls = 0
        |
        `--> OPTIONAL MODEL ADVICE: bounded expert_advice
                                  -> exactly one canonical model request
                                  -> answer OR selected expert-tool proposal
                                  -> existing rlm_tool execution boundary
```

The optional advisory layer never executes the provider's returned tool call.
Pure-symbolic execution never enters the model-advice branch.

## Public API

```prolog
expert_tool_candidates(+Registry, -Outcome).
expert_tool_select(+Registry, +Query, +Context, -Outcome).
expert_mode_signal(+Selection, -Signal).
expert_auto_route(+ModeContext, +Registry, +Query, +ExpertContext, +TaskSignals, -Outcome).
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

### Expert-aware auto route

`expert_auto_route/6` is the normal composition point for downstream `/auto`
frontends.

It:

1. performs expert selection from the query and real capability context;
2. derives `expert_applicable` internally;
3. refuses a caller-supplied `expert_applicable` field;
4. merges the derived signal with the remaining trusted task signals;
5. calls canonical `reasoning_mode_select/4`;
6. returns both the expert selection and resulting mode state.

This makes expert-aware `auto` a single runtime operation rather than forcing
each frontend to duplicate the routing sequence.

### Pure-symbolic zero-model path

Pure-symbolic consumers stop at deterministic expert selection and invoke the
selected expert through canonical `rlm_expert:expert_invoke/7`. They do **not**
call `expert_advice_build/3`, `expert_advice_model_request/4`, or
`expert_advice_model_step/5`.

That distinction is normative for zero-model acceptance:

- provider configuration and credentials are unnecessary;
- `max_model_calls=0` remains valid for the whole deterministic expert path;
- parse miss, ambiguity, missing expert, or expert error returns deterministic
  typed state to the symbolic supervisor rather than entering a provider
  fallback;
- capability, cancellation, budget, and effect checks remain owned by the
  canonical expert/tool runtime;
- downstream Zara pure-symbolic consumers must treat the model-advice API as an
  explicitly opt-in fallback surface, never as mandatory reasoning glue.

A deterministic expert result is therefore complete symbolic evidence in its
own right. No model call is implied by expert selection, applicability, auto
routing, or local expert invocation.

### Optional one-step model advice

`expert_advice_build/3` belongs specifically to the optional model-advice path.
It creates closed bounded advice containing the selected expert/tool identity,
goal, version, normal capability/effect metadata, deterministic selection
rationale, at most 16 bounded evidence strings, and
`stop_condition:one_model_step`.

`expert_advice_model_request/4` renders only the selected expert-tool schema
into one provider request.

`expert_advice_model_step/5` calls `rlm_chain:model_complete/3` exactly once.
It does not loop and it does not execute returned tool calls.

If the model proposes the expert-tool, the supervising symbolic runtime submits
that proposal through ordinary `rlm_tool` execution. Capability and authority
are rechecked there. Expert selection therefore cannot make a denied tool
executable.

The `one_model_step` stop condition is intentionally local to this opt-in API.
It is not the stop condition for pure-symbolic expert execution and must not be
propagated into zero-model consumers.

## Loop policy

The deterministic loop is the base path:

```text
observe state
-> apply local deterministic experts/rules
-> choose one next expert/tool
-> invoke through canonical expert/tool authority
-> validate result/effects
-> observe new state
-> repeat under the enclosing runtime budget
```

Only when the enclosing policy explicitly permits provider use may that loop
branch to exactly one model-advice step. Model advice is a fallback/operator,
not mandatory reasoning glue.

## Remaining #377 work

The merged/integration slice is still a bounded **leaf** expert runtime.
Recursive expert cooperation, aggregate nested expert budgets,
evidence-aware applicability predicates, richer invocation lineage,
per-expert unregister, and fully metered recursive/model fallback remain
separate #377 work.
