{
  description = "Development environment for correio";

  inputs = {
    design-layer.url = "github:lostbean/design-layer";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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

        # The upstream apps pin the renderer; authored imports also need its
        # generated local projection on a fresh checkout.
        designApp =
          name:
          let
            wrapper = pkgs.writeShellApplication {
              name = "design-gate-${name}";
              runtimeInputs = [ pkgs.coreutils ];
              text = ''
                project_layer() {
                  if [ -f "$1/design.typ" ]; then
                    mkdir -p "$1/.render"
                    cp -RL --remove-destination --no-preserve=mode ${
                      design-layer.packages.${system}.gate-bundle
                    }/render/. "$1/.render/"
                  fi
                }
                project_layer "''${1:-docs/design}"
                exec ${design-layer.apps.${system}.${name}.program} "$@"
              '';
            };
          in
          {
            type = "app";
            program = "${wrapper}/bin/design-gate-${name}";
          };

        # One derivation shared by the devShell and the mix-format formatter,
        # so `nix fmt` never formats with a different Elixir/OTP than the
        # shell actually runs prototypes on.
        elixirPackage = pkgs.beam28Packages.elixir;

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
          programs.nixfmt.enable = true;
          programs.prettier.enable = true;
        };
      in
      {
        apps.design-gate-check = designApp "check";
        apps.design-gate-render = designApp "render";
        apps.design-gate-context = designApp "context";

        devShells.default = pkgs.mkShell {
          # Gleam and OTP run Correio; Elixir runs the pinned email and
          # authentication oracles. Node and Chromium exercise browser policy.
          packages =
            with pkgs;
            [
              lefthook
              gleam
              nodejs
              beam28Packages.erlang
              rebar3
              elixirPackage
              actionlint
              shellcheck
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
