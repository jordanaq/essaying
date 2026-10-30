{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

module Essaying.Types.Health (
  HealthResponse (..),
  ReadyResponse (..),
)
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Essaying.Types.Context (EffectiveContext)
import GHC.Generics (Generic)

-- | Status returned by the health endpoint.
data HealthResponse = HealthResponse
  { status :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Readiness response with the sample resolved context.
data ReadyResponse = ReadyResponse
  { message :: Text
  , sampleContext :: EffectiveContext
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
