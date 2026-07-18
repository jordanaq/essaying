{
  description = "A local-first essay platform in Haskell with a Svelte-based client";

  nixConfig = {
    allow-import-from-derivation = true;
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
    haskell-flake.url = "github:srid/haskell-flake";
  };

  outputs = inputs@{ flake-parts, haskell-flake, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      imports = [
        haskell-flake.flakeModule
      ];

      perSystem = { pkgs, config, ... }:
        let
          frontendLauncher = pkgs.writeShellApplication {
            name = "frontend";
            runtimeInputs = [ pkgs.nodejs_22 ];
            text = ''
              set -euo pipefail
              cd frontend

              if [ ! -d node_modules ]; then
                npm install
              fi

              exec npm run dev -- --host 127.0.0.1 --port 4173
            '';
          };

          devLauncher = pkgs.writeShellApplication {
            name = "dev";
            runtimeInputs = [ pkgs.nodejs_22 config.haskellProjects.backend.outputs.packages.haskell-essaying.package ];
            text = ''
              set -euo pipefail

              backend_log=$(mktemp)
              frontend_log=$(mktemp)

              cleanup() {
                if [ -n "''${backend_pid:-}" ]; then
                  kill "$backend_pid" 2>/dev/null || true
                fi
                if [ -n "''${frontend_pid:-}" ]; then
                  kill "$frontend_pid" 2>/dev/null || true
                fi
              }

              trap cleanup INT TERM EXIT

              (
                cd backend
                HESSAY_HTTP_LOG=1 "${config.haskellProjects.backend.outputs.packages.haskell-essaying.package}/bin/haskell-essaying" 2>&1 \
                  | sed -u 's/^/[backend] /' \
                  | tee "$backend_log"
              ) &
              backend_pid=$!

              (
                cd frontend
                if [ ! -d node_modules ]; then
                  npm install
                fi
                npm run dev -- --host 127.0.0.1 --port 4173 2>&1 \
                  | sed -u 's/^/[frontend] /' \
                  | tee "$frontend_log"
              ) &
              frontend_pid=$!

              echo "Backend log: $backend_log"
              echo "Frontend log: $frontend_log"
              wait -n "$backend_pid" "$frontend_pid"
              exit_code=$?

              cleanup
              exit "$exit_code"
            '';
          };

          testLauncher = pkgs.writeShellApplication {
            name = "test";
            runtimeInputs = [ pkgs.nix pkgs.nodejs_22 ];
            text = ''
              set -euo pipefail

              (
                cd backend
                nix --accept-flake-config develop -c \
                  cabal test haskell-essaying-test --test-show-details=streaming
              )

              if [ -f frontend/package.json ]; then
                (cd frontend && npm test)
              fi
            '';
          };

          cleanLauncher = pkgs.writeShellApplication {
            name = "clean";
            runtimeInputs = [ pkgs.nix ];
            text = ''
              set -euo pipefail

              (
                cd backend
                nix --accept-flake-config develop -c cabal clean
              )

              echo "Backend build artifacts cleaned."
            '';
          };
        in {
        haskellProjects.backend = {
          projectRoot = ./backend;
          basePackages = pkgs.haskellPackages;
          autoWire = [ "packages" "apps" "checks" ];

          devShell = {
            hlsCheck.enable = false;
            tools = hp: {
              cabal = hp.cabal-install;
              hls = hp.haskell-language-server;
              ghcid = pkgs.ghcid;
            };
          };
        };

        packages.default = config.haskellProjects.backend.outputs.packages.haskell-essaying.package;
        packages.backend = config.haskellProjects.backend.outputs.packages.haskell-essaying.package;
        packages.frontend = frontendLauncher;
        packages.dev = devLauncher;
        packages.test = testLauncher;
        packages.clean = cleanLauncher;
        apps.default = config.haskellProjects.backend.outputs.apps.haskell-essaying;
        apps.backend = config.haskellProjects.backend.outputs.apps.haskell-essaying;
        apps.frontend = {
          type = "app";
          program = "${pkgs.lib.getExe frontendLauncher}";
        };
        apps.dev = {
          type = "app";
          program = "${pkgs.lib.getExe devLauncher}";
        };
        apps.test = {
          type = "app";
          program = "${pkgs.lib.getExe testLauncher}";
        };
        apps.clean = {
          type = "app";
          program = "${pkgs.lib.getExe cleanLauncher}";
        };

        devShells.default = pkgs.mkShell {
          name = "essay-monorepo-shell";
          inputsFrom = [ config.haskellProjects.backend.outputs.devShell ];
          packages = [
            pkgs.git
            pkgs.fish
            pkgs.nodejs_22
          ];

          shellHook = ''
            echo "Monorepo dev shell ready"
            echo "Backend project root: ./backend"
          '';
        };
      };
    };
}
