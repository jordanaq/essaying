{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Exception (finally)
import Data.Aeson (decode, encode)
import Data.Proxy (Proxy (..))
import Essaying.API.V1 (Api)
import Essaying.Context (Context (..))
import Essaying.Handler.Health (HealthResponse (..), ReadyResponse (..), healthResponse, readyResponseFromContext)
import Essaying.Server (app)
import Essaying.Storage (resolveCacheRoot)
import Essaying.Types.Storage (CacheRoot (..))
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.Wai.Handler.Warp (testWithApplication)
import Servant.Client
  ( BaseUrl (..)
  , ClientM
  , Scheme (Http)
  , client
  , mkClientEnv
  , runClientM
  )
import Servant ( (:<|>) ((:<|>)) )
import System.Directory (getHomeDirectory)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>), normalise)
import Test.HUnit (Test (..), assertEqual, assertFailure, runTestTT)

healthClient :: ClientM HealthResponse
readyClient :: ClientM ReadyResponse
(healthClient :<|> readyClient) = client (Proxy @Api)

main :: IO ()
main = do
  _ <- runTestTT tests
  pure ()

tests :: Test
tests = TestList
  [ TestLabel "health response value" healthResponseValue
  , TestLabel "health response json" healthResponseJson
  , TestLabel "ready response value" readyResponseValue
  , TestLabel "ready response json" readyResponseJson
  , TestLabel "resolveCacheRoot fallback" resolveCacheRootFallback
  , TestLabel "resolveCacheRoot env override" resolveCacheRootEnvOverride
  , TestLabel "health endpoint" healthEndpoint
  , TestLabel "ready endpoint" readyEndpoint
  ]

healthResponseValue :: Test
healthResponseValue = TestCase $ do
  let expected = HealthResponse {status = "ok"}
  assertEqual "health response should be stable" expected healthResponse

healthResponseJson :: Test
healthResponseJson = TestCase $ do
  let expected = Just healthResponse
  assertEqual "health response JSON should round-trip" expected (decode (encode healthResponse))

readyResponseValue :: Test
readyResponseValue = TestCase $ do
  let sampleContext =
        Context
          { title = Just "History Essay"
          , audience = Just "student"
          , model = Just "llama3.1:8b"
          , instructions = ["Use concise prose."]
          , rubric = mempty
          }
      expected =
        ReadyResponse
          { message = "System Ready"
          , sampleContext = sampleContext
          }
  assertEqual "ready response should wrap the provided context" expected (readyResponseFromContext sampleContext)

readyResponseJson :: Test
readyResponseJson = TestCase $ do
  let sampleContext =
        mempty
          { title = Just "Essay"
          , rubric = mempty
          }
      response = readyResponseFromContext sampleContext
      expected = Just response
  assertEqual "ready response JSON should round-trip" expected (decode (encode response))

resolveCacheRootFallback :: Test
resolveCacheRootFallback = TestCase $ do
  home <- getHomeDirectory
  let expected = normalise (home </> ".cache" </> "hessaying")
  withEnvVar "HESSAY_CACHE" Nothing $ do
    CacheRoot resolved <- resolveCacheRoot
    assertEqual "fallback should resolve to ~/.cache/hessaying" expected resolved

resolveCacheRootEnvOverride :: Test
resolveCacheRootEnvOverride = TestCase $ do
  let requested = "/tmp/hessay-cache-test"
      expected = normalise requested
  withEnvVar "HESSAY_CACHE" (Just requested) $ do
    CacheRoot resolved <- resolveCacheRoot
    assertEqual "env override should be used when HESSAY_CACHE is set" expected resolved

withEnvVar :: String -> Maybe String -> IO a -> IO a
withEnvVar key newValue action = do
  oldValue <- lookupEnv key
  setMaybe key newValue
  action `finally` setMaybe key oldValue
  where
    setMaybe k (Just v) = setEnv k v
    setMaybe k Nothing = unsetEnv k

healthEndpoint :: Test
healthEndpoint = TestCase $
  testWithApplication (pure app) $ \port -> do
    manager <- newManager defaultManagerSettings
    let env = mkClientEnv manager (BaseUrl Http "127.0.0.1" port "")
    result <- runClientM healthClient env
    case result of
      Left err -> assertFailure (show err)
      Right response -> assertEqual "health endpoint should return ok" (HealthResponse {status = "ok"}) response

readyEndpoint :: Test
readyEndpoint = TestCase $
  testWithApplication (pure app) $ \port -> do
    manager <- newManager defaultManagerSettings
    let env = mkClientEnv manager (BaseUrl Http "127.0.0.1" port "")
    result <- runClientM readyClient env
    case result of
      Left err -> assertFailure (show err)
      Right response -> do
        assertEqual "ready endpoint message" "System Ready" (message response)
        assertEqual "ready endpoint sample context" mempty (sampleContext response)