{
  description = "Prolog-RLM and AgentProlog development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f (import nixpkgs { inherit system; }));
    in {
      devShells = forAllSystems (pkgs:
        let
          # Nixpkgs' Corepack package exposes pnpm/yarn shims and honors the
          # nearest package.json packageManager field. Binding it to Node 24
          # keeps the developer shell on the same runtime family as CI.
          corepack24 = pkgs.corepack.override {
            nodejs-slim = pkgs.nodejs-slim_24;
          };
        in {
          default = pkgs.mkShell {
            packages = [
              pkgs.nodejs_24
              corepack24
              pkgs.swiProlog
              pkgs.git
              pkgs.pkg-config
              pkgs.tree-sitter
            ];

            shellHook = ''
              export COREPACK_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/corepack"
            '';
          };
        });
    };
}
