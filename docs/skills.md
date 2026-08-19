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

Activation is not authorization. A selected skill can change model-visible instructions, but it cannot register a callable, grant a tool capability, change authority mode, start an MCP server, execute a bundled script, or bypass the existing execution policy.

## Skill format

A skill directory contains `SKILL.md`. Discovery parses only this frontmatter subset:

```yaml
---
name: tdd
description: Test-driven development. Use when the request is about test-first implementation.
disable-model-invocation: false
---
```

The Markdown body is not read during catalog discovery. Unknown frontmatter keys are ignored and never interpreted as Prolog. After Prolog selects a skill, the body and bounded recursive text resources under that skill directory are read and rendered into the planner instruction. Resource types include Markdown, text, shell templates, configuration, and common source formats. They remain inert text even when their filename is executable-looking.

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
- `skill_catalog(default|none|Catalog)` on completion
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

## Distribution overlays

Third-party skill documents stay inert and may contain routing syntax for another runtime. `prolog-rlm` does not rewrite that text and does not emulate a model-callable router. Instead, a trusted distribution overlay can translate known compatibility relationships into ordinary compiler rules.

The pinned Matt Pocock distribution uses `rlm_skill_mattpocock:mattpocock_skill_rules/1`. For example, upstream `grill-me` is explicit-user-only and says to call a `Skill` tool with `grilling`; the trusted overlay represents that as:

```prolog
requires('grill-me', grilling).
```

An explicit host selection of `grill-me` therefore causes Prolog dependency closure to select `grilling` before the planner request exists. The model sees both compiled instruction bodies but never performs the activation itself. Custom catalogs do not receive Matt-specific rules automatically; hosts supply their own `skill_rules/1` when needed.

## Completion boundary

`rlm_skill_completion` wraps the canonical guarded completion predicate inside the scheduled completion task. This means public `rlm:rlm_completion/4`, lower-level `rlm_completion:rlm_completion/4`, managed conversation paths, and the CLI all reach the same Prolog skill-compilation boundary before a planner request exists. A compilation fingerprint marker prevents nested facades from injecting the same skill prompt twice.

`skill_catalog(none)` or `skill_mode(off)` preserves the non-skill path. Existing caller `planner_instruction` content is retained unchanged and no catalog or skill body is exposed to the model.

## Prompt budget

Skill files are assigned a conservative byte-based prompt-token estimate at discovery time. Selection is bounded by both `skill_max_count` and `skill_max_tokens`; only admitted skill bodies/resources are read. This is a skill-local ceiling, not a replacement for the completion provider's measured token/cost budget.

The compiled result records selected skills, rejected skills with structured reasons, estimated prompt tokens, and a stable fingerprint over catalog/input/compiler state.

## Resource confinement

`skill_read_resource/3` accepts only relative paths and resolves them under the selected skill directory. Catalog scanning and resource loading reject descendant symlinks before following them, then re-check the resolved path remains inside the configured root. Absolute paths, missing files, `..` traversal, symlink escapes, oversized resources, and non-text resources are rejected.

Recursive resource discovery deliberately supports nested inert templates such as `scripts/*.sh` because the pinned upstream collection references them. Loading such text does not grant process or shell authority.

## Default and complete Matt Pocock distribution

The repository carries two forms of the same pinned upstream revision `9c9f36ccd3995266cd675468af71639c8dde1ec5`:

- `third_party/mattpocock-skills/upstream` is a git submodule pin to the complete upstream repository;
- `third_party/mattpocock-skills/skills` is a vendored stable fallback used by source archives and CI checkouts that do not initialize submodules.

Initialize the complete collection with:

```sh
git submodule update --init third_party/mattpocock-skills/upstream
```

When the submodule is initialized, `skill_catalog(default)` automatically prefers the complete pinned `upstream/skills` tree. When it is absent, the same completion path falls back to the vendored stable corpus. No runtime network fetch occurs in either case. The scanner excludes `deprecated/` and `in-progress/` unless explicitly configured otherwise.

A host may also load either tree explicitly with `skill_catalog_load/3`. Runtime compatibility belongs in Prolog overlay rules, not edits to upstream Markdown. The upstream collection remains third-party material under its MIT license. See `third_party/mattpocock-skills/UPSTREAM.md` and `LICENSE` for provenance and attribution.
