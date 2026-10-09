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

              exec ./node_modules/.bin/vite --host 127.0.0.1 --port 4173
            '';
          };

          devLauncher = pkgs.writeShellApplication {
            name = "dev";
            runtimeInputs = [ pkgs.nodejs_22 config.haskellProjects.backend.outputs.packages.haskell-essaying.package ];
            text = ''
              set -euo pipefail

              pkill -f 'vite --host 127.0.0.1 --port 4173' 2>/dev/null || true
              pkill -f 'haskell-essaying backend on http://127.0.0.1:8080' 2>/dev/null || true
              pkill -f 'haskell-essaying/bin/haskell-essaying' 2>/dev/null || true

              cleanup() {
                if [ -n "''${backend_pid:-}" ]; then
                  kill "$backend_pid" 2>/dev/null || true
                  wait "$backend_pid" 2>/dev/null || true
                fi
                if [ -n "''${frontend_pid:-}" ]; then
                  kill "$frontend_pid" 2>/dev/null || true
                  wait "$frontend_pid" 2>/dev/null || true
                fi
              }

              trap 'exit 130' INT
              trap 'exit 143' TERM
              trap cleanup EXIT

              if [ ! -d frontend/node_modules ]; then
                (cd frontend && npm install)
              fi

              (
                cd backend
                exec env HESSAY_HTTP_LOG=1 "${config.haskellProjects.backend.outputs.packages.haskell-essaying.package}/bin/haskell-essaying"
              ) &
              backend_pid=$!

              (
                cd frontend
                exec ./node_modules/.bin/vite --host 127.0.0.1 --port 4173
              ) &
              frontend_pid=$!

              wait -n "$backend_pid" "$frontend_pid"
            '';
          };

          testLauncher = pkgs.writeShellApplication {
            name = "test";
            runtimeInputs = [
              pkgs.nix
              pkgs.nodejs_22
              pkgs.playwright-driver
              pkgs.curl
              config.haskellProjects.backend.outputs.packages.haskell-essaying.package
            ];
            text = ''
              set -euo pipefail
              export PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}"
              export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

              (
                cd backend
                nix --accept-flake-config develop -c \
                  cabal test haskell-essaying-test --test-show-details=streaming
              )

              if [ -f frontend/package.json ]; then
                (cd frontend && npm test)

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
                  "${config.haskellProjects.backend.outputs.packages.haskell-essaying.package}/bin/haskell-essaying" >"$backend_log" 2>&1
                ) &
                backend_pid=$!

                (
                  cd frontend
                  npm run dev -- --host 127.0.0.1 --port 4173 >"$frontend_log" 2>&1
                ) &
                frontend_pid=$!

                for _ in $(seq 1 60); do
                  if curl -fsS http://127.0.0.1:8080/api/v1/health >/dev/null 2>&1 && \
                     curl -fsS http://127.0.0.1:4173 >/dev/null 2>&1; then
                    break
                  fi
                  sleep 1
                done

                if ! curl -fsS http://127.0.0.1:8080/api/v1/health >/dev/null 2>&1; then
                  echo "Backend did not become ready"
                  echo "Backend log: $backend_log"
                  exit 1
                fi

                if ! curl -fsS http://127.0.0.1:4173 >/dev/null 2>&1; then
                  echo "Frontend did not become ready"
                  echo "Frontend log: $frontend_log"
                  exit 1
                fi

                (cd frontend && npm run e2e)
                cleanup
                trap - INT TERM EXIT
              fi
            '';
          };

          cleanLauncher = pkgs.writeShellApplication {
            name = "clean";
            runtimeInputs = [ pkgs.nix ];
            text = ''
              set -euo pipefail

              pkill -f 'vite --host 127.0.0.1 --port 4173' 2>/dev/null || true
              pkill -f 'haskell-essaying backend on http://127.0.0.1:8080' 2>/dev/null || true
              pkill -f 'haskell-essaying/bin/haskell-essaying' 2>/dev/null || true

              (
                cd backend
                nix --accept-flake-config develop -c cabal clean
              )

              rm -rf frontend/dist
              rm -rf frontend/node_modules/.vite
              rm -rf frontend/test-results
              rm -rf frontend/playwright-report
              rm -rf frontend/coverage

              echo "Backend and frontend build artifacts cleaned."
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
            pkgs.playwright-driver
          ];

          shellHook = ''
            export PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}"
            export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
            echo "Monorepo dev shell ready"
            echo "Backend project root: ./backend"
            echo "Playwright browsers path: $PLAYWRIGHT_BROWSERS_PATH"
          '';
        };
      };
    };
}
