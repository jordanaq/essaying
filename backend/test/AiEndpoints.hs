{-# LANGUAGE OverloadedStrings #-}

{- | Full-app prompt and grading replays against local fake providers.
Recorded request/response fixtures verify integration without live API calls.
-}
module AiEndpoints (tests) where

import AiTestSupport (readFixture, withCache, withEnvironment, writeBytes)
import ApiClients (aiClients)
import Control.Monad (forM_)
import Data.Aeson (Value, eitherDecode, eitherDecodeStrict', encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as BL
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Essaying.Provider.OpenAiCompatible (promptGenerationTask, promptResponseFormat)
import Essaying.Server (app)
import Essaying.Storage (accountRoot, profileRoot, usersRoot, workspaceRoot)
import Essaying.Types.Account (AccountId (..), AccountProfile (..))
import Essaying.Types.Ai (GradeRequest (..), GradeResponse (..), PromptRequest (..), PromptResponse (..))
import Essaying.Types.Context (EffectiveContext (..))
import Essaying.Types.Storage (CacheRoot (..), WorkspaceRoot (..))
import Network.HTTP.Client (defaultManagerSettings, managerSetProxy, newManager, noProxy)
import Network.HTTP.Types (status200)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Servant ((:<|>) ((:<|>)))
import Servant.Client (BaseUrl (..), Scheme (Http), mkClientEnv, runClientM)
import System.Directory (copyFile, createDirectoryIfMissing, listDirectory)
import System.FilePath (takeDirectory, (</>))
import Test.HUnit (Test (..), assertBool, assertEqual, assertFailure)

-- | Verify both prompt model-selection paths and the recorded grading workflow.
tests :: Test
tests =
  TestLabel "AI endpoints through the real application" $
    TestList
      [ promptEndpoint "essay context overrides the account model" (Just "context-model") "context-model"
      , promptEndpoint "account preference supplies the model when context has none" Nothing "account-model"
      , gradeEndpoint
      ]

{- | Replay the exact grading sample through routing, loading, transport, and normalization.
Expected scores/weights are fixture data, not calculated by the helper under test.
-}
gradeEndpoint :: Test
gradeEndpoint = TestLabel "grade endpoint replays the real sample response" $ TestCase $ withCache $ \cache -> do
  let fixtures = "test/fixtures/provider"
      account = accountRoot (usersRoot (CacheRoot cache)) (AccountId "grade-sample")
      WorkspaceRoot workspace = workspaceRoot account
      expectedFiles = ["context.json", "Religion/essay.md", "Religion/prompt.md"]
  recorded <- BL.readFile (fixtures </> "gpt-6.1-sol-grade.response.json")
  recordedRequest <- readFixture (fixtures </> "gpt-6.1-sol-grade.request.json")
  expected <- readFixture (fixtures </> "gpt-6.1-sol-grade.expected.json")
  writeBytes (profileRoot account) $
    encode $
      AccountProfile (AccountId "grade-sample") "Grade sample" (Just "account-fallback-must-not-win")
  forM_ expectedFiles $ \relative -> do
    createDirectoryIfMissing True (takeDirectory (workspace </> relative))
    copyFile (fixtures </> "grade-workspace" </> relative) (workspace </> relative)
  originalFiles <- mapM (BL.readFile . (workspace </>)) expectedFiles
  received <- newIORef []
  let provider request respond = do
        bytes <- Wai.strictRequestBody request
        modifyIORef' received ((Wai.requestMethod request, Wai.rawPathInfo request, Wai.requestHeaders request, bytes) :)
        respond $ Wai.responseLBS status200 [("Content-Type", "application/json")] recorded
  testWithApplication (pure provider) $ \providerPort ->
    withEnvironment
      ( [ ("HESSAY_CACHE", Just cache)
        , ("OPENAI_BASE_URL", Just ("http://127.0.0.1:" <> show providerPort <> "/v1/"))
        , ("OPENAI_API_KEY", Just "test-key")
        ]
          <> [(key, Nothing) | key <- ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"]]
      )
      $ testWithApplication (pure app)
      $ \appPort -> do
        manager <- newManager (managerSetProxy noProxy defaultManagerSettings)
        let environment = mkClientEnv manager (BaseUrl Http "127.0.0.1" appPort "")
            _ :<|> grade = aiClients "grade-sample"
        result <- runClientM (grade (GradeRequest "Religion")) environment
        case result of
          Left err -> assertFailure ("grade endpoint failed: " <> show err)
          Right (GradeResponse overall feedback criteria) -> do
            let GradeResponse expectedOverall expectedFeedback expectedCriteria = expected
            assertBool
              "weighted overall score is 79.3/100"
              (not (isNaN overall || isInfinite overall) && abs (overall - expectedOverall) < 1e-10)
            assertEqual "real overall feedback is preserved" expectedFeedback feedback
            assertEqual "real criterion scores and feedback, with application-calculated weights" expectedCriteria criteria
        requests <- readIORef received
        case requests of
          [(method, path, headers, bytes)] -> do
            assertEqual "one provider POST" "POST" method
            assertEqual "provider URL includes its API prefix" "/v1/chat/completions" path
            assertEqual "only fake credentials are sent" (Just "Bearer test-key") (lookup "Authorization" headers)
            assertEqual "JSON request" (Just "application/json") (lookup "Content-Type" headers)
            assertEqual
              "entire outgoing request matches the real smoke request"
              (Right recordedRequest)
              (eitherDecode bytes :: Either String Value)
          _ -> assertFailure "expected exactly one grading provider request"
        assertEqual "saved context, draft, and assignment are unchanged" originalFiles
          =<< mapM (BL.readFile . (workspace </>)) expectedFiles
        entries <- listDirectory (workspace </> "Religion")
        assertEqual "grading creates no files in the essay" ["essay.md", "prompt.md"] (sort entries)

-- | Assert selected-account context/model inputs and unchanged saved files on generation.
promptEndpoint :: String -> Maybe Text -> Text -> Test
promptEndpoint label contextModel expectedModel = TestLabel label $ TestCase $ withCache $ \cache -> do
  recorded <- BL.readFile "test/fixtures/provider/gpt-6.1-sol-prompt-options.response.json"
  expectedBytes <- BL.readFile "test/fixtures/provider/gpt-6.1-sol-prompt-options.expected.json"
  expected <- case eitherDecode expectedBytes :: Either String [Text] of
    Left err -> assertFailure ("invalid expected fixture: " <> err) >> pure []
    Right options -> pure options
  let account = accountRoot (usersRoot (CacheRoot cache)) (AccountId "alice")
      WorkspaceRoot workspace = workspaceRoot account
      essay = workspace </> "Religion/Comparison"
      instructions = Just "Generate three distinct assignment options."
      context =
        EffectiveContext
          (Just "Hume and Kierkegaard")
          (Just "Philosophy students")
          contextModel
          ["religion"]
          ["Compare arguments fairly."]
          []
          Map.empty
      draft = "# My saved draft\n"
      savedPrompt = "My existing assignment.\n"
  writeBytes (profileRoot account) $ encode (AccountProfile (AccountId "alice") "Alice" (Just "account-model"))
  writeBytes (workspace </> "context.json") $
    encode $
      object
        [ "audience" .= scalar ("Philosophy students" :: Text)
        , "instructions" .= object ["tag" .= ("AppendList" :: Text), "contents" .= (["Compare arguments fairly."] :: [Text])]
        ]
  writeBytes (workspace </> "Religion/context.json") $
    encode $
      object
        ["tags" .= object ["tag" .= ("AppendList" :: Text), "contents" .= (["religion"] :: [Text])]]
  writeBytes (essay </> "context.json") $
    encode $
      object $
        ["title" .= scalar ("Hume and Kierkegaard" :: Text)]
          <> maybe [] (\modelValue -> ["model" .= scalar modelValue]) contextModel
  writeBytes (essay </> "essay.md") draft
  writeBytes (essay </> "prompt.md") savedPrompt
  -- A second account catches accidental use of another workspace or preference.
  let other = accountRoot (usersRoot (CacheRoot cache)) (AccountId "bob")
      WorkspaceRoot otherWorkspace = workspaceRoot other
  writeBytes (profileRoot other) $ encode (AccountProfile (AccountId "bob") "Bob" (Just "wrong-account-model"))
  writeBytes (otherWorkspace </> "Religion/Comparison/essay.md") "Other account's draft"
  writeBytes (otherWorkspace </> "context.json") $
    encode $
      object
        ["title" .= scalar ("Wrong account context" :: Text)]
  received <- newIORef []
  let provider request respond = do
        bytes <- Wai.strictRequestBody request
        modifyIORef' received ((Wai.requestMethod request, Wai.rawPathInfo request, Wai.requestHeaders request, bytes) :)
        respond $ Wai.responseLBS status200 [("Content-Type", "application/json")] recorded
  testWithApplication (pure provider) $ \providerPort ->
    withEnvironment
      ( [ ("HESSAY_CACHE", Just cache)
        , ("OPENAI_BASE_URL", Just ("http://127.0.0.1:" <> show providerPort <> "/v1/"))
        , ("OPENAI_API_KEY", Just "test-key")
        ]
          <> [(key, Nothing) | key <- ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"]]
      )
      $ testWithApplication (pure app)
      $ \appPort -> do
        manager <- newManager (managerSetProxy noProxy defaultManagerSettings)
        let environment = mkClientEnv manager (BaseUrl Http "127.0.0.1" appPort "")
            generate :<|> _ = aiClients "alice"
        result <- runClientM (generate (PromptRequest "Religion/Comparison" instructions)) environment
        assertEqual "HTTP endpoint returns every recorded option in order" (Right (PromptResponse expected)) result
        requests <- readIORef received
        case requests of
          [(method, path, headers, bytes)] -> do
            assertEqual "one provider POST" "POST" method
            assertEqual "configured provider URL" "/v1/chat/completions" path
            assertEqual "fake credentials only" (Just "Bearer test-key") (lookup "Authorization" headers)
            assertEqual "JSON request" (Just "application/json") (lookup "Content-Type" headers)
            case eitherDecode bytes >>= parseEither providerInput of
              Left err -> assertFailure ("invalid provider request: " <> err)
              Right (selectedModel, streaming, responseFormat, messages) -> do
                assertEqual "model selection" expectedModel selectedModel
                assertEqual "MVP uses a complete response" False streaming
                assertEqual "structured output requested" promptResponseFormat responseFormat
                case messages of
                  [("system", task), ("user", input)] -> do
                    assertEqual "prompt generation task" promptGenerationTask task
                    assertEqual
                      "inherited context and request instructions reach the provider"
                      (Right (object ["context" .= context, "instructions" .= instructions]))
                      (eitherDecodeStrict' (TextEncoding.encodeUtf8 input) :: Either String Value)
                  _ -> assertFailure "expected system and user messages"
          _ -> assertFailure "expected exactly one provider request"
        assertEqual "generation preserves the draft" draft =<< BL.readFile (essay </> "essay.md")
        assertEqual "generation preserves the saved assignment" savedPrompt =<< BL.readFile (essay </> "prompt.md")
 where
  scalar value = object ["tag" .= ("SetScalar" :: Text), "contents" .= value]

-- | Extract outgoing model, response schema, and messages for endpoint assertions.
providerInput :: Value -> Parser (Text, Bool, Value, [(Text, Text)])
providerInput = withObject "provider request" $ \request -> do
  selectedModel <- request .: "model"
  streaming <- request .: "stream"
  responseFormat <- request .: "response_format"
  messages <- request .: "messages"
  parsedMessages <-
    mapM
      ( withObject "message" $ \message ->
          (,) <$> message .: "role" <*> message .: "content"
      )
      messages
  pure (selectedModel, streaming, responseFormat, parsedMessages)
