{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Essaying.API.V1 (
  Api,
  AccountsApi,
  AccountApi,
  WorkspaceApi,
  EssayApi,
  ContextApi,
  AiApi,
)
where

import Data.Text (Text)
import Essaying.Types.Account (AccountProfile, CreateAccountRequest, UpdateAccountRequest)
import Essaying.Types.Ai (GradeRequest, GradeResponse, PromptRequest, PromptResponse)
import Essaying.Types.Context (ContextLayer, ContextWriteRequest, DeleteContextRequest, EffectiveContext)
import Essaying.Types.Health (HealthResponse, ReadyResponse)
import Essaying.Types.Workspace (
  CreateWorkspaceDirectoryRequest,
  CreateWorkspaceEssayRequest,
  SaveWorkspaceEssayRequest,
  WorkspaceEssayContent,
  WorkspaceNode,
  WorkspaceTreeResponse,
 )
import Servant (Capture, CaptureAll, DeleteNoContent, Get, JSON, Patch, Post, PostCreated, Put, QueryParam', ReqBody, Required, Strict, (:<|>) (..), (:>))

-- | Version-one API rooted at @/api/v1@, with health, readiness, and account routes.
type Api =
  "api"
    :> "v1"
    :> ( "health" :> Get '[JSON] HealthResponse
           :<|> "ready" :> Get '[JSON] ReadyResponse
           :<|> "accounts" :> AccountsApi
       )

-- | List or create accounts, or select an account by its captured ID.
type AccountsApi =
  Get '[JSON] [AccountProfile]
    :<|> ReqBody '[JSON] CreateAccountRequest :> PostCreated '[JSON] AccountProfile
    :<|> Capture "accountId" Text :> AccountApi

-- | Read, patch, or delete a selected account, or access its workspace.
type AccountApi =
  Get '[JSON] AccountProfile
    :<|> ReqBody '[JSON] UpdateAccountRequest :> Patch '[JSON] AccountProfile
    :<|> DeleteNoContent
    :<|> "workspace" :> WorkspaceApi

{- | Account-scoped workspace tree, essay, directory, context, and AI operations.
Captured workspace paths are lists of directory-name segments.
-}
type WorkspaceApi =
  Get '[JSON] WorkspaceTreeResponse
    :<|> "essays" :> CaptureAll "path" Text :> EssayApi
    :<|> "essays" :> ReqBody '[JSON] CreateWorkspaceEssayRequest :> PostCreated '[JSON] WorkspaceEssayContent
    :<|> "directories" :> CaptureAll "path" Text :> DeleteNoContent
    :<|> "directories" :> ReqBody '[JSON] CreateWorkspaceDirectoryRequest :> PostCreated '[JSON] WorkspaceNode
    :<|> "context" :> ContextApi
    :<|> "ai" :> AiApi

-- | Read, update one content field, or delete the essay at the captured directory path.
type EssayApi =
  Get '[JSON] WorkspaceEssayContent
    :<|> ReqBody '[JSON] SaveWorkspaceEssayRequest :> Put '[JSON] WorkspaceEssayContent
    :<|> DeleteNoContent

{- | Paths identify workspace-relative context.json files, except for effective
context, whose path identifies an essay. Filesystem roots stay server-side.
-}
type ContextApi =
  "effective" :> QueryParam' '[Required, Strict] "path" FilePath :> Get '[JSON] EffectiveContext
    :<|> QueryParam' '[Required, Strict] "path" FilePath :> Get '[JSON] ContextLayer
    :<|> ReqBody '[JSON] ContextWriteRequest :> PostCreated '[JSON] ContextLayer
    :<|> ReqBody '[JSON] ContextWriteRequest :> Put '[JSON] ContextLayer
    :<|> ReqBody '[JSON] DeleteContextRequest :> DeleteNoContent

{- | Complete-response AI operations under the selected account's workspace.
Request paths identify existing essay directories. Provider credentials and
resolved context stay server-side; neither route persists its generated result.
-}
type AiApi =
  "prompt" :> ReqBody '[JSON] PromptRequest :> Post '[JSON] PromptResponse
    :<|> "grade" :> ReqBody '[JSON] GradeRequest :> Post '[JSON] GradeResponse
