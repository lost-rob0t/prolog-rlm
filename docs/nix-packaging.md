# Nix flake packaging

`prolog-rlm` remains an SWI-Prolog pack. The Nix flake packages that same runtime rather than introducing a second plugin or copied runtime.

## Outputs

For each default flake system the repository exposes:

- `packages.<system>.prolog-rlm`
- `packages.<system>.default`
- `apps.<system>.swipl`
- `apps.<system>.default`
- `devShells.<system>.default`
- `checks.<system>.packaged-library-load`
- `checks.<system>.wrapper-load`

The package installs the SWI pack at:

```text
$out/share/swi-prolog/pack/prolog_rlm
```

and exports a Nix setup hook that adds `$out/share/swi-prolog/pack` to `SWIPL_PACK_PATH`. SWI-Prolog attaches packs from `SWIPL_PACK_PATH` at startup, so a downstream derivation can put the package in `nativeBuildInputs`, `buildInputs`, or its runtime environment and continue using the canonical public entrypoint:

```prolog
:- use_module(library(rlm)).
```

The package also provides `prolog-rlm-swipl`, a convenience wrapper that attaches exactly this packaged pack path before starting the Nix-provided SWI-Prolog runtime.

## Downstream flake

A downstream product should depend on the runtime directly rather than cloning it or routing it through `rlm_tool_loader`:

```nix
{
  inputs.prolog-rlm.url = "github:lost-rob0t/prolog-rlm";
  inputs.prolog-rlm.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, prolog-rlm, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      runtime = prolog-rlm.packages.${system}.default;
    in {
      packages.${system}.my-agent = pkgs.writeShellApplication {
        name = "my-agent";
        runtimeInputs = [ pkgs.swiProlog runtime ];
        text = ''
          exec swipl -q -g "use_module(library(rlm)),halt" -- "$@"
        '';
      };
    };
}
```

This is the intended AgentProlog dependency direction:

```text
AgentProlog -> prolog-rlm
```

Concrete coding tools and frontend plugins remain downstream. `config.prolog` remains trusted runtime/operator configuration. Neither is the package boundary.

## Verification

`nix flake check` must prove that `library(rlm)` loads from the built package while the current working directory is outside the source checkout. CI repeats this check explicitly and also exercises the packaged wrapper. This preserves the existing clean-pack invariant rather than accepting a build that succeeds only because source-relative imports happen to be visible.
