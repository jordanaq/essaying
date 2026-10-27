{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Essaying.API.V1 (
    Api,
    ContextApi,
)
where

import Data.Text (Text)
import Essaying.Types.Context (ContextLayer, EffectiveContext, ContextWriteRequest, DeleteContextRequest)
import Essaying.Types.Health (HealthResponse, ReadyResponse)
import Essaying.Types.Account (AccountProfile, CreateAccountRequest, UpdateAccountRequest)
import Essaying.Types.Workspace (
    CreateWorkspaceDirectoryRequest,
    CreateWorkspaceEssayRequest,
    SaveWorkspaceEssayRequest,
    WorkspaceEssayContent,
    WorkspaceNode,
    WorkspaceTreeResponse,
 )
import Servant (Capture, CaptureAll, DeleteNoContent, Get, JSON, Patch, QueryParam', Required, Strict, PostCreated, Put, ReqBody, (:<|>) (..), (:>))

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
                                                    :<|> "context" :> ContextApi
                                               )
                                   )
                       )
           )

-- | Paths identify workspace-relative context.json files, except for effective
-- context, whose path identifies an essay. Filesystem roots stay server-side.
type ContextApi =
    "effective" :> QueryParam' '[Required, Strict] "path" FilePath :> Get '[JSON] EffectiveContext
        :<|> QueryParam' '[Required, Strict] "path" FilePath :> Get '[JSON] ContextLayer
        :<|> ReqBody '[JSON] ContextWriteRequest :> PostCreated '[JSON] ContextLayer
        :<|> ReqBody '[JSON] ContextWriteRequest :> Put '[JSON] ContextLayer
        :<|> ReqBody '[JSON] DeleteContextRequest :> DeleteNoContent
