{-# LANGUAGE OverloadedStrings #-}

-- | Public provider-error status, guidance, and redaction contract tests.
module ProviderErrors (tests) where

import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BL
import Essaying.Handler.Ai (handleProviderError)
import Essaying.Types.Ai (ProviderError (..))
import Servant (ServerError (..))
import Test.HUnit (Test (..), assertBool, assertEqual)

-- | Assert safe public statuses and corrective messages for every error category.
tests :: Test
tests = TestLabel "safe provider error contract" $ TestList
  [ TestLabel label $ TestCase $ do
      let response = handleProviderError providerError
          body = BL.toStrict (errBody response)
      assertEqual "public HTTP status" expectedStatus (errHTTPCode response)
      assertBool "message gives an application-owned correction" (expectedGuidance `BS.isInfixOf` body)
      assertBool "internal diagnostics are never echoed" (not ("PRIVATE_DIAGNOSTIC test-key" `BS.isInfixOf` body))
      assertBool "messages apply to both prompt and grading" (not ("Prompt generation" `BS.isInfixOf` body))
  | (label, providerError, expectedStatus, expectedGuidance) <-
      [ ("model selection", ModelNotSelected, 422, "account preferences")
      , ("unimplemented operation", ProviderNotImplemented, 501, "AI operation")
      , ("fallback failure is redacted", GenerationFailed "PRIVATE_DIAGNOSTIC test-key", 502, "retry")
      , ("missing configuration is redacted", ProviderConfigurationMissing "PRIVATE_DIAGNOSTIC test-key", 500, "OPENAI_BASE_URL and OPENAI_API_KEY")
      , ("invalid provider URL", ProviderConfigurationInvalid "OPENAI_BASE_URL", 500, "absolute HTTP or HTTPS")
      , ("invalid API key", ProviderConfigurationInvalid "OPENAI_API_KEY", 500, "single line")
      , ("unknown configuration diagnostic is redacted", ProviderConfigurationInvalid "PRIVATE_DIAGNOSTIC test-key", 500, "backend environment")
      , ("timeout", ProviderTimedOut, 504, "timed out")
      , ("connection failure", ProviderConnectionFailed, 502, "network access")
      , ("invalid output", ProviderInvalidResponse, 502, "JSON schema")
      , ("unknown upstream error is redacted", ProviderHttpError 418 (Just "PRIVATE_DIAGNOSTIC test-key"), 502, "model compatibility")
      ]
  ]
