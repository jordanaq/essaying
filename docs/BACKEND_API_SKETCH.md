# Backend API Sketch

This document proposes the backend API surface for the Essaying platform, based on the requirements in [prompt.md](../prompt.md).

## Goals

- Keep the API local-first and filesystem-backed.
- Scope all operations to a local user account.
- Use write-through persistence for consistency.
- Use REST/JSON for stateful operations.
- Use SSE for AI streaming operations.

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
  - SSE stream: `text/event-stream`

## Authentication and Account Selection

This is a local app. Prefer a simple account selector token in early versions, then harden later.

- Request header (initial): `X-Account-Id: <accountId>`
- Optional future session cookie: `hessay_session`
- Every endpoint except `/health` and `/ready` requires account context.

## Resource Model

- Account: local user profile and settings.
- Tree node: folder or essay file within account workspace.
- Essay: markdown content plus metadata.
- Context: effective merged context from `context.yaml` inheritance.
- Rubric: grading criteria and weights.
- AI job stream: prompt generation, drafting, grading events.

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

- `GET /api/v1/context/effective?path=<workspaceRelativePath>`
  - Purpose: fetch merged context from root to path.
  - Response: `Context`

- `PUT /api/v1/context?path=<workspaceRelativePath>`
  - Purpose: write or replace `context.yaml` at path.
  - Body: `Context`
  - Response: `Context`

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

### AI Prompting and Streaming (SSE)

- `POST /api/v1/ai/prompt/stream`
  - Purpose: stream prompt generation tokens/events.
  - Body: `PromptStreamRequest`
  - Response: SSE `AiStreamEvent`

- `POST /api/v1/ai/draft/stream`
  - Purpose: stream drafting assistance.
  - Body: `DraftStreamRequest`
  - Response: SSE `AiStreamEvent`

- `POST /api/v1/ai/grade/stream`
  - Purpose: stream grading reasoning and final score payload.
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

data Context = Context
  { title :: Maybe Text
  , audience :: Maybe Text
  , model :: Maybe Text
  , instructions :: [Text]
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

data AiStreamEvent
  = AiStarted { requestId :: Text, model :: Text }
  | AiToken { chunk :: Text }
  | AiProgress { percent :: Maybe Int, stage :: Text }
  | AiResult { payload :: Value }
  | AiError { code :: Text, message :: Text }
  | AiDone
```

## Servant Type Signatures (Sketch)

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

         :<|> AccountHeader :> "context" :> "effective" :> QueryParam' '[Required, Strict] "path" Text :> Get '[JSON] Context
         :<|> AccountHeader :> "context" :> QueryParam' '[Required, Strict] "path" Text :> ReqBody '[JSON] Context :> Put '[JSON] Context

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
- AI streaming endpoints for prompt/draft/grade.

Keep internal (not exposed):

- Direct filesystem absolute paths.
- Raw Ollama request internals and provider-specific chain-of-thought fields.
- Internal lock, cache, and merge-debug structures.
- Unnormalized path operations.

## Error Model

Use JSON error envelope for all non-stream endpoints:

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
- `502` Ollama unavailable/error.

## Implementation Notes

- Preserve existing endpoint behavior by keeping `GET /api/ready` as temporary alias while moving to `/api/v1/ready`.
- Normalize `WorkspacePath` once at request boundary.
- Ensure all file operations are rooted under `<cacheRoot>/users/<accountId>/workspace`.
- Add request IDs for stream and grading calls for diagnostics.

## MVP Cut (First Implement)

- `GET /api/v1/ready`
- `POST /api/v1/accounts`
- `GET /api/v1/tree`
- `GET /api/v1/context/effective`
- `GET /api/v1/essays`
- `PUT /api/v1/essays`
- `POST /api/v1/ai/grade/stream`

This set supports account bootstrap, tree browsing, context-aware loading, write-through editing, and streamed grading.
