{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Exception (finally)
import Control.Monad (when)
import Data.Aeson (decode, encode)
import Data.List (sortOn)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Essaying.API.V1 (Api)
import Essaying.Context (Context (..))
import Essaying.Handler.Health (HealthResponse (..), ReadyResponse (..), healthResponse, readyResponseFromContext)
import Essaying.Persistence.Account (CreateAccountProfileResult (..), createAccountProfile, readAccountProfile)
import Essaying.Server (app)
import Essaying.Storage (accountRoot, profileRoot, resolveCacheRoot, usersRoot)
import Essaying.Types.Account (AccountId (..), AccountProfile (..), CreateAccountRequest (..), UpdateAccountRequest)
import Essaying.Types.Storage (CacheRoot (..))
import Essaying.Types.Workspace
  ( CreateWorkspaceDirectoryRequest
  , CreateWorkspaceEssayRequest
  , WorkspaceEssayContent
  , WorkspaceNode
  , WorkspaceTreeResponse
  )
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
import Servant (NoContent (NoContent), (:<|>) ((:<|>)) )
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, getCurrentDirectory, getHomeDirectory, removePathForcibly)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>), normalise, takeDirectory)
import Test.HUnit (Test (..), assertEqual, assertFailure, runTestTT)
import qualified Data.ByteString.Lazy as BL

healthClient :: ClientM HealthResponse
readyClient :: ClientM ReadyResponse
listAccountsClient :: ClientM [AccountProfile]
createAccountClient :: CreateAccountRequest -> ClientM AccountProfile
type WorkspaceClientRoutes =
  ClientM WorkspaceTreeResponse
    :<|> ([Text] -> ClientM WorkspaceEssayContent)
    :<|> (CreateWorkspaceDirectoryRequest -> ClientM WorkspaceNode)
    :<|> (CreateWorkspaceEssayRequest -> ClientM WorkspaceEssayContent)

accountByIdClient :: Text -> (ClientM AccountProfile :<|> (UpdateAccountRequest -> ClientM AccountProfile) :<|> ClientM NoContent :<|> WorkspaceClientRoutes)
(healthClient :<|> readyClient :<|> (listAccountsClient :<|> createAccountClient :<|> accountByIdClient)) = client (Proxy @Api)

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
  , TestLabel "list accounts endpoint with sample cache" listAccountsEndpointWithSampleCache
  , TestLabel "account create and delete endpoints" createAndDeleteAccountEndpoints
  , TestLabel "create account profile duplicate returns already-exists" createAccountProfileDuplicate
  , TestLabel "read account profile rejects mismatched accountId" readAccountProfileRejectsMismatchedAccountId
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

listAccountsEndpointWithSampleCache :: Test
listAccountsEndpointWithSampleCache = TestCase $ do
  sampleCachePath <- resolveSampleCachePath
  withEnvVar "HESSAY_CACHE" (Just sampleCachePath) $
    testWithApplication (pure app) $ \port -> do
      manager <- newManager defaultManagerSettings
      let env = mkClientEnv manager (BaseUrl Http "127.0.0.1" port "")
      result <- runClientM listAccountsClient env
      case result of
        Left err -> assertFailure (show err)
        Right profiles -> do
          let expectedProfiles =
                [ AccountProfile (AccountId "alice") "Alice" (Just "llama3.1:8b")
                , AccountProfile (AccountId "bob") "Bob" Nothing
                ]
              sortProfiles = sortOn (unAccountId . accountId)
          assertEqual "list accounts endpoint should return fixture accounts"
            (sortProfiles expectedProfiles)
            (sortProfiles profiles)

resolveSampleCachePath :: IO FilePath
resolveSampleCachePath = do
  cwd <- getCurrentDirectory
  let direct = normalise (cwd </> "data" </> "sample" </> "cache")
      monorepo = normalise (cwd </> "backend" </> "data" </> "sample" </> "cache")

  directExists <- doesDirectoryExist direct
  if directExists
    then pure direct
    else pure monorepo

createAccountProfileDuplicate :: Test
createAccountProfileDuplicate = TestCase $ do
  sampleCachePath <- resolveSampleCachePath
  let acctId = AccountId "alice"
      profile = AccountProfile acctId "Alice" (Just "llama3.1:8b")
      acctRoot = accountRoot (usersRoot (CacheRoot sampleCachePath)) acctId

  result <- createAccountProfile acctRoot profile
  assertEqual "duplicate account create should be rejected"
    AccountAlreadyExists
    result

createAndDeleteAccountEndpoints :: Test
createAndDeleteAccountEndpoints = TestCase $
  withEphemeralCacheRoot $ \cachePath ->
    withEnvVar "HESSAY_CACHE" (Just cachePath) $
      testWithApplication (pure app) $ \port -> do
        manager <- newManager defaultManagerSettings
        let env = mkClientEnv manager (BaseUrl Http "127.0.0.1" port "")
            createReq = CreateAccountRequest "Charlie" (Just "llama3.1:8b")

        created <- runClientM (createAccountClient createReq) env
        case created of
          Left err -> assertFailure ("create failed: " <> show err)
          Right profile ->
            assertEqual
              "create endpoint should return created profile"
              (AccountProfile (AccountId "charlie") "Charlie" (Just "llama3.1:8b"))
              profile

        let getClient :<|> _ :<|> deleteClient :<|> _ = accountByIdClient "charlie"

        fetched <- runClientM getClient env
        case fetched of
          Left err -> assertFailure ("fetch after create failed: " <> show err)
          Right profile ->
            assertEqual
              "get endpoint should return created profile"
              (AccountProfile (AccountId "charlie") "Charlie" (Just "llama3.1:8b"))
              profile

        deleted <- runClientM deleteClient env
        case deleted of
          Left err -> assertFailure ("delete failed: " <> show err)
          Right noContent -> assertEqual "delete endpoint should return NoContent" NoContent noContent

        fetchedAfterDelete <- runClientM getClient env
        case fetchedAfterDelete of
          Left _ -> pure ()
          Right profile ->
            assertFailure ("expected missing account after delete, but got: " <> show profile)

readAccountProfileRejectsMismatchedAccountId :: Test
readAccountProfileRejectsMismatchedAccountId = TestCase $
  withEphemeralCacheRoot $ \cachePath -> do
    let acctRoot = accountRoot (usersRoot (CacheRoot cachePath)) (AccountId "alice")
        mismatchedProfile = AccountProfile (AccountId "bob") "Bob" Nothing
        profilePath = profileRoot acctRoot

    createDirectoryIfMissing True (takeDirectory profilePath)
    BL.writeFile profilePath (encode mismatchedProfile)

    loaded <- readAccountProfile acctRoot
    assertEqual
      "mismatched accountId in profile should be treated as invalid"
      Nothing
      loaded

withEphemeralCacheRoot :: (FilePath -> IO a) -> IO a
withEphemeralCacheRoot action = do
  cwd <- getCurrentDirectory
  let direct = normalise (cwd </> "data" </> "tmp-test-cache")
      monorepo = normalise (cwd </> "backend" </> "data" </> "tmp-test-cache")

  backendDirExists <- doesDirectoryExist (cwd </> "backend")
  let cachePath = if backendDirExists then monorepo else direct

  ensureCleanDir cachePath
  action cachePath `finally` ensureCleanDir cachePath

ensureCleanDir :: FilePath -> IO ()
ensureCleanDir dirPath = do
  exists <- doesDirectoryExist dirPath
  when exists $ removePathForcibly dirPath
  createDirectoryIfMissing True dirPath