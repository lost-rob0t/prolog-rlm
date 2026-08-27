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
        swiProlog = pkgs."swi-prolog";
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
            makeWrapper ${swiProlog}/bin/swipl "$out/bin/prolog-rlm-swipl" \
              --prefix SWIPL_PACK_PATH : "${packRoot}"
            runHook postInstall
          '';
        };

        installedPackRoot = "${prologRlm}/share/swi-prolog/pack";

        agentProlog = pkgs.stdenvNoCC.mkDerivation {
          pname = "agentprolog";
          version = "0.1.0";
          src = self;
          dontBuild = true;
          nativeBuildInputs = [ pkgs.makeWrapper ];

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/share/agentprolog/bin"
            mkdir -p "$out/share/agentprolog/agentProlog"
            cp bin/agentprolog.pl "$out/share/agentprolog/bin/agentprolog.pl"
            cp -R agentProlog/prolog "$out/share/agentprolog/agentProlog/prolog"
            mkdir -p "$out/bin"
            makeWrapper ${swiProlog}/bin/swipl "$out/bin/agentprolog" \
              --prefix SWIPL_PACK_PATH : "${installedPackRoot}" \
              --add-flags "-q" \
              --add-flags "-s" \
              --add-flags "$out/share/agentprolog/bin/agentprolog.pl" \
              --add-flags "--"
            runHook postInstall
          '';
        };

        deepseekHarness = pkgs.buildGoModule {
          pname = "agentprolog-deepseek-harness";
          version = "0.1.0";
          src = ./harness/deepseek_tui;
          vendorHash = pkgs.lib.fakeHash;
          nativeBuildInputs = [ pkgs.makeWrapper ];

          postInstall = ''
            if [ -x "$out/bin/deepseek_tui" ]; then
              mv "$out/bin/deepseek_tui" "$out/bin/deepseek-harness"
            fi
            wrapProgram "$out/bin/deepseek-harness" \
              --prefix PATH : ${pkgs.lib.makeBinPath [ agentProlog ]}
          '';
        };
      in {
        packages.prolog-rlm = prologRlm;
        packages.agentprolog = agentProlog;
        packages.deepseek-harness = deepseekHarness;
        packages.default = prologRlm;

        apps.swipl = {
          type = "app";
          program = "${prologRlm}/bin/prolog-rlm-swipl";
        };
        apps.agentprolog = {
          type = "app";
          program = "${agentProlog}/bin/agentprolog";
        };
        apps.deepseek-harness = {
          type = "app";
          program = "${deepseekHarness}/bin/deepseek-harness";
        };
        apps.default = self.apps.${system}.swipl;

        devShells.default = pkgs.mkShell {
          packages = [ swiProlog prologRlm agentProlog pkgs.go ];
        };

        checks.packaged-library-load = pkgs.runCommand "prolog-rlm-packaged-library-load" {
          nativeBuildInputs = [ swiProlog prologRlm ];
        } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME" "$TMPDIR/outside-source"
          cd "$TMPDIR/outside-source"
          swipl -q -g "use_module(library(rlm)),rlm:rlm_ready,rlm:rlm_agent_zero_adapter_ready,halt"
          touch "$out"
        '';

        checks.wrapper-load = pkgs.runCommand "prolog-rlm-wrapper-load" {
          nativeBuildInputs = [ prologRlm ];
        } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME" "$TMPDIR/outside-source"
          cd "$TMPDIR/outside-source"
          prolog-rlm-swipl -q -g "use_module(library(rlm)),rlm:rlm_ready,rlm:rlm_agent_zero_adapter_ready,halt"
          touch "$out"
        '';

        checks.agentprolog-product = pkgs.runCommand "agentprolog-product" {
          nativeBuildInputs = [ swiProlog prologRlm agentProlog ];
        } ''
          export HOME="$TMPDIR/home"
          export XDG_CONFIG_HOME="$TMPDIR/config"
          mkdir -p "$HOME" "$XDG_CONFIG_HOME"
          swipl -q -s ${self}/agentProlog/test/run.pl
          agentprolog help | grep -q '^AgentProlog$'
          touch "$out"
        '';

        checks.deepseek-harness = pkgs.runCommand "agentprolog-deepseek-harness" {
          nativeBuildInputs = [ deepseekHarness ];
        } ''
          deepseek-harness --check | grep -q 'agentprolog-deepseek-tui: ready'
          touch "$out"
        '';
      });
}
