{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Essaying.API.V1
  ( Api
  )
where

import Essaying.Handler.Health (HealthResponse, ReadyResponse)
import Essaying.Types.Account (AccountProfile, CreateAccountRequest, UpdateAccountRequest)
import Servant (Capture, DeleteNoContent, Get, JSON, Patch, PostCreated, ReqBody, (:<|>) (..), (:>))
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
                )
          )
    )