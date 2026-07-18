{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Essaying.Server
  ( app
  )
where

import Essaying.API.V1 (Api)
import Essaying.Handler.Health (healthHandler, readyHandler)
import Essaying.Handler.Account (accountHandler)
import Network.Wai (Application)
import Servant (Proxy (..), (:<|>) ((:<|>)), serve)

app :: Application
app = serve (Proxy @Api) (healthHandler :<|> readyHandler :<|> accountHandler)