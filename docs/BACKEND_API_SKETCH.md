# Backend API contract

Reviewed against `backend/src/Essaying/API/V1.hs` and its request/response types
on 2026-10-30. This file retains its original filename; the routes below describe
the implemented API. Rename/move, revision history, streaming, and separate
rubric-generation endpoints remain future work.

## Runtime and storage

`HESSAY_CACHE` selects the cache root, defaulting to `~/.cache/hessaying`.
Account profiles are at `<cacheRoot>/users/<accountId>/profile.json`; workspaces
are at `<cacheRoot>/users/<accountId>/workspace/`.

An essay is a non-root directory containing a regular, non-symlink `essay.md`.
The directory path is its identity, such as `History/Causes`. `essay.md` contains
the draft; optional `prompt.md` contains the assignment; optional `context.json`
provides the essay-local context layer. The explorer represents essays as leaves.
Creation inside an essay is rejected. Deleting an essay removes its whole
directory, including any extra files. Draft and assignment are independent files.

The cache conversion is complete. There is no startup migration, legacy alias,
or further legacy-layout validation requirement. See the
[essay-directory contract](ESSAY_DIRECTORY_PLAN.md).

## Accounts and routing

All routes start with `/api/v1`. Local account selection is routing context,
not authentication; no `X-Account-Id` header is required.

| Method | Route | Success |
| --- | --- | --- |
| GET | `/health` | 200, `HealthResponse` |
| GET | `/ready` | 200, `ReadyResponse` |
| GET | `/accounts` | 200, list of account profiles |
| POST | `/accounts` | 201, created profile from `CreateAccountRequest` |
| GET | `/accounts/:accountId` | 200, account profile |
| PATCH | `/accounts/:accountId` | 200, profile updated with `UpdateAccountRequest` |
| DELETE | `/accounts/:accountId` | 204 |

## Workspace and essay routes

Base: `/api/v1/accounts/:accountId/workspace`.
Path components in route captures must be URL-encoded individually. Creation
bodies use arrays of directory-name segments; context and AI bodies use
workspace-relative strings with forward slashes.

| Method | Suffix | Input | Success |
| --- | --- | --- | --- |
| GET | (base) | None | 200, `{"tree":[...]}` |
| POST | `/directories` | `{"parentPath":[],"directoryName":"History"}` | 201, `WorkspaceNode` |
| DELETE | `/directories/History` | Folder path in URL | 204 |
| POST | `/essays` | Creation body below | 201, essay content |
| GET | `/essays/History/Causes` | Essay directory in URL | 200, essay content |
| PUT | `/essays/History/Causes` | Exactly one of `markdown` or `prompt` | 200, reloaded essay content |
| DELETE | `/essays/History/Causes` | Essay directory in URL | 204 |

Tree nodes have `name`, `path` (a segment array), `nodeType`
(`WorkspaceDirectoryNode` or `WorkspaceEssayNode`), and `children`. Essay nodes
have no children. Their names come from their directories, independent of the
context `title` field.

Create an essay:

```json
{
  "parentPath": ["History"],
  "essayName": "Causes",
  "markdown": "",
  "prompt": "Explain the causes of the revolution."
}
```

Initial `markdown` and `prompt` are optional. Omitting both creates a blank draft
without a prompt file. Creation rejects existing destinations and cleans up a
new directory if creation fails.

Essay content responses contain:

```json
{
  "path": ["History", "Causes"],
  "title": "Causes",
  "markdown": "",
  "prompt": "Explain the causes of the revolution."
}
```

A missing prompt loads as an empty string. An unreadable prompt is a load error.
Save one field at a time, for example `{"markdown":"Updated draft"}` or
`{"prompt":""}`. Omitted fields stay unchanged; empty strings persist and clear
the selected field. Nulls, unknown keys, empty updates, and two-field updates are
rejected. Successful responses must not replace unsaved sibling editor text.

The handler reloads both fields after a save. The deferred L11 issue remains:
an invalid unrelated prompt file can make that reload fail after a draft write
has succeeded. This does not reopen migration work.

