{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Essaying.API.V1
  ( Api
  )
where

import Essaying.Handler.Health (HealthResponse, ReadyResponse)
import Essaying.Types.Account (AccountProfile, CreateAccountRequest, UpdateAccountRequest)
import Essaying.Types.Workspace
  ( CreateWorkspaceDirectoryRequest
  , CreateWorkspaceEssayRequest
  , WorkspaceEssayContent
  , WorkspaceNode
  , WorkspaceTreeResponse
  )
import Servant (Capture, CaptureAll, DeleteNoContent, Get, JSON, Patch, PostCreated, ReqBody, (:<|>) (..), (:>))
import Data.Text (Text)


type Api =
  "api" :> "v1" :>
    (    "health" :> Get '[JSON] HealthResponse
    :<|> "ready"  :> Get '[JSON] ReadyResponse
    :<|> "accounts" :>
          (    Get '[JSON] [AccountProfile]
          :<|> ReqBody '[JSON] CreateAccountRequest :> PostCreated '[JSON] AccountProfile
          :<|> Capture "accountId" Text :>
                (    Get '[JSON] AccountProfile
                :<|> ReqBody '[JSON] UpdateAccountRequest :> Patch '[JSON] AccountProfile
                :<|> DeleteNoContent
                    :<|> "workspace" :>
                      (    Get '[JSON] WorkspaceTreeResponse
                      :<|> "essay" :> CaptureAll "path" Text :> Get '[JSON] WorkspaceEssayContent
                      :<|> "directories" :> ReqBody '[JSON] CreateWorkspaceDirectoryRequest :> PostCreated '[JSON] WorkspaceNode
                      :<|> "essays" :> ReqBody '[JSON] CreateWorkspaceEssayRequest :> PostCreated '[JSON] WorkspaceEssayContent
                      )
                )
          )
    )