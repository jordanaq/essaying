# Essaying Monorepo

Local-first essay platform with a Haskell backend and Svelte frontend.

## AI provider integration

Backend prompt and grading endpoints support providers implementing Chat
Completions with strict JSON-schema output. Configure `OPENAI_BASE_URL` and
`OPENAI_API_KEY` in the backend environment and select a model in context or
account preferences. Use the provider API base URL (for example,
`https://api.openai.com/v1`); the backend appends `/chat/completions`.
OpenAI hosting is not required. Credentials stay server-side. AI actions send relevant
essay text and context to the configured provider; local editing and saving do
not require provider access.

Backend prompt generation and grading return complete JSON responses. Frontend
generation/adoption and real grading/results integration remain E07–E09; the
current Grade button uses mock feedback. Streaming and user-initiated
cancellation are deferred to post-MVP stretch L10.

## Essay storage

`HESSAY_CACHE` selects the cache root; the default is `~/.cache/hessaying`.
Each account has `users/<accountId>/profile.json` and a `workspace/` directory:

```text
workspace/
├── context.json
└── History/
    ├── context.json
    └── Causes/
        ├── essay.md
        ├── prompt.md
        └── context.json
```

`History/Causes` identifies the essay. Its required `essay.md` stores the draft;
`prompt.md` is optional and stores the assignment. Context is optional at every
level and resolves from the workspace root through the essay's own directory.
The explorer shows essays as leaves. Draft and assignment save independently;
empty text clears a field, and deleting an essay removes its whole directory.
Context errors leave local editing and saving available.

The existing cache has been converted to this format. Migration is complete;
there is no startup conversion or legacy-layout verification step.
See [the storage contract](docs/ESSAY_DIRECTORY_PLAN.md),
[API reference](docs/BACKEND_API_SKETCH.md), and
[context contract](docs/CONTEXT_DESIGN.md).

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