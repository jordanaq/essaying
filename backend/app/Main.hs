{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Main where

import Data.Aeson (ToJSON)
import Data.Text (Text)
import Essaying.Context (Context (..), loadEffectiveContext)
import GHC.Generics (Generic)
import Control.Monad.IO.Class (liftIO)
import Network.Wai.Handler.Warp (run)
import Servant hiding (Context)

-- Sprint-1 handshake endpoint described in prompt.md.
data ReadyResponse = ReadyResponse
  { message :: Text
  , sampleContext :: Context
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ReadyResponse

type Api = "api" :> "ready" :> Get '[JSON] ReadyResponse

server :: Server Api
server = do
  effective <-
    liftIO $
      loadEffectiveContext
        "data/sample/History/French-Revolution"
        "data/sample"
  pure ReadyResponse
    { message = "System Ready"
    , sampleContext = effective
    }

app :: Application
app = serve (Proxy @Api) server

main :: IO ()
main = do
  putStrLn "Starting haskell-essaying backend on http://127.0.0.1:8080"
  run 8080 app
