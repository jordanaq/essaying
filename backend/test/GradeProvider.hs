{-# LANGUAGE OverloadedStrings #-}

module GradeProvider (tests) where

import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Essaying.Provider.OpenAiCompatible (decodeGradeResponse)
import Essaying.Types.Ai
  ( CriterionGrade (..), GradeResponse (..), ProviderCriterionGrade (..)
  , ProviderError (..), ProviderGrade (..)
  )
import Test.HUnit (Test (..), assertEqual, assertFailure)

tests :: Test
tests = TestLabel "grading provider decoding" $ TestList $
  [ TestLabel "recorded real response preserves every score and feedback string" $ TestCase $ do
      recorded <- BL.readFile "test/fixtures/provider/gpt-6.1-sol-grade.response.json"
      golden <- BL.readFile "test/fixtures/provider/gpt-6.1-sol-grade.expected.json"
      case eitherDecode golden of
        Left err -> assertFailure ("invalid grade fixture: " <> err)
        Right (GradeResponse _ feedback criteria) ->
          assertEqual "provider returns assessments without application-calculated weights"
            (Right (ProviderGrade feedback (Map.map (\(CriterionGrade score text _) -> ProviderCriterionGrade score text) criteria)))
            (decodeGradeResponse recorded)
  , TestLabel "valid Unicode grade decodes without changing its text" $ TestCase $
      assertEqual "criterion names and feedback retain Unicode"
        (Right (ProviderGrade "Révision utile" (Map.singleton "宗教" (ProviderCriterionGrade 80 "Café: précision"))))
        (decodeGradeResponse (completion "stop" (payload "Révision utile")))
  ] <> [ TestLabel label $ TestCase $
           assertEqual "invalid envelopes or grading payloads are rejected with a safe error"
             (Left ProviderInvalidResponse) (decodeGradeResponse bytes)
       | (label, bytes) <-
           [ ("malformed envelope", "not JSON")
           , ("no choices", "{\"choices\":[]}")
           , ("missing choices", "{}")
           , ("truncated completion", completion "length" (payload "Feedback"))
           , ("tool call completion", completion "tool_calls" (payload "Feedback"))
           , ("missing assistant message", "{\"choices\":[{\"finish_reason\":\"stop\"}]}")
           , ("refusal without content", "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":null,\"refusal\":\"Cannot assess\"}}]}")
           , ("blank content", completion "stop" " \n\t")
           , ("malformed inner JSON", completion "stop" "not JSON")
           , ("missing overall feedback", completion "stop" "{\"criteria\":{}}")
           , ("criteria is an array", completion "stop" "{\"feedback\":\"F\",\"criteria\":[]}")
           , ("criterion score has the wrong type", completion "stop" "{\"feedback\":\"F\",\"criteria\":{\"argument\":{\"score\":\"high\",\"feedback\":\"F\"}}}")
           , ("criterion feedback is missing", completion "stop" "{\"feedback\":\"F\",\"criteria\":{\"argument\":{\"score\":80}}}")
           ]
       ]

completion :: Text -> Text -> BL.ByteString
completion finishReason content = encode $ object
  [ "choices" .= [object
      [ "finish_reason" .= finishReason
      , "message" .= object ["content" .= content]
      ]]
  ]

payload :: Text -> Text
payload feedback = TL.toStrict $ TLE.decodeUtf8 $ encode $ object
  [ "feedback" .= feedback
  , "criteria" .= object
      [ "宗教" .= object ["score" .= (80 :: Int), "feedback" .= ("Café: précision" :: Text)] ]
  ]
