{-# LANGUAGE OverloadedStrings #-}

module Essaying.Handler.Health (
  healthResponse,
  healthHandler,
  readyResponseFromContext,
  readyHandler,
)
where

import Essaying.Context (emptyEffectiveContext)
import Essaying.Types.Context (EffectiveContext)
import Essaying.Types.Health (HealthResponse (..), ReadyResponse (..))
import Servant (Handler)

healthResponse :: HealthResponse
healthResponse = HealthResponse{status = "ok"}

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
