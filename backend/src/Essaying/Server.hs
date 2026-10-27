{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Essaying.Server
  ( app
  )
where

import Network.HTTP.Types.URI (decodePathSegments)
import Essaying.API.V1 (Api)
import Essaying.Handler.Health (healthHandler, readyHandler)
import Essaying.Handler.Account (accountHandler)
import Network.Wai (Application, rawPathInfo)
import Essaying.Handler.ContextError (invalidRequestError)
import Servant.Server (ErrorFormatters (..), defaultErrorFormatters, serveWithContext)
import Servant (Proxy (..), (:<|>) ((:<|>)), Context (..))

app :: Application
app = serveWithContext (Proxy @Api) (formatters :. EmptyContext)
  (healthHandler :<|> readyHandler :<|> accountHandler)
  where
    formatters = defaultErrorFormatters
      { bodyParserErrorFormatter = contextFormatter (bodyParserErrorFormatter defaultErrorFormatters)
      , urlParseErrorFormatter = contextFormatter (urlParseErrorFormatter defaultErrorFormatters)
      }
    contextFormatter fallback representation request message =
      case decodePathSegments (rawPathInfo request) of
        ["api", "v1", "accounts", _, "workspace", "context"] -> invalidRequestError
        ["api", "v1", "accounts", _, "workspace", "context", "effective"] -> invalidRequestError
        _ -> fallback representation request message
