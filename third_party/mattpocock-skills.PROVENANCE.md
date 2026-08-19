# Matt Pocock skills provenance

`third_party/mattpocock-skills` is a git submodule pinned to Matt Pocock's public `skills` repository.

- Upstream: `https://github.com/mattpocock/skills`
- Pinned commit: `9c9f36ccd3995266cd675468af71639c8dde1ec5`
- License: MIT, preserved in `third_party/mattpocock-skills.LICENSE`
- Upstream author: Matt Pocock

The upstream collection is used as an optional bundled skill catalog. `prolog-rlm` does not execute the Markdown files. The trusted Prolog skill compiler reads bounded metadata, selects relevant skills, and injects only selected instruction bodies into model-visible planner context.

Initialize the pinned distribution with:

```sh
git submodule update --init --recursive third_party/mattpocock-skills
```

Updating the pin is an explicit dependency update: review the upstream diff, preserve license/provenance, update this commit hash, and run the deterministic skill/compiler gates before merging.
