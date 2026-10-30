# Essaying Monorepo

Local-first essay platform with a Haskell backend and Svelte frontend.

## Planned AI provider integration (E06)

AI operations will support any provider implementing the required
OpenAI-compatible API, with a configurable provider base URL, API key, and model
ID. OpenAI hosting is not required. Proposed backend environment settings are
`OPENAI_BASE_URL` and `OPENAI_API_KEY`; provider integration and these settings
are not implemented yet. Credentials stay server-side. AI actions send relevant
essay text and context to the configured provider; local editing and saving do
not require provider access.

MVP prompt generation and grading will return complete JSON responses, with a
pending state in the UI. Streaming and user-initiated cancellation are deferred
to post-MVP stretch L10.

## Start Components

Run all commands from the repository root.

### Backend (API)

Start backend with Nix:

```bash
nix --accept-flake-config run .#backend
```

Default backend app command also works:

```bash
nix --accept-flake-config run .#default
```

Backend serves on `127.0.0.1:8080`.

### Frontend (UI)

Start frontend with Nix:

```bash
nix --accept-flake-config run .#frontend
```

Frontend serves on `127.0.0.1:4173` and proxies `/api` to backend on `127.0.0.1:8080`.

### Backend + Frontend Together

Start both components at once:

```bash
nix --accept-flake-config run .#dev
```

### Optional: Start Without Nix (Manual)

Backend:

```bash
cd backend
cabal run haskell-essaying
```

Frontend:

```bash
cd frontend
npm install
npm run dev -- --host 127.0.0.1 --port 4173
```

## Useful Development Commands

Open development shell:

```bash
nix develop
```

Build backend package:

```bash
nix build .#default
```