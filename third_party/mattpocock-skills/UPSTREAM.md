# mattpocock/skills provenance

This directory vendors selected stable skills from Matt Pocock's `mattpocock/skills` project for the default `prolog-rlm` skill catalog.

- Upstream repository: `https://github.com/mattpocock/skills`
- Pinned revision: `9c9f36ccd3995266cd675468af71639c8dde1ec5`
- Upstream license: MIT
- Upstream copyright: Copyright (c) 2026 Matt Pocock

Thank you to Matt Pocock for publishing the skill collection and making it available under the MIT License.

`prolog-rlm` does not preserve the upstream model-side invocation mechanism. The vendored Markdown remains third-party instructional material, while Prolog owns activation. `disable-model-invocation: true` is normalized to trusted explicit-user-only activation; other stable skills are eligible for deterministic Prolog selection.

The default vendored corpus intentionally excludes upstream `deprecated/` and `in-progress/` trees. Update the pin and copied files together; never fetch floating upstream skill content at runtime.
