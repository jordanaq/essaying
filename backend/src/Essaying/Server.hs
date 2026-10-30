{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Essaying.Server (
  app,
)
where

import Essaying.API.V1 (Api)
import Essaying.Handler.Account (accountHandler)
import Essaying.Handler.ContextError (invalidRequestError)
import Essaying.Handler.Health (healthHandler, readyHandler)
import Network.HTTP.Types.URI (decodePathSegments)
import Network.Wai (Application, rawPathInfo)
import Servant (Context (..), Proxy (..), (:<|>) ((:<|>)))
import Servant.Server (ErrorFormatters (..), defaultErrorFormatters, serveWithContext)

app :: Application
app =
  serveWithContext
    (Proxy @Api)
    (formatters :. EmptyContext)
    (healthHandler :<|> readyHandler :<|> accountHandler)
 where
  formatters =
    defaultErrorFormatters
      { bodyParserErrorFormatter = contextFormatter (bodyParserErrorFormatter defaultErrorFormatters)
      , urlParseErrorFormatter = contextFormatter (urlParseErrorFormatter defaultErrorFormatters)
      }
  contextFormatter fallback representation request message =
    case decodePathSegments (rawPathInfo request) of
      ["api", "v1", "accounts", _, "workspace", "context"] -> invalidRequestError
      ["api", "v1", "accounts", _, "workspace", "context", "effective"] -> invalidRequestError
      _ -> fallback representation request message
