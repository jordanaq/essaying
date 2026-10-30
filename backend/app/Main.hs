{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Essaying.Server (app)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.RequestLogger (logStdoutDev)
import System.Environment (lookupEnv)

{- | Enable HTTP logging only for the exact @HESSAY_HTTP_LOG@ values
@1@, @true@, @yes@, or @on@; all other values disable it.
-}
httpLoggingEnabled :: IO Bool
httpLoggingEnabled = do
  raw <- lookupEnv "HESSAY_HTTP_LOG"
  pure $ case raw of
    Just "1" -> True
    Just "true" -> True
    Just "yes" -> True
    Just "on" -> True
    _ -> False

-- | Wrap the application with development request logging when enabled.
withConditionalHttpLogging :: Bool -> Application -> Application
withConditionalHttpLogging enabled baseApp =
  if enabled then logStdoutDev baseApp else baseApp

-- | Read the logging setting and run the backend on port 8080.
main :: IO ()
main = do
  enableHttpLog <- httpLoggingEnabled
  let runtimeApp = withConditionalHttpLogging enableHttpLog app
  putStrLn "Starting haskell-essaying backend on http://127.0.0.1:8080"
  run 8080 runtimeApp
