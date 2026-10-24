{
  description = "Development environment for correio";

  inputs = {
    design-layer.url = "github:lostbean/design-layer/main";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      design-layer,
      nixpkgs,
      flake-utils,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # One derivation shared by the devShell and the mix-format formatter,
        # so `nix fmt` never formats with a different Elixir/OTP than the
        # shell actually runs prototypes on.
        elixirPackage = pkgs.beam29Packages.elixir_1_20;

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          settings.global.excludes = [
            "**/*.pdf"
            ".render/**"
          ];
          programs.gleam.enable = true;
          programs.mix-format = {
            enable = true;
            package = elixirPackage;
          };
          programs.ruff-format.enable = true;
          settings.formatter.ruff-format.includes = [
            "oracles/*.py"
            "benchmarks/*.py"
          ];
          programs.nixfmt.enable = true;
          programs.prettier.enable = true;
        };
      in
      {
        # Keep oracle inputs out of the shell closure; only comparisons use them.
        apps.oracle-phoenix-templates = {
          type = "app";
          program =
            let
              source = (builtins.fromJSON (builtins.readFile ./oracles/manifest.json)).phoenix;
              templates = pkgs.linkFarm "phoenix-oracle-templates" (
                pkgs.lib.mapAttrsToList (path: sha256: {
                  name = builtins.baseNameOf path;
                  path = pkgs.fetchurl {
                    url = "${
                      builtins.replaceStrings [ "https://github.com/" ] [ "https://raw.githubusercontent.com/" ]
                        source.source
                    }/${source.revision}/${path}";
                    inherit sha256;
                  };
                }) source.files
              );
            in
            "${pkgs.writeShellScript "oracle-phoenix-templates" ''
              printf '%s\n' ${templates}
            ''}";
        };
        apps.snips = design-layer.apps.${system}.snips;
        apps.design-gate-check = design-layer.apps.${system}.check;
        apps.design-gate-render = design-layer.apps.${system}.render;
        apps.design-gate-context = design-layer.apps.${system}.context;

        devShells.default = pkgs.mkShell {
          # Gleam and OTP run Correio; Elixir runs the pinned email and
          # authentication oracles. Node and Chromium exercise browser policy.
          packages =
            with pkgs;
            [
              lefthook
              gleam
              nodejs
              beam29Packages.erlang
              beam29Packages.rebar3
              elixirPackage
              ripgrep
              ruff
              # Disposable clusters for atomic challenge storage and fault tests.
              postgresql_16
              (python3.withPackages (pythonPackages: [ pythonPackages.jsonschema ]))
            ]
            ++ lib.optionals stdenv.hostPlatform.isLinux [
              chromium
              util-linux
            ];
        };

        formatter = treefmtEval.config.build.wrapper;

        checks.formatting = treefmtEval.config.build.check ./.;
      }
    );
}
