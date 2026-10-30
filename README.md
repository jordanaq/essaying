# Essaying Monorepo

Local-first essay platform with a Haskell backend and Svelte frontend.

Create or select a local account, organize essays into folders, edit inherited
JSON context, generate assignment candidates, and grade saved drafts. Account
selection is local routing, without passwords or authentication. Filesystem/API
hardening and complete restart/isolation workflow validation remain pending.

## AI provider integration

Backend prompt and grading endpoints support providers implementing Chat
Completions with strict JSON-schema output. Configure `OPENAI_BASE_URL` and
`OPENAI_API_KEY` in the backend environment and select a model in context or
account preferences. Use the provider API base URL (for example,
`https://api.openai.com/v1`); the backend appends `/chat/completions`.
OpenAI hosting is not required. Credentials stay server-side. AI actions send relevant
essay text and context to the configured provider; local editing and saving do
not require provider access.

Prompt generation and grading return complete JSON responses. The frontend can
generate and adopt assignment prompts and grade saved essays, displaying overall
and per-criterion feedback. Grading requires valid effective context with a
nonempty rubric of finite positive total weight, a selected model, and a saved
nonblank draft. An essay-local context file and assignment are optional.
Streaming and user-initiated cancellation are deferred to post-MVP stretch L10.

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

Access the backend at `http://127.0.0.1:8080`. Warp uses `run 8080`;
the startup URL does not configure a loopback-only bind address.

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
npm ci
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


## Configure the backend

Set these variables in the shell that starts the backend (or the combined dev
launcher). No `.env` loader is configured; exporting values after startup does
not update an already running process.

| Variable | Behavior |
| --- | --- |
| `HESSAY_CACHE` | Cache root; missing or blank uses `~/.cache/hessaying`. Relative paths resolve against the backend's working directory; use an absolute path for consistent launcher behavior. |
| `OPENAI_BASE_URL` | Required for AI actions; provider API base URL, including a version prefix such as `/v1`, without `/chat/completions`. |
| `OPENAI_API_KEY` | Required for AI actions; a nonblank, single-line Bearer token. |
| `HESSAY_HTTP_LOG` | Enables backend request logging for exactly `1`, `true`, `yes`, or `on`. The combined dev launcher sets it to `1`. |
| `HESSAY_DEBUG` | Optional numeric debug level; leave unset to disable debug output. |

For example, in Bash, before starting the backend:

```bash
export OPENAI_BASE_URL='https://api.openai.com/v1'
read -rsp 'Provider API key: ' OPENAI_API_KEY
printf '\n'
export OPENAI_API_KEY
```

Choose the provider's exact model ID in saved context or when creating an
account. The saved context model takes precedence over the account preference.
The editor toolbar model selector is currently a local placeholder and does not
change AI requests. Context accepts custom model IDs; the curated suggestions
are a snapshot rather than automatic discovery of the configured provider.

Prompt generation sends effective context and optional generation instructions;
it does not send the draft or saved assignment. Grading sends effective context,
the saved draft, and the optional saved assignment as separate inputs. Neither
endpoint saves its result. Adopt a generated candidate and select **Save Prompt**
to persist it. Feedback is currently transient; grading history is future work.

## Build and verify

Use the repository's Nix development shell for GHC/Cabal, Node, and Playwright
browser paths. Without Nix, install compatible dependencies described in
`backend/haskell-essaying.cabal` and `frontend/package.json` and provision Chromium
for Playwright yourself. A fresh setup has not yet been validated end to end.

From the repository root:

```bash
nix --accept-flake-config develop
```

Inside that shell, install frontend dependencies and run checks:

```bash
(cd frontend && npm ci)
(cd backend && cabal build)
(cd backend && cabal test haskell-essaying-test --test-show-details=direct)
(cd frontend && npm test)
(cd frontend && npm run build)
```

The frontend build includes Svelte/TypeScript checking. Regular backend tests
use temporary workspaces and controlled local providers, without paid API calls.
The separate 120-second provider deadline check is opt-in; see the
[provider fixture notes](backend/test/fixtures/provider/README.md#failure-and-deadline-checks).

For browser checks, first stop any backend on port 8080 so Playwright starts one
with the isolated cache, then run inside the development shell:

```bash
HESSAY_CACHE="$(mktemp -d /tmp/essaying-e2e.XXXXXX)" bash -c 'cd frontend && npm run e2e'
```

Playwright starts a backend on 8080 and a temporary frontend on 4175 (override
with `PLAYWRIGHT_FRONTEND_PORT`). It reuses an existing backend outside CI, so an
already running process would ignore the isolated cache setting above. Live
account/context scenarios create and delete test accounts; other scenarios use
mock APIs. Keep the temporary cache if investigating failures. Browser checks
do not yet establish the complete live AI/restart workflow.

## Troubleshooting

- If the UI cannot load accounts, check that the backend is running on 8080.
  `curl http://127.0.0.1:8080/api/v1/health` checks liveness; `/api/v1/ready`
  returns empty sample context and does not validate storage or provider access.
- If essays seem missing after changing launchers, check `HESSAY_CACHE` and use
  the same absolute cache path. Invalid profiles can also make account listing
  fail; back up files before repairing them.
- If context blocks AI, inspect the layer error, repair the saved `context.json`,
  and retry the preview. Draft and assignment editing/saving remain available.
  Use the [context examples](docs/CONTEXT_DESIGN.md) and
  [error contract](docs/CONTEXT_ERRORS.md) for valid operations and error details.
- If generation or grading fails, check the backend environment, exact model ID,
  and provider support for Chat Completions with strict JSON-schema output.
  Errors distinguish authentication/access, missing model/endpoint, quota,
  unsupported capabilities, invalid responses, and connection failures.
- Provider calls have a 60-second response timeout and a 120-second overall
  deadline, without automatic application retries. A timeout returns 504; retry
  explicitly or select a faster compatible model.

For optional live provider checks, see the [prompt smoke sample](backend/examples/provider-smoke/README.md)
and [grading smoke sample](backend/examples/grade-smoke/README.md). Those commands
send real requests when explicitly run and can incur provider charges.

## Documentation map

- [Project layout](docs/PROJECT_LAYOUT.md)
- [Implemented API](docs/BACKEND_API_SKETCH.md)
- [Essay-directory storage](docs/ESSAY_DIRECTORY_PLAN.md)
- [Context inheritance](docs/CONTEXT_DESIGN.md) and [context failures](docs/CONTEXT_ERRORS.md)
- [Frontend behavior and checks](frontend/README.md)
- [Historical research brief](docs/PROMPT.md)