## Context routes

Base: `/api/v1/accounts/:accountId/workspace/context`.

| Method | Path/input | Success |
| --- | --- | --- |
| GET | `?path=History/Causes/context.json` | 200, saved `ContextLayer` operations |
| GET | `/effective?path=History/Causes` | 200, resolved `EffectiveContext` |
| POST | `{"path":"History/Causes/context.json","contextLayer":{...}}` | 201, persisted layer |
| PUT | Same body as POST | 200, persisted layer |
| DELETE | `{"path":"History/Causes/context.json"}` | 204 |

Layer paths identify `context.json` files at the workspace root, organizational
folders, or an essay directory. Effective-context paths identify the essay
directory, without `/essay.md`. Resolution includes the workspace root,
organizational ancestors, and the essay's own layer, in that order.

Parent directories must exist. POST requires an absent layer (409 if present);
PUT requires an existing layer (404 if absent) and can repair malformed stored
JSON. An absent layer GET returns 404. Missing layers during effective resolution
are skipped; invalid layers fail resolution without returning partial context.

Effective responses directly contain `title`, `audience`, `model`, `tags`,
`instructions`, `grading_directions`, and `rubric`. There is no response wrapper,
contributing-file list, or per-field provenance. See
[context inheritance](CONTEXT_DESIGN.md#backend-and-ui-integration) and
[context errors](CONTEXT_ERRORS.md). Ordered contributing files remain L07 and
field provenance remains L01.

## AI routes

Base: `/api/v1/accounts/:accountId/workspace/ai`.

| Method | Suffix | Body | Success |
| --- | --- | --- | --- |
| POST | `/prompt` | `{"path":"History/Causes","instructions":"Offer two options."}` | 200, `{"prompts":["..."]}` |
| POST | `/grade` | `{"path":"History/Causes"}` | 200, grade response below |

`instructions` is optional for prompt generation. Both endpoints currently
require an existing essay directory. Prompt generation uses its effective
context and optional extra instructions without sending the draft. It returns
nonempty Markdown candidates and does not save `prompt.md`.

Grading loads the saved draft and optional saved assignment as distinct inputs,
resolves context, and requires a nonblank draft and a finite, positive total
rubric weight before calling the provider. Missing/empty assignments are allowed.
It validates exact criterion names, finite scores from 0 to 100, and nonblank
feedback. The application calculates normalized weights and the overall score:

```json
{
  "overallScore": 80,
  "feedback": "A clear argument with room for stronger support.",
  "criteria": {
    "evidence": {
      "score": 80,
      "feedback": "Support the central claim with a specific example.",
      "normalizedWeight": 1
    }
  }
}
```

AI operations resolve one context snapshot per request and never persist their
results. Browser edits must be saved to become grading inputs. Clients do not
supply effective context, provider URLs, or credentials.

### Provider configuration and failures

Set `OPENAI_BASE_URL` and `OPENAI_API_KEY` in the backend environment. The adapter
appends `/chat/completions` to the API base URL and uses Bearer authentication,
non-streaming Chat Completions, and strict JSON-schema output. Select the model
in effective context or, as fallback, account preferences. Providers and models
must support the required endpoint and schema capability.

Calls are bounded and return a complete validated JSON result or an error.
Provider failures use application-owned corrective messages without raw provider
diagnostics or credentials. Missing model/invalid grading inputs return 422;
configuration errors return 500; upstream/invalid-response failures generally
return 502; timeouts return 504. Context errors retain their documented JSON
envelope; other handlers do not uniformly use that envelope.

The frontend connects prompt generation/adoption and real grading/results to
these complete-response endpoints. It requires saved/discarded pending edits
before grading, displays overall and criterion feedback, and labels results for
earlier inputs when editing continues. Effective context can be inherited; no
essay-local context file or assignment is required. Streaming and user
cancellation are post-MVP L10; explorer/folder generation is stretch L15 after
rubric generation L12.
