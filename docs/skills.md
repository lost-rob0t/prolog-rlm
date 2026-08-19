# Prolog-owned skills

`rlm_skill` makes `SKILL.md` collections usable without handing skill activation to the model. Prolog discovers bounded metadata, evaluates deterministic evidence from the operator input, closes dependencies, applies a hard skill-prompt token ceiling, and only then reads the selected Markdown bodies.

A selected skill is instruction data, not authority. It cannot grant a tool, capability, path, network endpoint, MCP server, process, provider, or executable Prolog predicate. Those remain controlled by the existing runtime registries and authority boundary.

## Catalogs

Load any trusted skill directory containing nested `SKILL.md` files:

```prolog
?- skill_catalog_load("./skills", [], ok(Catalog)).
```

The loader reads only bounded frontmatter during catalog construction. Full Markdown bodies are loaded lazily after selection. Supported metadata is deliberately small:

```text
---
name: code-review
description: Review code changes against requirements.
keywords: [review, diff]
phrases: [review this change]
intents: [review]
requires: [tdd]
priority: 20
disable-model-invocation: false
---
```

`explicit-user-only`, `user-invocable-only`, and `disable-model-invocation` all make a skill explicit-only. Explicit-only skills never activate from lexical evidence alone.

Catalog scanning rejects symlinks and duplicate skill names. `skill_resource_read/4` additionally rejects traversal outside the selected skill directory.

## Compile skills

```prolog
?- skill_compile(Catalog,
                 "review this diff",
                 [max_skill_prompt_tokens(4096)],
                 ok(Compilation)),
   skill_compilation_summary(Compilation, Summary),
   skill_render(Compilation, PromptText).
```

Selection uses deterministic evidence from the skill name, optional phrases/intents/keywords, and description overlap. Explicit selection wins over ordinary lexical routing. Direct negation such as `do not use code review` suppresses ordinary activation. Dependencies are selected before their parent and may not silently bypass explicit-only or negation rules.

Every compilation records selected and rejected reasons, token accounting, body hashes, and a stable fingerprint. This makes the prompt decision inspectable instead of asking the model why it decided to load something after the fact, which is a charming but useless debugging ritual.

Explicit selection is passed with `explicit_skills/1`:

```prolog
?- skill_compile(Catalog,
                 "implement issue 117",
                 [explicit_skills([implement])],
                 ok(Compilation)).
```

If an explicitly requested skill or one of its required dependencies cannot fit the configured ceiling, compilation fails closed.

## Completion integration

Ordinary `rlm_completion/4` accepts a preloaded catalog:

```prolog
?- rlm_completion(
       "review the current change",
       text("opaque context"),
       [ skill_catalog(Catalog),
         skill_options([max_skill_prompt_tokens(4096)])
       ],
       Outcome).
```

The selected bodies are inserted into the root planner prompt before the planner model call. Successful results expose a `prompt_compilation.skills` summary. With no `skill_catalog/1` option, the existing completion path remains unchanged.

The optional bundled collection is pinned at `third_party/mattpocock-skills`:

```prolog
?- rlm_completion(
       "review this branch",
       text("opaque context"),
       [skill_catalog(bundled)],
       Outcome).
```

Initialize the submodule before using `bundled`. The exact upstream revision and license are recorded in `third_party/mattpocock-skills.PROVENANCE.md`.

## What this does not do

This slice does not add a model-callable Skill tool, let the model emit authorization facts, execute code from a skill, or unify tool/MCP/project-instruction budgeting yet. The skill compiler is the first concrete input type for the broader symbolic prompt compiler. Tools, MCP metadata, project instructions, rendering overhead, and managed rolling-context accounting still need to converge on the same bounded compilation ledger.
