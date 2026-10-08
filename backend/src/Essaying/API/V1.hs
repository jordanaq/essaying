{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Essaying.API.V1 (
    Api,
)
where

import Data.Text (Text)
import Essaying.Handler.Health (HealthResponse, ReadyResponse)
import Essaying.Types.Account (AccountProfile, CreateAccountRequest, UpdateAccountRequest)
import Essaying.Types.Workspace (
    CreateWorkspaceDirectoryRequest,
    CreateWorkspaceEssayRequest,
    SaveWorkspaceEssayRequest,
    WorkspaceEssayContent,
    WorkspaceNode,
    WorkspaceTreeResponse,
 )
import Servant (Capture, CaptureAll, DeleteNoContent, Get, JSON, Patch, PostCreated, Put, ReqBody, (:<|>) (..), (:>))

type Api =
    "api"
        :> "v1"
        :> ( "health" :> Get '[JSON] HealthResponse
                :<|> "ready" :> Get '[JSON] ReadyResponse
                :<|> "accounts"
                    :> ( Get '[JSON] [AccountProfile]
                            :<|> ReqBody '[JSON] CreateAccountRequest :> PostCreated '[JSON] AccountProfile
                            :<|> Capture "accountId" Text
                                :> ( Get '[JSON] AccountProfile
                                        :<|> ReqBody '[JSON] UpdateAccountRequest :> Patch '[JSON] AccountProfile
                                        :<|> DeleteNoContent
                                        :<|> "workspace"
                                            :> ( Get '[JSON] WorkspaceTreeResponse
                                                    :<|> "essays"
                                                        :> CaptureAll "path" Text
                                                        :> ( Get '[JSON] WorkspaceEssayContent
                                                                :<|> ReqBody '[JSON] SaveWorkspaceEssayRequest :> Put '[JSON] WorkspaceEssayContent
                                                                :<|> DeleteNoContent
                                                           )
                                                    :<|> "essays" :> ReqBody '[JSON] CreateWorkspaceEssayRequest :> PostCreated '[JSON] WorkspaceEssayContent
                                                    :<|> "directories" :> CaptureAll "path" Text :> DeleteNoContent
                                                    :<|> "directories" :> ReqBody '[JSON] CreateWorkspaceDirectoryRequest :> PostCreated '[JSON] WorkspaceNode
                                               )
                                   )
                       )
           )
