# Prolog-owned skill activation

`prolog-rlm` treats skills as inert instruction documents compiled into a turn by Prolog. The model does not receive a skill router, a skill-selection tool, or the full skill catalog.

## Runtime flow

```text
user/runtime input
      |
      v
SKILL.md metadata catalog
      |
      v
Prolog signal scoring + explicit host selections
      |
      v
dependency/conflict/budget resolution
      |
      v
selected skill bodies + bounded local resources
      |
      v
planner instruction
      |
      v
model
```

Activation is not authorization. A selected skill can change model-visible instructions, but it cannot register a callable, grant a tool capability, change authority mode, start an MCP server, or bypass the existing execution policy.

## Skill format

A skill directory contains `SKILL.md`. Discovery parses only this frontmatter subset:

```yaml
---
name: tdd
description: Test-driven development. Use when the request is about test-first implementation.
disable-model-invocation: false
---
```

The Markdown body is not read during catalog discovery. Unknown frontmatter keys are ignored and never interpreted as Prolog. After Prolog selects a skill, the body and sibling `.md`/`.txt` resources are read and rendered into the planner instruction.

`disable-model-invocation: true` is normalized as `explicit_user`. In `prolog-rlm` that name is historical compatibility metadata: it means **automatic Prolog activation is disabled**. A trusted host may still select the skill with `explicit_skills([...])`.

Legacy text inside third-party skills that says to call a `Skill` tool is inert. `prolog-rlm` intentionally exposes no such model-callable tool; Prolog owns activation.

## Public catalog API

```prolog
skill_catalog_load(+Roots, +Options, -Outcome).
skill_catalog_merge(+A, +B, -Outcome).
skill_catalog_skills(+Catalog, -Skills).
skill_catalog_skill(+Catalog, +Name, -Skill).
skill_compile(+Catalog, +Input, +Options, -Outcome).
skill_prompt_fragment(+Compiled, -Prompt).
```

A root may be a path or a trusted source-labelled term:

```prolog
skill_catalog_load(
    [skill_root(project, ".agents/skills")],
    [],
    ok(Catalog)).
```

Catalog entries contain only normalized metadata and canonical file locations. They contain no executable handler terms.

## Compiler options

The first deterministic compiler slice supports:

- `skill_mode(auto|off)`
- `skill_catalog(default|none|Catalog)` on the public completion facade
- `explicit_skills(Names)` for trusted explicit user/host selections
- `disabled_skills(Names)` for hard host exclusions
- `skill_min_score(N)`
- `skill_max_count(N)`
- `skill_max_tokens(N)`
- `skill_rules(Rules)`

Rules are trusted host data:

```prolog
skill_rules([
    alias(tdd, "red green refactor"),
    trigger('diagnosing-bugs', "debug this", 80),
    requires(tdd, 'codebase-design'),
    conflicts(prototype, tdd),
    priority(tdd, 10)
]).
```

Supported rules are `alias/2`, `trigger/3`, `requires/2`, `conflicts/2`, and `priority/2`. Dependencies close transitively. Missing, disabled, or explicit-user-only required dependencies fail closed instead of silently weakening the selected skill.

Automatic evidence is deterministic: exact skill-name phrases, aliases, configured trigger phrases, and normalized lexical overlap with the skill name/description contribute scores. Explicit trusted selection dominates heuristic evidence. Common negation forms such as `do not use tdd` suppress ordinary automatic activation.

## Prompt budget

Skill files are assigned a conservative byte-based prompt-token estimate at discovery time. Selection is bounded by both `skill_max_count` and `skill_max_tokens`; only admitted skill bodies are read. This is a skill-local ceiling, not a replacement for the completion provider's measured token/cost budget.

The compiled result records selected skills, rejected skills with structured reasons, estimated prompt tokens, and a stable fingerprint over catalog/input/compiler state.

## Resource confinement

`skill_read_resource/3` accepts only relative paths and resolves them canonically under the selected skill directory. Absolute paths, missing files, and `..`/symlink escapes are rejected. Discovery likewise canonicalizes paths beneath each configured root.

## Default distribution

The repository pins a copy of Matt Pocock's `mattpocock/skills` under `third_party/mattpocock-skills/`. The default catalog is loaded from its stable vendored skill set when present. Deprecated and experimental/in-progress material is not part of the default vendored corpus.

The upstream collection remains third-party material under its MIT license. See `third_party/mattpocock-skills/UPSTREAM.md` and `LICENSE` for provenance and attribution.
