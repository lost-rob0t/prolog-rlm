# mattpocock/skills provenance

This directory integrates Matt Pocock's `mattpocock/skills` collection for the `prolog-rlm` skill compiler.

- Upstream repository: `https://github.com/mattpocock/skills`
- Pinned revision: `9c9f36ccd3995266cd675468af71639c8dde1ec5`
- Upstream license: MIT
- Upstream copyright: Copyright (c) 2026 Matt Pocock

Thank you to Matt Pocock for publishing the skill collection and making it available under the MIT License.

The complete upstream repository is pinned as the git submodule `third_party/mattpocock-skills/upstream`. Initialize it with:

```sh
git submodule update --init third_party/mattpocock-skills/upstream
```

`third_party/mattpocock-skills/skills` remains a vendored stable fallback so ordinary source archives and CI checkouts that do not initialize submodules still have a deterministic default catalog. The fallback intentionally excludes upstream `deprecated/` and `in-progress/` trees. The submodule preserves the complete pinned upstream collection for callers that want the full catalog rather than the fallback subset.

`prolog-rlm` does not preserve the upstream model-side invocation mechanism. The Markdown remains third-party instructional material, while Prolog owns discovery and activation. `disable-model-invocation: true` is normalized to trusted explicit-user-only activation; other stable skills are eligible for deterministic Prolog selection. Skill resources are loaded only after Prolog selects a skill and remain inert text, including shell templates.

Never fetch floating upstream skill content at runtime. Updating the collection means reviewing and updating the pinned submodule revision, provenance, fallback corpus where applicable, and deterministic skill tests together.
