{
  description = "Prolog-native Recursive Language Model runtime";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        packRoot = "$out/share/swi-prolog/pack";
        prologRlm = pkgs.stdenvNoCC.mkDerivation {
          pname = "prolog-rlm";
          version = "0.1.0";
          src = self;
          dontBuild = true;
          nativeBuildInputs = [ pkgs.makeWrapper ];

          installPhase = ''
            runHook preInstall
            mkdir -p ${packRoot}/prolog_rlm
            cp -R pack.pl prolog ${packRoot}/prolog_rlm/
            mkdir -p "$out/nix-support" "$out/bin"
            cat > "$out/nix-support/setup-hook" <<EOF
            addPrologRlmPackPath() {
              addToSearchPath SWIPL_PACK_PATH "${packRoot}"
            }
            addEnvHooks "$targetOffset" addPrologRlmPackPath
            EOF
            makeWrapper ${pkgs.swiProlog}/bin/swipl "$out/bin/prolog-rlm-swipl" \
              --prefix SWIPL_PACK_PATH : "${packRoot}"
            runHook postInstall
          '';
        };
      in {
        packages.prolog-rlm = prologRlm;
        packages.default = prologRlm;

        apps.swipl = {
          type = "app";
          program = "${prologRlm}/bin/prolog-rlm-swipl";
        };
        apps.default = self.apps.${system}.swipl;

        devShells.default = pkgs.mkShell {
          packages = [ pkgs.swiProlog prologRlm ];
        };

        checks.packaged-library-load = pkgs.runCommand "prolog-rlm-packaged-library-load" {
          nativeBuildInputs = [ pkgs.swiProlog prologRlm ];
        } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME" "$TMPDIR/outside-source"
          cd "$TMPDIR/outside-source"
          swipl -q -g "use_module(library(rlm)),halt"
          touch "$out"
        '';

        checks.wrapper-load = pkgs.runCommand "prolog-rlm-wrapper-load" {
          nativeBuildInputs = [ prologRlm ];
        } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME" "$TMPDIR/outside-source"
          cd "$TMPDIR/outside-source"
          prolog-rlm-swipl -q -g "use_module(library(rlm)),halt"
          touch "$out"
        '';
      });
}
