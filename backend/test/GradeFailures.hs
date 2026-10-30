{-# LANGUAGE OverloadedStrings #-}

{- | Grading preflight and upstream-failure regressions against the real app.
The actual 120-second deadline check is opt-in, outside the regular suite.
-}
module GradeFailures (tests, deadlineTests) where

import AiTestSupport (readFixture, withCache, withEnvironment, writeBytes)
import Control.Concurrent (threadDelay)
import Control.Monad (forM_, forever)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Builder (string8)
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Essaying.Persistence.Context (loadEffectiveContext)
import Essaying.Persistence.Workspace (loadWorkspaceEssay)
import Essaying.Provider.OpenAiCompatible (generateGrade)
import Essaying.Server (app)
import Essaying.Storage (accountRoot, profileRoot, usersRoot, workspaceRoot)
import Essaying.Types.Account (AccountId (..), AccountProfile (..))
import Essaying.Types.Ai (GradeRequest (..), ProviderError (..))
import Essaying.Types.Storage (CacheRoot (..), WorkspaceRoot (..))
import GHC.Clock (getMonotonicTimeNSec)
import Network.HTTP.Types (Status, mkStatus, status200, statusCode)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test (SRequest (..), SResponse (..), runSession, setPath, srequest)
import System.Directory (copyFile, createDirectory, createDirectoryIfMissing, createFileLink, removeFile)
import System.FilePath (takeDirectory, (</>))
import System.Timeout (timeout)
import Test.HUnit (Test (..), assertBool, assertEqual, assertFailure)

{- | Fast endpoint failures plus the allowed missing-assignment case.
Rejected inputs must not contact the provider; upstream failures stay redacted.
-}
tests :: Test
tests =
  TestLabel "grading endpoint rejection and upstream failures" $
    TestList $
      [ rejected "empty draft" (\_ root -> writeBytes (root </> "Religion/essay.md") "") "Religion" 422
      , rejected "whitespace-only draft" (\_ root -> writeBytes (root </> "Religion/essay.md") " \n\t ") "Religion" 422
      , rejected "empty rubric" (\_ root -> setRubric root (object [])) "Religion" 422
      , rejected "all-zero rubric" (\_ root -> setRubric root (object ["argument" .= object ["weight" .= (0 :: Int)]])) "Religion" 422
      , rejected
          "finite rubric weights overflow when summed"
          ( \_ root ->
              setRubric
                root
                ( object
                    [ "argument" .= object ["weight" .= (1e308 :: Double)]
                    , "evidence" .= object ["weight" .= (1e308 :: Double)]
                    ]
                )
          )
          "Religion"
          422
      , rejected "negative rubric weight" (\_ root -> setRubric root (object ["argument" .= object ["weight" .= (-1 :: Int)]])) "Religion" 422
      , rejected "malformed stored context" (\_ root -> writeBytes (root </> "context.json") "not JSON") "Religion" 422
      , rejected
          "no context model or account preference"
          ( \cache root -> do
              changeContext root (KeyMap.delete "model")
              writeBytes (profilePath cache) (encode (AccountProfile (AccountId "grade-tests") "Test" Nothing))
          )
          "Religion"
          422
      , rejected "missing account" (\cache _ -> removeFile (profilePath cache)) "Religion" 404
      , rejected "missing essay directory" (\_ _ -> pure ()) "Missing" 404
      , rejected "missing draft marker" (\_ root -> removeFile (root </> "Religion/essay.md")) "Religion" 404
      , rejected
          "assignment path is a directory"
          ( \_ root -> do
              removeFile (root </> "Religion/prompt.md")
              createDirectory (root </> "Religion/prompt.md")
          )
          "Religion"
          500
      , rejected
          "assignment path is a symlink"
          ( \_ root -> do
              removeFile (root </> "Religion/prompt.md")
              createFileLink (root </> "Religion/essay.md") (root </> "Religion/prompt.md")
          )
          "Religion"
          500
      , rejected "traversal is rejected before provider access" (\_ _ -> pure ()) "../private" 400
      , rejected "absolute path is rejected before provider access" (\_ _ -> pure ()) "/private/essay" 400
      , configurationFailure "missing provider URL" [("OPENAI_BASE_URL", Nothing)] "Set OPENAI_BASE_URL and OPENAI_API_KEY"
      , configurationFailure "missing API key" [("OPENAI_API_KEY", Nothing)] "Set OPENAI_BASE_URL and OPENAI_API_KEY"
      , configurationFailure "invalid provider URL" [("OPENAI_BASE_URL", Just "not a provider URL")] "absolute HTTP or HTTPS"
      , configurationFailure "multiline API key" [("OPENAI_API_KEY", Just "test-key\ninvalid-header")] "single line"
      , TestLabel "missing assignment is allowed" $ TestCase $ do
          recorded <- BL.readFile "test/fixtures/provider/gpt-6.1-sol-grade.response.json"
          withScenario status200 recorded [] (\_ root -> removeFile (root </> "Religion/prompt.md")) $ \_ requests -> do
            response <- callGrade "Religion"
            assertEqual "saved draft can be graded without an assignment" 200 (statusCode (simpleStatus response))
            assertEqual "provider was called once" 1 =<< readIORef requests
      ]
        <> [ TestLabel ("upstream HTTP " <> show code <> " has actionable public feedback") $
               TestCase $
                 withScenario (mkStatus code "Fixture") upstreamError [] (\_ _ -> pure ()) $ \_ requests -> do
                   response <- callGrade "Religion"
                   assertPublicError expectedStatus response
                   assertEqual "safe actionable failure message" expectedMessage (simpleBody response)
                   assertEqual "one provider call, without automatic retry" 1 =<< readIORef requests
           | (code, expectedStatus, expectedMessage) <-
               [ (400, 502, "The AI provider rejected the request. Check the model and support for Chat Completions with strict JSON schemas.")
               , (401, 502, "AI provider authentication failed. Check OPENAI_API_KEY for the configured provider.")
               , (403, 502, "The AI provider denied access. Check API key permissions and model access.")
               , (404, 502, "The AI provider could not find the model or endpoint. Check OPENAI_BASE_URL, the model ID, and Chat Completions support.")
               , (408, 504, "The AI provider request timed out. Retry or choose a faster model.")
               , (422, 502, "The AI provider rejected the request. Check the model and support for Chat Completions with strict JSON schemas.")
               , (429, 502, "The AI provider rate or quota limit was reached. Check quota or billing, or retry later.")
               , (500, 502, "The AI provider is unavailable. Try again later.")
               , (503, 502, "The AI provider is unavailable. Try again later.")
               , (504, 504, "The AI provider request timed out. Retry or choose a faster model.")
               ]
           ]
        <> [ TestLabel label $
               TestCase $
                 withScenario status200 bytes [] (\_ _ -> pure ()) $ \_ requests -> do
                   response <- callGrade "Religion"
                   assertPublicError 502 response
                   assertEqual "invalid upstream result required one call" 1 =<< readIORef requests
           | (label, bytes) <-
               [ ("malformed successful provider response", "PRIVATE_UPSTREAM_DIAGNOSTIC test-key not JSON")
               , ("truncated provider grade", completion "length" validAssessment)
               , ("provider criterion names do not match", completion "stop" (assessment ["unexpected"] 80 "Feedback"))
               , ("provider score is outside 0-100", completion "stop" (assessment criterionNames 101 "Feedback"))
               , ("provider feedback is blank", completion "stop" (assessment criterionNames 80 " \n\t "))
               ]
           ]

-- | Alter a sample workspace and require a public error with zero provider requests.
rejected :: String -> (FilePath -> FilePath -> IO ()) -> FilePath -> Int -> Test
rejected label prepare essayPath expectedStatus = TestLabel label $
  TestCase $
    withScenario status200 "provider must not be called" [] prepare $ \_ requests -> do
      response <- callGrade essayPath
      assertPublicError expectedStatus response
      assertEqual "rejected input never reaches the provider" 0 =<< readIORef requests

-- | Override fake connection settings and assert corrective, private-data-free output.
configurationFailure :: String -> [(String, Maybe String)] -> BS.ByteString -> Test
configurationFailure label overrides expectedGuidance = TestLabel label $
  TestCase $
    withScenario status200 "provider must not be called" overrides (\_ _ -> pure ()) $ \_ requests -> do
      response <- callGrade "Religion"
      assertPublicError 500 response
      assertBool
        "configuration feedback identifies the correction"
        (expectedGuidance `BS.isInfixOf` BL.toStrict (simpleBody response))
      assertEqual "invalid configuration never reaches the provider" 0 =<< readIORef requests

-- | POST through the actual Servant application without starting an app HTTP server.
callGrade :: FilePath -> IO SResponse
callGrade path = runSession (srequest (SRequest request (encode (GradeRequest path)))) app
 where
  request =
    (setPath Wai.defaultRequest "/api/v1/accounts/grade-tests/workspace/ai/grade")
      { Wai.requestMethod = "POST"
      , Wai.requestHeaders = [("Content-Type", "application/json")]
      }

-- | Check the status and absence of deliberately private test sentinels and paths.
assertPublicError :: Int -> SResponse -> IO ()
assertPublicError expected response = do
  assertEqual "HTTP error status" expected (statusCode (simpleStatus response))
  forM_ ["PRIVATE_UPSTREAM_DIAGNOSTIC", "test-key", "/tmp/essaying", "../private", "/private/essay"] $ \private ->
    assertBool
      "public error does not expose provider diagnostics, credentials, or rejected paths"
      (not (private `BS.isInfixOf` BL.toStrict (simpleBody response)))

{- | Serve a controlled upstream response using an isolated sample workspace.
Restore temporary environment settings and stop the provider after the check.
-}
withScenario ::
  Status ->
  BL.ByteString ->
  [(String, Maybe String)] ->
  (FilePath -> FilePath -> IO ()) ->
  (FilePath -> IORef Int -> IO a) ->
  IO a
withScenario status bytes overrides prepare check = withSampleWorkspace $ \cache root -> do
  prepare cache root
  requests <- newIORef 0
  let provider request respond = do
        _ <- Wai.strictRequestBody request
        modifyIORef' requests (+ 1)
        respond $ Wai.responseLBS status [("Content-Type", "application/json")] bytes
  testWithApplication (pure provider) $ \port ->
    withEnvironment (providerSettings cache port) $
      withEnvironment overrides (check root requests)

-- | Copy the frozen sample into a temporary account, never a user workspace.
withSampleWorkspace :: (FilePath -> FilePath -> IO a) -> IO a
withSampleWorkspace check = withCache $ \cache -> do
  let account = accountRoot (usersRoot (CacheRoot cache)) (AccountId "grade-tests")
      WorkspaceRoot root = workspaceRoot account
  writeBytes (profileRoot account) (encode (AccountProfile (AccountId "grade-tests") "Test" (Just "fallback-model")))
  forM_ ["context.json", "Religion/essay.md", "Religion/prompt.md"] $ \relative -> do
    createDirectoryIfMissing True (takeDirectory (root </> relative))
    copyFile ("test/fixtures/provider/grade-workspace" </> relative) (root </> relative)
  check cache root

-- | Locate the temporary test account profile for controlled fixture changes.
profilePath :: FilePath -> FilePath
profilePath cache = profileRoot (accountRoot (usersRoot (CacheRoot cache)) (AccountId "grade-tests"))

-- | Modify a sample layer as raw JSON so tests can exercise invalid stored input.
changeContext :: FilePath -> (KeyMap.KeyMap Value -> KeyMap.KeyMap Value) -> IO ()
changeContext root change = do
  value <- readFixture (root </> "context.json")
  case value of
    Object fields -> writeBytes (root </> "context.json") (encode (Object (change fields)))
    _ -> assertFailure "sample context must be an object"

-- | Replace only the sample context layer's rubric operation.
setRubric :: FilePath -> Value -> IO ()
setRubric root criteria =
  changeContext root $
    KeyMap.insert "rubric" $
      object ["tag" .= ("ReplaceRubric" :: Text), "contents" .= criteria]

-- | Use a loopback URL and fake key, disabling proxies for deterministic local tests.
providerSettings :: FilePath -> Int -> [(String, Maybe String)]
providerSettings cache port =
  [ ("HESSAY_CACHE", Just cache)
  , ("OPENAI_BASE_URL", Just ("http://127.0.0.1:" <> show port <> "/v1/"))
  , ("OPENAI_API_KEY", Just "test-key")
  ]
    <> [(key, Nothing) | key <- ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"]]

-- | Synthetic private diagnostic used to prove that upstream messages are redacted.
upstreamError :: BL.ByteString
upstreamError = encode $ object ["error" .= object ["message" .= ("PRIVATE_UPSTREAM_DIAGNOSTIC test-key" :: Text)]]

-- | Criterion keys required by the frozen grading sample.
criterionNames :: [Key]
criterionNames = ["argument", "comparison", "evidence", "interpretation"]

-- | Build synthetic grade JSON, allowing invalid scores or feedback deliberately.
assessment :: [Key] -> Int -> Text -> Value
assessment names score feedback =
  object
    [ "feedback" .= feedback
    , "criteria" .= object [name .= object ["score" .= score, "feedback" .= feedback] | name <- names]
    ]

-- | A well-shaped assessment for testing abnormal completion reasons.
validAssessment :: Value
validAssessment = assessment criterionNames 80 "Feedback"

-- | Place serialized grading JSON inside the shared Chat Completions envelope.
completion :: Text -> Value -> BL.ByteString
completion finish payload =
  encode $
    object
      [ "choices"
          .= [ object
                 [ "finish_reason" .= finish
                 , "message" .= object ["content" .= TL.toStrict (TLE.decodeUtf8 (encode payload))]
                 ]
             ]
      ]

{- | Deliberately separate from the fast suite: exercises the real 120-second
production deadline. Heartbeats prevent the 60-second idle timeout winning.
-}
deadlineTests :: Test
deadlineTests = TestLabel "real grading deadline cancels an active provider response" $
  TestCase $
    withSampleWorkspace $ \cache root -> do
      context <- loadEffectiveContext (WorkspaceRoot root) "Religion" >>= either (fail . show) pure
      essay <- loadWorkspaceEssay (WorkspaceRoot root) ["Religion"] >>= maybe (fail "missing sample essay") pure
      requests <- newIORef (0 :: Int)
      chunks <- newIORef (0 :: Int)
      let provider request respond = do
            _ <- Wai.strictRequestBody request
            modifyIORef' requests (+ 1)
            respond $ Wai.responseStream status200 [("Content-Type", "application/json")] $ \write flush ->
              forever $ do
                write (string8 " ")
                flush
                modifyIORef' chunks (+ 1)
                threadDelay 1000000
      testWithApplication (pure provider) $ \port ->
        withEnvironment (providerSettings cache port) $ do
          started <- getMonotonicTimeNSec
          result <- timeout (135 * 1000000) (generateGrade "gpt-6.1-sol" context essay)
          finished <- getMonotonicTimeNSec
          assertEqual
            "production deadline, rather than idle timeout, wins"
            (Just (Left ProviderTimedOut))
            result
          let elapsed = fromIntegral (finished - started) / 1e9 :: Double
          assertBool "the real 120-second deadline is exercised" (elapsed >= 110 && elapsed < 135)
          assertEqual "one request without retries" 1 =<< readIORef requests
          assertBool "provider continued sending heartbeats" . (> 60) =<< readIORef chunks
