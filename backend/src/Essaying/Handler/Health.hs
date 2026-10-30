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

-- | Stable liveness payload reporting that the server is running.
healthResponse :: HealthResponse
healthResponse = HealthResponse{status = "ok"}

-- | Return the liveness payload without filesystem or provider access.
healthHandler :: Handler HealthResponse
healthHandler = pure healthResponse

-- | Wrap the supplied context in the readiness response without resolving it.
readyResponseFromContext :: EffectiveContext -> ReadyResponse
readyResponseFromContext sampleContext =
  ReadyResponse
    { message = "System Ready"
    , sampleContext = sampleContext
    }

{- | Return readiness with empty context, independent of account files,
invalid user context, and provider availability.
-}
readyHandler :: Handler ReadyResponse
readyHandler =
  -- Readiness should remain available while a user's context is invalid.
  pure (readyResponseFromContext emptyEffectiveContext)
