# Project layout

Essaying uses a Haskell/Servant API and a Svelte/TypeScript frontend, with
account-scoped files under the configured cache root.

## Source and checks

| Path | Purpose |
| --- | --- |
| `backend/app/Main.hs` | Warp entrypoint on port 8080 and optional HTTP logging |
| `backend/src/Essaying/API/V1.hs` | Account, workspace, context, and AI routes |
| `backend/src/Essaying/Handler/` | HTTP orchestration and failure mapping |
| `backend/src/Essaying/Persistence/` | Account, essay, and context filesystem operations |
| `backend/src/Essaying/Context.hs` | Context inheritance rules |
| `backend/src/Essaying/Provider/` | OpenAI-compatible Chat Completions adapter |
| `backend/src/Essaying/Types/` | API, context, storage, and provider types |
| `backend/test/` | HUnit API, persistence, context, and controlled-provider regressions |
| `backend/examples/` | Optional manual prompt/grading provider smoke samples |
| `frontend/src/` | App, explorer, editors, context panel, prompt generation, and grading feedback |
| `frontend/src/*.test.ts` | Vitest component/integration tests |
| `frontend/e2e/` | Playwright browser scenarios, using live and mocked APIs |
| `frontend/playwright.config.ts` | Browser setup and temporary test servers |
| `docs/` | Current contracts plus the historical research brief |
| `flake.nix`, `flake.lock` | Nix dependencies, development shell, launchers, and backend package |

The backend remains Cabal-described; `haskell-flake` uses `./backend` as its
project root. Runtime profiles and essays live outside source by default, at
`~/.cache/hessaying/users/<accountId>/`; see the
[storage contract](ESSAY_DIRECTORY_PLAN.md).

## Entrypoints

Run from the repository root:

- `nix --accept-flake-config develop`: development shell with backend tools,
  Node, and Playwright browser paths.
- `nix --accept-flake-config build .#default`: backend package.
- `nix --accept-flake-config run .#backend`: backend only (`.#default` is an alias).
- `nix --accept-flake-config run .#frontend`: Vite development server on 4173.
- `nix --accept-flake-config run .#dev`: combined development launcher; stops
  matching existing dev processes before starting its backend/frontend pair.

See [README.md](../README.md#build-and-verify) for dependency installation and
backend, component, build, and isolated browser checks. The `.#test` launcher
also exists, but starts servers against the inherited cache; Playwright then
manages a separate frontend on 4175. Prefer the documented isolated browser
command when checking account mutations.
