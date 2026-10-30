{-# LANGUAGE OverloadedStrings #-}

-- | Pure grading validation and independently expected weighted-score tests.
module GradeNormalization (tests) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Essaying.Handler.Ai (normalizeGrade)
import Essaying.Types.Ai
  ( CriterionGrade (..), GradeResponse (..), ProviderCriterionGrade (..)
  , ProviderError (..), ProviderGrade (..)
  )
import Essaying.Types.Context (RubricCriterion (..))
import Test.HUnit (Assertion, Test (..), assertBool, assertEqual, assertFailure)

-- | Check weighted means, retained zero-weight criteria, and every rejection guard.
tests :: Test
tests = TestLabel "grade validation and normalization" $ TestList $
  [ TestLabel "relative weights produce a weighted average and preserve feedback" $ TestCase $
      assertGrade 80 "Overall feedback"
        [ ("argument", CriterionGrade 90 "Argument feedback" (2 / 3))
        , ("evidence", CriterionGrade 60 "Evidence feedback" (1 / 3))
        ] (normalizeGrade sampleGrade sampleRubric)
  , TestLabel "zero-weight criteria remain present without changing the overall score" $ TestCase $
      assertGrade 80 "Overall feedback"
        [ ("argument", CriterionGrade 90 "Argument feedback" (2 / 3))
        , ("evidence", CriterionGrade 60 "Evidence feedback" (1 / 3))
        , ("style", CriterionGrade 100 "Style feedback" 0)
        ] (normalizeGrade
          (grade [("argument", 90, "Argument feedback"), ("evidence", 60, "Evidence feedback"), ("style", 100, "Style feedback")])
          (rubric [("argument", 2), ("evidence", 1), ("style", 0)]))
  , TestLabel "scores at both boundaries are valid" $ TestCase $
      assertGrade 50 "Overall feedback"
        [("argument", CriterionGrade 0 "Low" 0.5), ("evidence", CriterionGrade 100 "High" 0.5)]
        (normalizeGrade (grade [("argument", 0, "Low"), ("evidence", 100, "High")])
          (rubric [("argument", 1), ("evidence", 1)]))
  , TestLabel "a single criterion has full weight" $ TestCase $
      assertGrade 75 "Overall feedback" [("argument", CriterionGrade 75 "Feedback" 1)]
        (normalizeGrade (grade [("argument", 75, "Feedback")]) (rubric [("argument", 7)]))
  , TestLabel "weights already summing to one retain their proportions" $ TestCase $
      assertGrade 70 "Overall feedback"
        [("argument", CriterionGrade 100 "A" 0.25), ("evidence", CriterionGrade 60 "E" 0.75)]
        (normalizeGrade (grade [("argument", 100, "A"), ("evidence", 60, "E")])
          (rubric [("argument", 0.25), ("evidence", 0.75)]))
  ]
  <> [ rejects label ProviderInvalidResponse provider expectedRubric
     | (label, provider, expectedRubric) <-
         [ ("missing criterion", grade [("argument", 90, "A")], sampleRubric)
         , ("unexpected criterion", grade [("argument", 90, "A"), ("evidence", 60, "E"), ("extra", 50, "X")], sampleRubric)
         , ("different criterion with the same count", grade [("argument", 90, "A"), ("other", 60, "E")], sampleRubric)
         , ("missing zero-weight criterion", sampleGrade, rubric [("argument", 2), ("evidence", 1), ("style", 0)])
         ]
     ]
  <> [ rejects label ProviderInvalidResponse
         (grade [("argument", invalidScore, "A"), ("evidence", 60, "E")]) sampleRubric
     | (label, invalidScore) <-
         [("negative score", -0.01), ("score above 100", 100.01), ("NaN score", 0 / 0)
         , ("positive infinite score", 1 / 0), ("negative infinite score", -1 / 0)]
     ]
  <> [ rejects label ProviderInvalidResponse (ProviderGrade feedbackText assessments) sampleRubric
     | (label, feedbackText) <- [("empty overall feedback", ""), ("whitespace-only overall feedback", " \n\t ")]
     , let ProviderGrade _ assessments = sampleGrade
     ]
  <> [ rejects label ProviderInvalidResponse
         (grade [("argument", 90, feedbackText), ("evidence", 60, "E")]) sampleRubric
     | (label, feedbackText) <- [("empty criterion feedback", ""), ("whitespace-only criterion feedback", " \n\t ")]
     ]
  <> [ rejects label (GenerationFailed "Total weight of rubric criteria is invalid") sampleGrade (rubric weights)
     | (label, weights) <-
         [ ("all-zero weights", [("argument", 0), ("evidence", 0)])
         , ("negative total weight", [("argument", -2), ("evidence", 1)])
         , ("NaN total weight", [("argument", 0 / 0), ("evidence", 1)])
         , ("infinite total weight", [("argument", 1 / 0), ("evidence", 1)])
         , ("finite weights overflow when summed", [("argument", 1e308), ("evidence", 1e308)])
         ]
     ]
  <> [ rejects "empty rubric and assessments" (GenerationFailed "Total weight of rubric criteria is invalid") (grade []) Map.empty ]

-- | Two raw assessments with independently known scores and feedback.
sampleGrade :: ProviderGrade
sampleGrade = grade [("argument", 90, "Argument feedback"), ("evidence", 60, "Evidence feedback")]

-- | Relative weights 2:1; the expected weighted score is 80.
sampleRubric :: Map Text RubricCriterion
sampleRubric = rubric [("argument", 2), ("evidence", 1)]

-- | Construct provider assessments without precomputing application-owned weights.
grade :: [(Text, Double, Text)] -> ProviderGrade
grade entries = ProviderGrade "Overall feedback" $
  Map.fromList [(name, ProviderCriterionGrade score feedback) | (name, score, feedback) <- entries]

-- | Build test rubric entries from relative weights without descriptions.
rubric :: [(Text, Double)] -> Map Text RubricCriterion
rubric entries = Map.fromList [(name, RubricCriterion weight Nothing) | (name, weight) <- entries]

-- | Require a particular failure category for an invalid assessment or rubric.
rejects :: String -> ProviderError -> ProviderGrade -> Map Text RubricCriterion -> Test
rejects label expectedError provider expectedRubric = TestLabel label $ TestCase $
  assertEqual "rejects the invalid assessment with the expected reason"
    (Left expectedError) (normalizeGrade provider expectedRubric)

-- | Compare complete feedback/criteria and allow small floating-point rounding error.
assertGrade :: Double -> Text -> [(Text, CriterionGrade)] -> Either ProviderError GradeResponse -> Assertion
assertGrade expectedOverall expectedFeedback expectedCriteria result = case result of
  Left err -> assertFailure ("expected a valid grade, got " <> show err)
  Right (GradeResponse overall feedback criteria) -> do
    assertClose "overall score" expectedOverall overall
    assertEqual "overall feedback" expectedFeedback feedback
    assertEqual "all criterion names are preserved" (Map.keysSet (Map.fromList expectedCriteria)) (Map.keysSet criteria)
    mapM_ (\(name, CriterionGrade expectedScore expectedText expectedWeight) ->
      case Map.lookup name criteria of
        Nothing -> assertFailure "expected criterion is missing"
        Just (CriterionGrade score text weight) -> do
          assertEqual "criterion score" expectedScore score
          assertEqual "criterion feedback" expectedText text
          assertClose "normalized weight" expectedWeight weight) expectedCriteria

-- | Reject non-finite results and compare numeric values with an absolute tolerance.
assertClose :: String -> Double -> Double -> Assertion
assertClose label expected actual =
  assertBool (label <> ": expected " <> show expected <> ", got " <> show actual)
    (not (isNaN actual || isInfinite actual) && abs (expected - actual) < 1e-10)
