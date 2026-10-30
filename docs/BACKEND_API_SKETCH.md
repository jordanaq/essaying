# Backend API Sketch

This document retains proposals for the Essaying API, based on
[PROMPT.md](PROMPT.md). Context sections were reconciled with the implementation
on 2026-10-26. Other proposed routes/types below are not evidence that an endpoint
exists; see `backend/src/Essaying/API/V1.hs` for current routing.

The implemented context contract is described in
[CONTEXT_DESIGN.md](CONTEXT_DESIGN.md#backend-and-ui-integration), with errors in
[CONTEXT_ERRORS.md](CONTEXT_ERRORS.md). Ordered contributing-file output is
stretch task L07, not an E04 requirement. Broader provider/setup documentation
reconciliation remains E13.

## Current provider scope and implementation direction (2026-10-27)

E06 supports any provider implementing the required OpenAI-compatible API.
Configure a provider base URL, API key, and model ID; OpenAI hosting is not
required. Proposed backend environment names are `OPENAI_BASE_URL` and
`OPENAI_API_KEY` (not implemented yet). Never accept provider credentials from
essay/context content or expose them to the browser, logs, or source control.
Select the effective context model, falling back to the account preference;
report an actionable error if neither is set. Unsupported provider endpoints or
capabilities must fail clearly; compatibility does not imply every provider
supports every OpenAI API feature. The specific upstream endpoint remains a
design choice and must match the compatibility contract we establish.

Work from the Essaying API downward: route and request/response contracts,
account-scoped handlers, backend context/model resolution, a provider interface,
then outgoing provider HTTP calls. E06 establishes provider integration; complete-response prompt generation and
grading behavior remain E07/E08. Streaming and user-initiated cancellation are
post-MVP stretch L10. MVP requests use bounded non-streaming provider calls and
return one complete JSON result or an HTTP error.

### AI endpoint starting proposal (not implemented or finalized)

Follow the current account-scoped workspace routes instead of the historical
unscoped AI routes below. Suggested public operations are:

- `POST /api/v1/accounts/:accountId/workspace/ai/prompt`
- `POST /api/v1/accounts/:accountId/workspace/ai/grade`

First settle the request DTOs and complete JSON response/error contract. Requests identify
an essay by a workspace-relative path; decide explicitly whether grading uses
saved content or supplied editor markdown so unsaved edits have predictable
behavior. Clients do not supply effective context, provider URLs, or credentials.
Handlers resolve the selected account and context in the backend, choose the
model, and retain one context snapshot per operation. Validate the complete
provider result before returning JSON; return actionable HTTP errors for
validation failures, provider failures, and bounded request timeouts. The UI
shows a pending state until success or failure. Public output must not expose
provider-private reasoning. These contracts guide E06's provider interface without requiring
E07/E08's complete implementation in this card.

### References for implementing the contracts

- Local route composition: `backend/src/Essaying/API/V1.hs` (`ContextApi`).
- JSON DTOs: `backend/src/Essaying/Types/Context.hs`.
- Handler composition and IO/errors: `backend/src/Essaying/Handler/Context.hs`.
- Account routing: `backend/src/Essaying/Handler/Account.hs`.
- HTTP contract tests: `backend/test/ContextErrors.hs`.
- [Servant: A web API as a type](https://docs.servant.dev/en/latest/tutorial/ApiType.html).
- [Servant: Serving an API](https://docs.servant.dev/en/latest/tutorial/Server.html).
- Later, outgoing HTTP: [http-client tutorial](https://github.com/snoyberg/http-client/blob/main/TUTORIAL.md).

## Goals

- Keep the API local-first and filesystem-backed.
- Scope all operations to a local user account.
- Use write-through persistence for consistency.
- Use REST/JSON for stateful operations.
- Use complete JSON responses for MVP AI operations; SSE is post-MVP L10.

## Runtime and Storage Contract

- Cache root resolution:
  - Use `HESSAY_CACHE` when set.
  - Otherwise default to `~/.cache/hessaying`.
- Per-account root:
  - `<cacheRoot>/users/<accountId>/workspace/...`
- API must reject any path traversal or out-of-root path access.

## API Versioning and Base Path

- Base path: `/api`
- Versioned path: `/api/v1`
- Content types:
  - JSON: `application/json`
  - Post-MVP SSE stream (L10): `text/event-stream`

## Authentication and Account Selection

This is a local app. Implemented account-scoped routes select the account with
`/api/v1/accounts/:accountId/workspace/...`. Context endpoints do not require
an `X-Account-Id` header. Account selection is not authentication; session
authentication is optional future scope.

Older header-based prototypes in the historical Servant sketch below describe
an abandoned route shape and must not be used as current API examples.

## Resource Model

- Account: local user profile and settings.
- Tree node: folder or essay file within account workspace.
- Essay: markdown content plus metadata.
- Context: effective merged context from `context.json` inheritance; source layers contain explicit operations.
- Rubric: grading criteria and weights.
- AI operation: prompt generation or grading, returning a complete JSON result.
- Post-MVP AI job stream (L10): incremental output/progress and terminal events.

## Proposed Endpoint List

### Health and Handshake

- `GET /api/v1/health`
  - Purpose: liveness check.
  - Response: `{ "status": "ok" }`

- `GET /api/v1/ready`
  - Purpose: backend handshake and sample effective context.
  - Response: `{ "message": "System Ready", "sampleContext": Context }`

### Accounts

- `POST /api/v1/accounts`
  - Purpose: create local account and workspace root.
  - Body: `CreateAccountRequest`
  - Response: `Account`

- `GET /api/v1/accounts`
  - Purpose: list local accounts.
  - Response: `[Account]`

- `GET /api/v1/accounts/:accountId`
  - Purpose: fetch account profile.
  - Response: `Account`

- `PATCH /api/v1/accounts/:accountId`
  - Purpose: update account preferences.
  - Body: `UpdateAccountRequest`
  - Response: `Account`

### Workspace Tree and Context

- `GET /api/v1/tree?path=<workspaceRelativePath>`
  - Purpose: list folder contents.
  - Response: `TreeListing`

- `POST /api/v1/tree/folder`
  - Purpose: create folder.
  - Body: `CreateFolderRequest`
  - Response: `TreeNode`

- `POST /api/v1/tree/essay`
  - Purpose: create markdown essay file.
  - Body: `CreateEssayRequest`
  - Response: `EssaySummary`

- `POST /api/v1/tree/rename`
  - Purpose: rename or move node.
  - Body: `RenameNodeRequest`
  - Response: `TreeNode`

- `DELETE /api/v1/tree?path=<workspaceRelativePath>`
  - Purpose: delete node.
  - Response: `DeleteResult`

### Context (implemented)

Base: `/api/v1/accounts/:accountId/workspace/context`.

| Method | Path/input | Success |
| --- | --- | --- |
| GET | `?path=History/context.json` | 200, `ContextLayer` with saved operations |
| GET | `/effective?path=History/essay.md` | 200, `EffectiveContext` with resolved values |
| POST | JSON `{"path":"History/context.json","contextLayer":{...}}` | 201, persisted `ContextLayer` |
| PUT | Same JSON body as POST | 200, persisted `ContextLayer` |
| DELETE | JSON `{"path":"History/context.json"}` | 204, no body |

No account header, absolute filesystem root, or path query is needed for
mutations. Use an existing parent folder and workspace-relative `context.json`
path. POST requires an absent layer (409 if present); PUT requires an existing
layer (404 if absent) and can repair malformed stored JSON. An absent layer GET
returns 404, while missing layers during effective resolution are skipped.

The effective response directly contains `title`, `audience`, `model`, `tags`,
`instructions`, `grading_directions`, and `rubric`. It has no response wrapper,
contributing-file list, or per-field provenance. Contributing-file output is
stretch L07; field provenance is L01. Full examples and UI limitations are in
[the context design](CONTEXT_DESIGN.md#backend-and-ui-integration).

The earlier unscoped context endpoints and YAML write proposal are superseded
by this account-scoped JSON contract. The tree/essay/AI sections elsewhere in
this document remain proposals where they differ from current source.

### Essays and Saving

- `GET /api/v1/essays?path=<workspaceRelativePath>`
  - Purpose: load essay markdown and metadata.
  - Response: `EssayDocument`

- `PUT /api/v1/essays?path=<workspaceRelativePath>`
  - Purpose: write-through save essay.
  - Body: `SaveEssayRequest`
  - Response: `SaveEssayResponse`

- `GET /api/v1/essays/history?path=<workspaceRelativePath>`
  - Purpose: list saved revisions (optional MVP+).
  - Response: `[EssayRevision]`

### Rubrics and Grading

- `GET /api/v1/rubrics/effective?path=<workspaceRelativePath>`
  - Purpose: fetch effective rubric from context inheritance.
  - Response: `Rubric`

- `POST /api/v1/grade`
  - Purpose: run grading for provided essay text or file path.
  - Body: `GradeRequest`
  - Response: `GradeResponse`

### Historical AI streaming proposal (post-MVP L10)

The following unscoped routes and stream types are retained for reference only.
They are not MVP endpoints. Use the account-scoped complete-response proposal
above for current work; any later streaming routes require a separate contract.

- `POST /api/v1/ai/prompt/stream`
  - Purpose: stream prompt generation tokens/events.
  - Body: `PromptStreamRequest`
  - Response: SSE `AiStreamEvent`

- `POST /api/v1/ai/draft/stream`
  - Purpose: stream drafting assistance.
  - Body: `DraftStreamRequest`
  - Response: SSE `AiStreamEvent`

- `POST /api/v1/ai/grade/stream`
  - Purpose: stream grading progress and final score/feedback payload; do not expose provider-private reasoning.
  - Body: `GradeStreamRequest`
  - Response: SSE `AiStreamEvent`

## Data Types (Sketch)

```haskell
newtype AccountId = AccountId Text
newtype WorkspacePath = WorkspacePath Text  -- normalized, relative, no ".."

data Account = Account
  { accountId :: AccountId
  , displayName :: Text
  , createdAt :: UTCTime
  , preferredModel :: Maybe Text
  }

data TreeNodeType = FolderNode | EssayNode

data TreeNode = TreeNode
  { path :: WorkspacePath
  , name :: Text
  , nodeType :: TreeNodeType
  }

data TreeListing = TreeListing
  { parent :: WorkspacePath
  , nodes :: [TreeNode]
  }

data EssayDocument = EssayDocument
  { path :: WorkspacePath
  , markdown :: Text
  , updatedAt :: UTCTime
  }

data SaveEssayRequest = SaveEssayRequest
  { markdown :: Text
  , expectedVersion :: Maybe Int
  }

data SaveEssayResponse = SaveEssayResponse
  { path :: WorkspacePath
  , version :: Int
  , updatedAt :: UTCTime
  }

-- Historical name for resolved values; current code uses EffectiveContext.
-- Writes use ContextLayer operations, not this resolved record.
data Context = Context
  { title :: Maybe Text
  , audience :: Maybe Text
  , model :: Maybe Text
  , tags :: [Text]
  , instructions :: [Text]
  , grading_directions :: [Text]
  , rubric :: Map Text RubricCriterion
  }

data RubricCriterion = RubricCriterion
  { weight :: Double
  , description :: Maybe Text
  }

data Rubric = Rubric
  { criteria :: Map Text RubricCriterion
  }

data GradeRequest = GradeRequest
  { path :: Maybe WorkspacePath
  , markdown :: Maybe Text
  , modelOverride :: Maybe Text
  }

data GradeResponse = GradeResponse
  { overallScore :: Double
  , criteriaScores :: Map Text Double
  , feedback :: Text
  }

-- Historical post-MVP L10 event sketch, not an MVP response type.
data AiStreamEvent
  = AiStarted { requestId :: Text, model :: Text }
  | AiToken { chunk :: Text }
  | AiProgress { percent :: Maybe Int, stage :: Text }
  | AiResult { payload :: Value }
  | AiError { code :: Text, message :: Text }
  | AiDone
```

## Servant Type Signatures (Sketch)

Implemented context routes, nested under
`"accounts" :> Capture "accountId" Text :> "workspace" :> "context"`:

```haskell
type ContextApi =
       "effective" :> QueryParam' '[Required, Strict] "path" FilePath :> Get '[JSON] EffectiveContext
  :<|> QueryParam' '[Required, Strict] "path" FilePath :> Get '[JSON] ContextLayer
  :<|> ReqBody '[JSON] ContextWriteRequest :> PostCreated '[JSON] ContextLayer
  :<|> ReqBody '[JSON] ContextWriteRequest :> Put '[JSON] ContextLayer
  :<|> ReqBody '[JSON] DeleteContextRequest :> DeleteNoContent
```

`ContextWriteRequest` preserves the JSON `path`/`contextLayer` envelope, with a
raw layer value validated in the handler. Invalid submitted layers therefore
return 422 instead of a request-decoding 400.

The following is a historical prototype for other proposed resources. Its
account-header routing and several types differ from the implementation.
Context routes have been removed from it to avoid conflicting examples. Its
streaming AI declarations are post-MVP L10 references, not current MVP contracts.


```haskell
type AccountHeader = Header' '[Required, Strict] "X-Account-Id" Text

type ApiV1 =
       "api" :> "v1" :>
         (    "health" :> Get '[JSON] HealthResponse
         :<|> "ready"  :> Get '[JSON] ReadyResponse

         :<|> AccountHeader :> "accounts" :> ReqBody '[JSON] CreateAccountRequest :> PostCreated '[JSON] Account
         :<|> AccountHeader :> "accounts" :> Get '[JSON] [Account]
         :<|> AccountHeader :> "accounts" :> Capture "accountId" Text :> Get '[JSON] Account
         :<|> AccountHeader :> "accounts" :> Capture "accountId" Text :> ReqBody '[JSON] UpdateAccountRequest :> Patch '[JSON] Account

         :<|> AccountHeader :> "tree" :> QueryParam' '[Required, Strict] "path" Text :> Get '[JSON] TreeListing
         :<|> AccountHeader :> "tree" :> "folder" :> ReqBody '[JSON] CreateFolderRequest :> PostCreated '[JSON] TreeNode
         :<|> AccountHeader :> "tree" :> "essay"  :> ReqBody '[JSON] CreateEssayRequest  :> PostCreated '[JSON] EssaySummary
         :<|> AccountHeader :> "tree" :> "rename" :> ReqBody '[JSON] RenameNodeRequest  :> Post '[JSON] TreeNode
         :<|> AccountHeader :> "tree" :> QueryParam' '[Required, Strict] "path" Text :> DeleteNoContent


         :<|> AccountHeader :> "essays" :> QueryParam' '[Required, Strict] "path" Text :> Get '[JSON] EssayDocument
         :<|> AccountHeader :> "essays" :> QueryParam' '[Required, Strict] "path" Text :> ReqBody '[JSON] SaveEssayRequest :> Put '[JSON] SaveEssayResponse

         :<|> AccountHeader :> "rubrics" :> "effective" :> QueryParam' '[Required, Strict] "path" Text :> Get '[JSON] Rubric
         :<|> AccountHeader :> "grade" :> ReqBody '[JSON] GradeRequest :> Post '[JSON] GradeResponse

         :<|> AccountHeader :> "ai" :> "prompt" :> "stream" :> ReqBody '[JSON] PromptStreamRequest :> StreamGet NewlineFraming EventStream AiStreamEvent
         :<|> AccountHeader :> "ai" :> "draft"  :> "stream" :> ReqBody '[JSON] DraftStreamRequest  :> StreamGet NewlineFraming EventStream AiStreamEvent
         :<|> AccountHeader :> "ai" :> "grade"  :> "stream" :> ReqBody '[JSON] GradeStreamRequest  :> StreamGet NewlineFraming EventStream AiStreamEvent
         )
```

## What Should Be Exposed

Expose publicly under `/api/v1`:

- Health/ready endpoints.
- Account profile and preferences.
- Workspace tree operations.
- Context and rubric read/write APIs.
- Essay load/save APIs.
- MVP account-scoped prompt and grade endpoints returning complete JSON.
- Streaming endpoints only in post-MVP L10; drafting remains optional L04.

Keep internal (not exposed):

- Direct filesystem absolute paths.
- Raw provider request internals and provider-specific chain-of-thought fields.
- Internal lock, cache, and merge-debug structures.
- Unnormalized path operations.

## Error Model

Context endpoints implement the envelope, status/code mappings, redaction, and
field diagnostics in [CONTEXT_ERRORS.md](CONTEXT_ERRORS.md). Invalid request
envelopes return 400; invalid stored/submitted context returns 422. That document
also records pending UI detail rendering and AI gating.

The generic envelope/status suggestions below are historical proposals for
other resources, not a description of current context responses:

```json
{
  "error": {
    "code": "PATH_OUTSIDE_WORKSPACE",
    "message": "Requested path escapes account workspace root.",
    "details": null
  }
}
```

Suggested status usage:

- `400` invalid request shape/path.
- `401` missing account header/session.
- `403` cross-account access attempt.
- `404` resource not found.
- `409` optimistic write version conflict.
- `422` invalid markdown/context payload.
- `500` internal error.
- `502` upstream provider unavailable/error (proposed mapping).

## Implementation Notes

- Preserve existing endpoint behavior by keeping `GET /api/ready` as temporary alias while moving to `/api/v1/ready`.
- Normalize `WorkspacePath` once at request boundary.
- Ensure all file operations are rooted under `<cacheRoot>/users/<accountId>/workspace`.
- Add request IDs for AI calls for diagnostics without logging credentials.

## MVP Cut (Historical Original Proposal)

This original cut includes streaming, which is now post-MVP L10. The current
MVP uses account-scoped prompt/grading endpoints returning complete JSON, as
described above; this list is not the current release checklist.

- `GET /api/v1/ready`
- `POST /api/v1/accounts`
- `GET /api/v1/tree`
- `GET /api/v1/accounts/:accountId/workspace/context/effective?path=<essayPath>`
- `GET /api/v1/essays`
- `PUT /api/v1/essays`
- `POST /api/v1/ai/grade/stream`

This set supports account bootstrap, tree browsing, context-aware loading, write-through editing, and streamed grading.
