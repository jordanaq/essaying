{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Essaying.Handler.Health
  ( HealthResponse (..)
  , ReadyResponse (..)
  , healthResponse
  , healthHandler
  , readyResponseFromContext
  , readyHandler
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Essaying.Context (emptyEffectiveContext)
import Essaying.Types.Context (EffectiveContext)
import GHC.Generics (Generic)
import Servant (Handler)

data HealthResponse = HealthResponse
  { status :: Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON HealthResponse
instance FromJSON HealthResponse

data ReadyResponse = ReadyResponse
  { message :: Text
  , sampleContext :: EffectiveContext
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ReadyResponse
instance FromJSON ReadyResponse

healthResponse :: HealthResponse
healthResponse = HealthResponse {status = "ok"}

healthHandler :: Handler HealthResponse
healthHandler = pure healthResponse

readyResponseFromContext :: EffectiveContext -> ReadyResponse
readyResponseFromContext sampleContext =
  ReadyResponse
    { message = "System Ready"
    , sampleContext = sampleContext
    }

readyHandler :: Handler ReadyResponse
readyHandler =
  -- Readiness should remain available while a user's context is invalid.
  pure (readyResponseFromContext emptyEffectiveContext)
