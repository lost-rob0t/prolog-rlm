# Skill packages

`rlm_skill` is the confined package layer for Agent Skills. It discovers
ordinary `SKILL.md` packages and converts them to the existing
`prompt_unit{unit:skill(Name), ...}` input accepted by
`rlm_prompt_compiler`. It does not contain an independent selector, lexical
scorer, dependency resolver, token packer, or prompt renderer.

## Progressive disclosure

The package boundary has three explicit stages:

1. `skill_catalog_load/3` admits only bounded package files. It reads bounded
   `SKILL.md` and resource bytes to compute SHA-256 fingerprints, parses the
   frontmatter, and indexes resources, but retains neither instruction nor
   resource content.
2. `skill_prompt_unit/3` defaults to `load_content(true)`: it rereads bounded
   `SKILL.md` bytes, verifies them against the admitted instruction SHA-256,
   and puts the stripped inert body in the prompt unit's `content` field. With
   host option `load_content(false)`, it does not open the instruction file and
   emits the same canonical routing metadata with `content:none`. It never
   reads resource bodies.
3. `skill_read_resource/3` explicitly reads one indexed, confined text
   resource and verifies its admitted fingerprint before returning content.
   Reading a script or template grants no execution authority.

The canonical prompt compiler owns selection, typed dependency resolution,
conflicts, scoring, packing, explanations, and provider-context fingerprints.

## Public API

```prolog
skill_catalog_empty(-Catalog).
skill_catalog_load(+Roots, +Options, -Outcome).
skill_catalog_merge(+A, +B, -Outcome).
skill_catalog_skills(+Catalog, -Skills).
skill_catalog_skill(+Catalog, +Name, -Skill).
skill_default_catalog(-Outcome).
skill_default_catalog_reset.
skill_prompt_unit(+Skill, +HostOptions, -Outcome).
skill_catalog_prompt_units(+Catalog, +HostOptions, -Outcome).
skill_read_resource(+Skill, +RelativePath, -Outcome).
```

A root may be source-labelled trusted host configuration:

```prolog
skill_catalog_load([skill_root(project, ".agents/skills")], [], ok(Catalog)).
```

`skill_prompt_unit/3` accepts host-owned `load_content(true|false)`,
`activation(relevant|always)`,
`available/1`, `provider_visible/1`, `mandatory_context/1`, `priority/1`,
`requires_capability/1`, and `category/1` options. Activation defaults to
`relevant`; any other value is rejected. A package cannot self-declare
provenance, availability, `activation:always`, mandatory context, provider
visibility, capabilities, handlers, authority, or effect permission. The
default is provider-visible but not mandatory.

`disable-model-invocation: true` is recognized for Claude compatibility. The
converted unit defaults to `available:false`, so it cannot route
automatically. A trusted host may explicitly override availability as part of
its activation policy. If both Claude metadata and the portable extension
disable automatic activation, the restrictive result wins.

Portable `activation.automatic` metadata may only narrow ordinary automatic
routing. It never maps to prompt-unit `activation:always`. Extra activation
keys or values such as `mode: always` are rejected structurally. Only the
trusted `HostOptions` argument can emit `activation:always`.

## Standard metadata

The required portable frontmatter is:

```yaml
---
name: review-pr
description: Review a pull request for correctness and regressions.
---
```

The body is inert instruction content. Unknown simple top-level fields are not
executed. `allowed-tools`, when present in third-party material, is advisory
text only and never grants a Prolog capability or authority.

This slice also supports the approved standard string extension form:

```yaml
metadata:
  prolog-rlm: |-
    {
      "schema": 1,
      "category": "review",
      "aliases": ["pr review"],
      "triggers": [
        {"kind": "phrase", "value": "review pull request", "weight": 80}
      ],
      "requires": [{"kind": "tool", "name": "git_diff"}],
      "suggests": [],
      "conflicts": [],
      "supersedes": [],
      "requires_capability": null,
      "priority": 200,
      "activation": {"automatic": true}
    }
```

JSON is parsed as data, never as a Prolog term. Schema v1 supports bounded
category, aliases, triggers, priority, automatic activation, and typed
`skill`, `tool`, and `resource` relationships. Unknown keys, kinds, malformed
values, unknown schema versions, and non-null capability descriptors are
reported as structured `unsupported_prolog_rlm_metadata(...)` faults rather
than guessed or partially executed. Capability descriptors remain host-owned
in this bounded slice.

## Prompt-unit mapping

The conversion maps package fields as follows:

- name to `unit:skill(Name)` and `name:Name`;
- description, category, aliases, triggers, and typed relationships to their
  existing prompt-unit fields;
- the verified, bounded Markdown body to inert `content`, or `content:none`
  without opening the body when `load_content(false)` is selected;
- source plus package fingerprint to bounded provenance;
- host options to `activation:relevant|always`, availability, provider
  visibility, mandatory context, priority, and capability requirement;
- resources remain on the loaded skill's index and are not bulk-loaded into
  the prompt unit.

The resulting dictionary can be passed directly to
`prompt_catalog_register/3`. Host registration and compile input determine
activation. A skill's text cannot promote itself to always-active or
mandatory.

## Default and optional catalogs

The stable default runtime catalog is `skills/core/`. It contains the concise
`rlm-operate`, `rlm-recurse`, `rlm-facts`, and `rlm-constraints` packages.
Canonical RLM completion applies trusted host policy that marks these units
always-active, mandatory, and provider-visible. `skill_mode(off)`,
`skill_catalog(none)`, and `disabled_skills/1` are trusted host controls; user
or model prose cannot unpin them.

`third_party/mattpocock-skills/` is an optional pinned coding-skill
distribution, not ambient core behavior. Thanks to Matt Pocock for publishing
that collection under the MIT License. The vendored material remains inert,
is never fetched at runtime, and does not grant tools or execution authority.

## Confinement and bounds

Scanning is restricted to configured roots. Every descendant path is checked
lexically, each descendant symlink is rejected before canonicalization, and
the canonical path is checked again against the root. Resource reads accept
only paths in the admitted `Skill.resources` index and reject traversal,
absolute paths, symlinks, non-text files, missing files, `SKILL.md`, and files
created after admission. Bounded reads hash the bytes actually read and check
the path again afterward; changed instruction or resource bytes are rejected
and are never returned or injected.

The exact package limits are:

- 16 configured roots per catalog load;
- 4,096 visited directory entries per configured root scan and a separate
  4,096 visited directory entries per skill package scan; these totals include
  ignored directories and non-text files, not only admitted skills and text
  resources;
- 100 KiB total bytes per `SKILL.md`, checked before frontmatter parsing or
  hashing;
- 64 KiB of frontmatter and 32 KiB of stripped body bytes when content is
  loaded;
- 512 KiB per text resource, 128 resources per skill, and 4 MiB aggregate
  resource bytes per skill;
- 256 skills per configured root and 512 skills per catalog, including merged
  catalogs;
- 16 descendant directory levels while scanning either a catalog root or a
  skill's resources.

These are admission ceilings, not authority grants. Catalog admission reads
bounded bytes for fingerprints but discards their content. Prompt bodies and
resource text remain unavailable until their explicit disclosure operation.
