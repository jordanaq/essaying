{-# LANGUAGE OverloadedStrings #-}

module ProviderRequests (tests) where

import Control.Monad (forM_)
import Control.Concurrent (threadDelay)
import Data.Aeson (Value (..), eitherDecode, eitherDecodeStrict', encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.Map.Strict qualified as Map
import Data.IORef (newIORef, readIORef, modifyIORef')
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.ByteString.Lazy qualified as BL
import Essaying.Provider.OpenAiCompatible
  ( OpenAiProviderConfig (..), buildRequest, buildPromptRequestBody, promptGenerationTask, generatePromptsWith
  , sendRequest, decodePromptResponse, decodePromptHttpResponse, decodeProviderErrorMessage
  )
import Essaying.Types.Ai (ProviderError (..))
import Essaying.Types.Context (EffectiveContext (..))
import Network.HTTP.Client
  ( Request (..), RequestBody (RequestBodyLBS), Response, newManager
  , defaultManagerSettings, responseBody, responseStatus, responseTimeoutMicro, managerSetProxy, noProxy
  )
import Network.HTTP.Types (status200, mkStatus)
import Network.Wai (responseLBS)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Test.HUnit (Test (..), assertBool, assertEqual, assertFailure)

-- Construction tests never send requests. Transport tests use a temporary
-- loopback server, fake credentials, and requests with proxies disabled.
tests :: Test
tests = TestList
  [ TestLabel "custom provider URL and authentication" $ TestCase $
      forM_ ["https://provider.example/v1", "https://provider.example/v1/"] $ \url -> do
        request <- buildRequest (OpenAiProviderConfig url "test-key") (object [])
        assertEqual "method" "POST" (method request)
        assertEqual "custom host" "provider.example" (host request)
        assertBool "HTTPS" (secure request)
        assertEqual "endpoint preserves API prefix" "/v1/chat/completions" (path request)
        assertEqual "content type" (Just "application/json") (lookup "Content-Type" (requestHeaders request))
        assertEqual "bearer authentication" (Just "Bearer test-key") (lookup "Authorization" (requestHeaders request))
        assertEqual "redirects disabled" 0 (redirectCount request)
  , TestLabel "message input survives JSON and UTF-8 encoding" $ TestCase $ do
      let context = EffectiveContext
            (Just "Café: \"identity\"\nand belonging") (Just "一般読者") Nothing
            ["文学"] ["Compare evidence and interpretation."] [] Map.empty
          instructions = Just "Discuss \"naïve\" assumptions.\nInclude a counterargument."
          body = buildPromptRequestBody "provider/model-name" context instructions
      request <- buildRequest (OpenAiProviderConfig "https://provider.example/v1" "test-key") body
      case requestBody request of
        RequestBodyLBS bytes -> case eitherDecode bytes >>= parseEither parseEnvelope of
          Left err -> assertFailure ("invalid request body: " <> err)
          Right (selectedModel, streaming, messages) -> do
            assertEqual "configured model" "provider/model-name" selectedModel
            assertEqual "non-streaming" False streaming
            case messages of
              [(systemRole, task), (userRole, inputText)] -> do
                assertEqual "system role" "system" systemRole
                assertEqual "task instructions" promptGenerationTask task
                assertEqual "user role" "user" userRole
                assertEqual "serialized context and instructions"
                  (Right (object ["context" .= context, "instructions" .= instructions]))
                  (eitherDecodeStrict' (TextEncoding.encodeUtf8 inputText) :: Either String Value)
              _ -> assertFailure "expected exactly a system message and a user message"
        _ -> assertFailure "expected a complete JSON request body"
  , TestLabel "transport returns the local provider response" $ TestCase $
      testWithApplication (pure (\_ respond -> respond (responseLBS status200 [] "provider reply"))) $ \port -> do
        manager <- newManager defaultManagerSettings
        request <- buildRequest
          (OpenAiProviderConfig (Text.pack ("http://127.0.0.1:" <> show port <> "/v1")) "test-key")
          (object [])
        result <- sendRequest manager request {proxy = Nothing}
        case result of
          Left err -> assertFailure ("unexpected transport failure: " <> show err)
          Right response -> do
            assertEqual "status" status200 (responseStatus response)
            assertEqual "complete response body" "provider reply" (responseBody response)
  , TestLabel "transport translates a response timeout into a provider error" $ TestCase $
      testWithApplication (pure (\_ respond -> do
        threadDelay 200000
        respond (responseLBS status200 [] "late reply"))) $ \port -> do
        manager <- newManager defaultManagerSettings
        request <- buildRequest
          (OpenAiProviderConfig (Text.pack ("http://127.0.0.1:" <> show port <> "/v1")) "test-key")
          (object [])
        result <- sendRequest manager request
          {proxy = Nothing, responseTimeout = responseTimeoutMicro 20000}
        case result of
          Left ProviderTimedOut -> pure ()
          Left err -> assertFailure ("unexpected provider error: " <> show err)
          Right _ -> assertFailure "expected a timeout to become a provider error"
  , TestLabel "connection failure is distinct from a timeout" $ TestCase $ do
      manager <- newManager (managerSetProxy noProxy defaultManagerSettings)
      request <- buildRequest (OpenAiProviderConfig "http://127.0.0.1:0/v1" "test-key") (object [])
      result <- sendRequest manager request
      case result of
        Left ProviderConnectionFailed -> pure ()
        Left err -> assertFailure ("expected connection failure, got " <> show err)
        Right _ -> assertFailure "port zero must not return a provider response"
  , decoderTests
  , httpResponseTests
  , errorMessageTests
  , generationWorkerTest
  ]

generationWorkerTest :: Test
generationWorkerTest = TestLabel "generation worker uses a fake provider and recorded response" $ TestCase $ do
  recorded <- BL.readFile "test/fixtures/provider/gpt-6.1-sol-prompt-options.response.json"
  expectedBytes <- BL.readFile "test/fixtures/provider/gpt-6.1-sol-prompt-options.expected.json"
  expected <- case eitherDecode expectedBytes :: Either String [Text] of
    Left err -> assertFailure ("invalid expected fixture: " <> err) >> pure []
    Right options -> pure options
  received <- newIORef []
  let context = EffectiveContext (Just "Hume and Kierkegaard") (Just "Philosophy students")
        Nothing ["religion"] ["Compare arguments fairly."] [] Map.empty
      instructions = Just "Generate three distinct assignment options."
      app request respond = do
        bytes <- Wai.strictRequestBody request
        modifyIORef' received
          ((Wai.requestMethod request, Wai.rawPathInfo request, Wai.requestHeaders request, bytes) :)
        respond (responseLBS status200 [("Content-Type", "application/json")] recorded)
  testWithApplication (pure app) $ \port -> do
    manager <- newManager (managerSetProxy noProxy defaultManagerSettings)
    let config = OpenAiProviderConfig
          (Text.pack ("http://127.0.0.1:" <> show port <> "/v1/")) "test-key"
    result <- generatePromptsWith manager config "gpt-6.1-sol" context instructions
    assertEqual "worker returns every recorded option, unchanged and in order" (Right expected) result
    requests <- readIORef received
    case requests of
      [(methodValue, pathValue, headers, bytes)] -> do
        assertEqual "one POST to the fake provider" "POST" methodValue
        assertEqual "provider endpoint" "/v1/chat/completions" pathValue
        assertEqual "only a literal fake key" (Just "Bearer test-key") (lookup "Authorization" headers)
        assertEqual "JSON content type" (Just "application/json") (lookup "Content-Type" headers)
        case eitherDecode bytes >>= parseEither parseEnvelope of
          Left err -> assertFailure ("invalid outgoing request: " <> err)
          Right (selectedModel, streaming, messages) -> do
            assertEqual "selected model" "gpt-6.1-sol" selectedModel
            assertEqual "non-streaming request" False streaming
            case messages of
              [("system", task), ("user", inputText)] -> do
                assertEqual "generation task" promptGenerationTask task
                assertEqual "context and extra instructions reach the provider"
                  (Right (object ["context" .= context, "instructions" .= instructions]))
                  (eitherDecodeStrict' (TextEncoding.encodeUtf8 inputText) :: Either String Value)
              _ -> assertFailure "expected the system task and user input"
      _ -> assertFailure "expected exactly one request to the fake provider"

httpResponseTests :: Test
httpResponseTests = TestLabel "provider HTTP response handling" $ TestList $
  [ TestLabel "recorded response traverses real request, transport, and decoder" $ TestCase $ do
      bytes <- BL.readFile "test/fixtures/provider/gpt-6.1-sol-prompt-options.response.json"
      expectedBytes <- BL.readFile "test/fixtures/provider/gpt-6.1-sol-prompt-options.expected.json"
      case eitherDecode expectedBytes :: Either String [Text] of
        Left err -> assertFailure ("invalid expected fixture: " <> err)
        Right expected -> withLocalResponse 200 bytes $ \response ->
          assertEqual "all recorded Markdown options survive the HTTP round trip"
            (Right expected) (decodePromptHttpResponse response)
  , TestLabel "malformed successful response is a decoding failure" $ TestCase $
      withLocalResponse 200 "not JSON" $ \response ->
        case decodePromptHttpResponse response of
          Left ProviderInvalidResponse -> pure ()
          other -> assertFailure ("expected decoding failure, got " <> show other)
  ] <> map statusCase
    [ (401, errorBody "  Invalid credentials.  ", Just "Invalid credentials.")
    , (403, errorBody "Access denied.", Just "Access denied.")
    , (404, errorBody "Unknown model.", Just "Unknown model.")
    , (429, errorBody "Rate limit exceeded.", Just "Rate limit exceeded.")
    , (500, "<html>Server error</html>", Nothing)
    , (503, contentCompletion "{\"prompts\":[\"Looks successful\"]}", Nothing)
    ]
  where
    statusCase (code, bytes, message) = TestLabel ("preserve HTTP " <> show code) $ TestCase $
      withLocalResponse code bytes $ \response ->
        assertEqual "HTTP errors stay distinct from successful prompt output"
          (Left (ProviderHttpError code message)) (decodePromptHttpResponse response)

-- Uses the real builder and sender, but only a short-lived loopback server.
withLocalResponse :: Int -> BL.ByteString -> (Response BL.ByteString -> IO ()) -> IO ()
withLocalResponse code bytes check =
  testWithApplication (pure (\_ respond -> respond (responseLBS (mkStatus code "Fixture") [] bytes))) $ \port -> do
    manager <- newManager defaultManagerSettings
    request <- buildRequest
      (OpenAiProviderConfig (Text.pack ("http://127.0.0.1:" <> show port <> "/v1")) "test-key")
      (object [])
    result <- sendRequest manager request {proxy = Nothing}
    case result of
      Left err -> assertFailure ("unexpected transport failure: " <> show err)
      Right response -> check response

errorBody :: Text -> BL.ByteString
errorBody message = encode (object ["error" .= object ["message" .= message]])

errorMessageTests :: Test
errorMessageTests = TestLabel "provider error message decoding" $ TestList $
  [ TestLabel "UTF-8 message is decoded and trimmed" $ TestCase $
      assertEqual "only the nested message is retained" (Just "Café: modèle indisponible. 宗教")
        (decodeProviderErrorMessage (errorBody " \nCafé: modèle indisponible. 宗教\t "))
  ] <> map absent
    [ ("malformed JSON", "not JSON")
    , ("HTML response", "<html>Bad gateway</html>")
    , ("invalid UTF-8", BL.pack [255])
    , ("missing error", "{}")
    , ("wrong error shape", "{\"error\":\"Failure\"}")
    , ("missing message", "{\"error\":{}}")
    , ("null message", "{\"error\":{\"message\":null}}")
    , ("non-text message", "{\"error\":{\"message\":42}}")
    , ("blank message", errorBody " \n\t ")
    ]
  where
    absent (label, bytes) = TestLabel label $ TestCase $
      assertEqual "unusable error body has no message" Nothing (decodeProviderErrorMessage bytes)

decoderTests :: Test
decoderTests = TestLabel "prompt response decoder" $ TestList $
  [ TestLabel "real GPT-6.1 Sol structured response preserves all three options" $ TestCase $ do
      responseBytes <- BL.readFile "test/fixtures/provider/gpt-6.1-sol-prompt-options.response.json"
      expectedBytes <- BL.readFile "test/fixtures/provider/gpt-6.1-sol-prompt-options.expected.json"
      case eitherDecode expectedBytes :: Either String [Text] of
        Left err -> assertFailure ("invalid expected fixture: " <> err)
        Right expected -> do
          assertEqual "recorded option count" 3 (length expected)
          assertEqual "exact Markdown content and original option order"
            (Right expected) (decodePromptResponse responseBytes)
  , TestLabel "one prompt with Unicode, quotes, newlines, and outer whitespace" $ TestCase $
      assertEqual "single trimmed Markdown prompt"
        (Right ["# Café\nCompare \"faith\" and reason: 宗教."])
        (decodePromptResponse (completion "stop" (object
          ["content" .= ("{\"prompts\":[\"  # Café\\nCompare \\\"faith\\\" and reason: 宗教.  \"]}" :: Text)])))
  , TestLabel "two options preserve order" $ TestCase $
      assertEqual "two distinct prompts" (Right ["First", "Second"])
        (decodePromptResponse (contentCompletion "{\"prompts\":[\"First\",\"Second\"]}"))
  , TestLabel "four options are accepted without a fixed three-option limit" $ TestCase $
      assertEqual "four prompts" (Right ["A", "B", "C", "D"])
        (decodePromptResponse (contentCompletion "{\"prompts\":[\"A\",\"B\",\"C\",\"D\"]}"))
  ] <> map rejected
    [ ("malformed outer JSON", "not JSON")
    , ("missing choices", encode (object []))
    , ("empty choices", encode (object ["choices" .= ([] :: [Value])]))
    , ("choices has wrong type", encode (object ["choices" .= ("wrong" :: Text)]))
    , ("missing message content", completion "stop" (object []))
    , ("null content from a refusal", completion "stop" (object
        ["content" .= Null, "refusal" .= ("Cannot generate this assignment." :: Text)]))
    , ("non-text content", completion "stop" (object ["content" .= (42 :: Int)]))
    , ("blank content", contentCompletion " \n\t ")
    , ("malformed inner JSON", contentCompletion "{\"prompts\":[")
    , ("plain Markdown is not the structured contract", contentCompletion "# An assignment")
    , ("missing prompts field", contentCompletion "{}")
    , ("prompts is not an array", contentCompletion "{\"prompts\":\"Assignment\"}")
    , ("prompts contains a non-string", contentCompletion "{\"prompts\":[\"Valid\",42]}")
    , ("empty prompt list", contentCompletion "{\"prompts\":[]}")
    , ("empty option invalidates the whole result", contentCompletion "{\"prompts\":[\"Valid\",\"\"]}")
    , ("whitespace-only option", contentCompletion "{\"prompts\":[\" \\n\\t \"]}")
    , ("truncated output fails even if its JSON parses", completion "length" validMessage)
    , ("content-filtered output fails", completion "content_filter" validMessage)
    ]
  where
    validMessage = object ["content" .= ("{\"prompts\":[\"Looks valid\"]}" :: Text)]
    rejected (label, bytes) = TestLabel label $ TestCase $
      case decodePromptResponse bytes of
        Left ProviderInvalidResponse -> pure ()
        Left err -> assertFailure ("unexpected error type: " <> show err)
        Right _ -> assertFailure "expected malformed or incomplete provider output to be rejected"

-- Helpers for synthetic edge cases; the real response uses a repository fixture.
completion :: Text -> Value -> BL.ByteString
completion finishReason message = encode $ object
  ["choices" .= [object ["finish_reason" .= finishReason, "message" .= message]]]

contentCompletion :: Text -> BL.ByteString
contentCompletion content = completion "stop" (object ["content" .= content])

parseEnvelope :: Value -> Parser (Text, Bool, [(Text, Text)])
parseEnvelope = withObject "chat request" $ \request -> do
  selectedModel <- request .: "model"
  streaming <- request .: "stream"
  messages <- request .: "messages" >>= mapM
    (withObject "message" $ \message -> (,) <$> message .: "role" <*> message .: "content")
  pure (selectedModel, streaming, messages)
