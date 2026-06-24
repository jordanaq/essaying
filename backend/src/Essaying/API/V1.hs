{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Essaying.API.V1
  ( Api
  )
where

import Essaying.Handler.Health (HealthResponse, ReadyResponse)
import Servant (Get, JSON, (:<|>) (..), (:>))

type Api =
       "api" :> "v1" :>
         (    "health" :> Get '[JSON] HealthResponse
         :<|> "ready" :> Get '[JSON] ReadyResponse
    )