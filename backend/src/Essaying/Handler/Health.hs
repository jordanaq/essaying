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

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Essaying.Context (loadEffectiveContext)
import Essaying.Types.Context (EffectiveContext)
import Essaying.Types.Storage (WorkspaceRoot (..))
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
readyHandler = do
  effective <-
    liftIO $
      loadEffectiveContext
        (WorkspaceRoot "data/sample")
        "History/French-Revolution"
  pure (readyResponseFromContext effective)
