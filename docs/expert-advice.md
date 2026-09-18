# Expert-guided symbolic advice

`rlm_expert_advice` is the compatibility bridge between the canonical
reasoning-mode contract (#335) and the full expert runtime (#377).

It makes symbolic mode more open without creating a second tool executor:
registered tool schemas can participate as deterministic expert candidates,
while trusted handlers remain inside `rlm_tool`.

## Direction

```text
registered tool schemas
      |
      v
prompt compiler relevance selection
      |
      v
inert expert_selection
      |
      +--> expert_applicable signal -> /auto
      |
      v
bounded expert_advice
      |
      v
one canonical model request
      |
      v
answer OR provider tool-call proposal
      |
      v
existing rlm_tool execution boundary
```

The expert layer does not execute the selected tool.

## Public API

```prolog
expert_tool_candidates(+Registry, -Outcome).
expert_tool_select(+Registry, +Query, +Options, -Outcome).
expert_mode_signal(+Selection, -Signal).
expert_advice_build(+Selection, +Evidence, -Outcome).
expert_advice_model_request(+Advice, +Query, +Options, -Outcome).
expert_advice_model_step(+Provider, +Advice, +Query, +Options, -Outcome).
```

### Tool-as-expert projection

`expert_tool_candidates/2` consumes `tool_discover/2`, which already strips
trusted handlers. Each candidate contains only inert schema information:

```prolog
expert_candidate{
    id:tool(Name),
    name:Name,
    description:Description,
    required_capability:tool(Name),
    effect:Effect,
    limits:Limits,
    schema:SanitizedSchema,
    source:tool_registry
}
```

A candidate is knowledge that an operation exists. It is not authorization.

### Selection

`expert_tool_select/4` imports the registry into a temporary
`rlm_prompt_compiler` catalog and asks the existing compiler's bounded
relevance search for one tool candidate.

This deliberately reuses the same lexical/metadata semantics already used for
managed tool discovery. There is no second fuzzy router or model classifier.

The compatibility selector accepts no capability, authority, effect, provider,
or budget override options. Those concerns remain owned by their canonical
runtime boundaries.

A successful selection includes `applicable:true`. No relevant candidate is a
normal `applicable:false` result.

### Auto-mode signal

```prolog
expert_mode_signal(Selection, _{expert_applicable:true}).
```

That signal can be supplied to `reasoning_mode_select/4`. It changes strategy
only. It cannot grant the selected tool capability.

### One-step advice

`expert_advice_build/3` creates closed bounded data containing:

- selected expert/tool identity;
- normal required capability and effect metadata;
- deterministic relevance rationale;
- at most 16 bounded evidence strings;
- `stop_condition:one_model_step`;
- the sanitized selected tool schema.

`expert_advice_model_request/4` converts that advice into exactly one
`model_request{}` with two messages: one expert-system instruction and the
user/task query. Only the selected tool's provider schema is exposed.

`expert_advice_model_step/5` submits that request once through the canonical
`rlm_chain:model_complete/3` boundary. It does not loop and it does not
execute any returned tool call.

If the provider proposes the selected tool, the supervising symbolic runtime
must submit that proposal through normal `rlm_tool` invocation with the
already-held capabilities and authority. A missing capability therefore fails
exactly as it would without the expert system.

## Future #377 migration

The full expert registry will replace tool-schema compatibility candidates with
first-class expert contracts and Prolog applicability rules. The important
invariants remain:

- expert selection is deterministic where rules suffice;
- expert output is advice/data, not hidden authority;
- local expert success can avoid a model call entirely;
- model fallback is explicitly bounded;
- normal tool/effect/budget/cancellation accounting remains canonical.
