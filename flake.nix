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
        nimGrammar = pkgs.tree-sitter.buildGrammar {
          language = "nim";
          version = "0.6.2";
          src = pkgs.fetchFromGitHub {
            owner = "alaviss";
            repo = "tree-sitter-nim";
            rev = "ac72ba30d16edf0be021588a9301ede4accd6cf4";
            sha256 = "0q6lqzpdwlj6pwdn7pb5aidkwv24mwpvr124175a9g2alysgqfnn";
          };
        };
        grammarPackages = {
          c = pkgs.tree-sitter-grammars.tree-sitter-c;
          lua = pkgs.tree-sitter-grammars.tree-sitter-lua;
          query = pkgs.tree-sitter-grammars.tree-sitter-query;
          python = pkgs.tree-sitter-grammars.tree-sitter-python;
          javascript = pkgs.tree-sitter-grammars.tree-sitter-javascript;
          markdown = pkgs.tree-sitter-grammars.tree-sitter-markdown;
          json = pkgs.tree-sitter-grammars.tree-sitter-json;
          org = pkgs.tree-sitter-grammars.tree-sitter-org-nvim;
          common_lisp = pkgs.tree-sitter-grammars.tree-sitter-commonlisp;
          nim = nimGrammar;
        };
        grammarBundle = pkgs.runCommand "prolog-rlm-tree-sitter-grammars" { } ''
          mkdir -p "$out"
          ${pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList
            (name: grammar: ''ln -s "${grammar}/parser" "$out/${name}"'')
            grammarPackages)}
        '';
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
        projectSyntaxCheck = pkgs.stdenv.mkDerivation {
          pname = "prolog-rlm-project-syntax-check";
          version = "0.1.0";
          src = self;
          nativeBuildInputs = [ swiProlog pkgs.pkg-config ];
          buildInputs = [ pkgs.tree-sitter ];

          buildPhase = ''
            runHook preBuild
            export LANG=C.UTF-8
            export LC_ALL=C.UTF-8
            make clean
            make tree-sitter-ffi
            mkdir -p test/fixtures/tree-sitter
            for language in c lua query python javascript markdown json org common_lisp nim; do
              ln -s "${grammarBundle}/$language" \
                "test/fixtures/tree-sitter/$language.$(swipl -q -g 'current_prolog_flag(shared_object_extension,E),write(E),halt.')"
            done
             swipl -q -g "use_module(prolog/rlm_tree_sitter),consult(test/rlm_project_syntax_test),consult(test/rlm_tree_sitter_query_test),consult(test/rlm_project_query_test),consult(test/rlm_project_query_restart_test),consult(test/rlm_tree_sitter_cancellation_test),run_tests([rlm_project_syntax,rlm_tree_sitter_query,rlm_project_query,rlm_project_query_restart,rlm_tree_sitter_cancellation]),halt"
            runHook postBuild
          '';

          installPhase = ''
            touch "$out"
          '';
        };
      in {
        packages.prolog-rlm = prologRlm;
        packages.tree-sitter-grammars = grammarBundle;
        packages.default = prologRlm;

        apps.swipl = {
          type = "app";
          program = "${prologRlm}/bin/prolog-rlm-swipl";
        };
        apps.default = self.apps.${system}.swipl;

        devShells.default = pkgs.mkShell {
          packages = [ swiProlog prologRlm pkgs.tree-sitter grammarBundle ];
          RLM_TREE_SITTER_GRAMMAR_DIR = "${grammarBundle}";
        };

        checks = {
          packaged-library-load = pkgs.runCommand "prolog-rlm-packaged-library-load" {
            nativeBuildInputs = [ swiProlog prologRlm ];
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME" "$TMPDIR/outside-source"
            cd "$TMPDIR/outside-source"
            swipl -q -g "use_module(library(rlm)),rlm:rlm_ready,rlm:rlm_agent_zero_adapter_ready,halt"
            touch "$out"
          '';

          wrapper-load = pkgs.runCommand "prolog-rlm-wrapper-load" {
            nativeBuildInputs = [ prologRlm ];
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME" "$TMPDIR/outside-source"
            cd "$TMPDIR/outside-source"
            prolog-rlm-swipl -q -g "use_module(library(rlm)),rlm:rlm_ready,rlm:rlm_agent_zero_adapter_ready,halt"
            touch "$out"
          '';
        } // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          project-syntax = projectSyntaxCheck;
        };
      });
}
