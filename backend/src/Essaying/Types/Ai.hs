{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}

{- | AI endpoint contracts, provider assessments, and shared failure categories.
Provider grades are validated before becoming public, weighted responses.
-}
module Essaying.Types.Ai (
  PromptRequest (..),
  PromptResponse (..),
  GradeRequest (..),
  GradeResponse (..),
  CriterionGrade (..),
  ProviderGrade (..),
  ProviderCriterionGrade (..),
  ProviderError (..),
)
where

import Data.Map (Map)
import Data.Text (Text)

import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)

{- | Request fresh assignment options using an existing essay's resolved context.
The backend supplies provider configuration and selects the model.
-}
data PromptRequest = PromptRequest
  { path :: FilePath
  -- ^ Workspace-relative essay directory, not an internal file.
  , instructions :: Maybe Text
  -- ^ Extra generation instructions; may request an option count.
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Validated assignment candidates. Returning them does not save @prompt.md@.
data PromptResponse = PromptResponse
  { prompts :: [Text]
  -- ^ Nonempty, ordered Markdown options, including singleton results.
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Grade the saved draft and optional saved assignment, rather than editor text.
data GradeRequest = GradeRequest
  { path :: FilePath
  -- ^ Workspace-relative directory containing @essay.md@.
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Public assessment after criterion validation and application-side weighting.
data GradeResponse = GradeResponse
  { overallScore :: Double
  -- ^ Weighted average of the criterion scores on a 0-100 scale.
  , feedback :: Text
  -- ^ Nonblank overall feedback supplied by the provider.
  , criteria :: Map Text CriterionGrade
  -- ^ Exactly the effective rubric's criterion names.
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One validated assessment with its application-calculated share of the grade.
data CriterionGrade = CriterionGrade
  { score :: Double
  -- ^ Finite provider score between 0 and 100, inclusive.
  , feedback :: Text
  -- ^ Nonblank feedback explaining this criterion's assessment.
  , normalizedWeight :: Double
  -- ^ Rubric weight divided by the positive total; may be zero.
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Raw criterion output. JSON decoding checks shape; the handler checks values.
data ProviderCriterionGrade = ProviderCriterionGrade
  { score :: Double
  -- ^ Expected to be finite and within 0-100; not trusted until validated.
  , feedback :: Text
  -- ^ Criterion feedback, checked for nonblank content before returning.
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Provider assessment without weights or an overall score.
The handler checks that criterion names match the resolved rubric exactly.
-}
data ProviderGrade = ProviderGrade
  { feedback :: Text
  -- ^ Overall feedback, checked for nonblank content by the handler.
  , criteria :: Map Text ProviderCriterionGrade
  -- ^ Assessments keyed by rubric criterion name.
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

{- | Backend failure categories shared by prompting and grading.
Convert through the handler's public error mapper; text payloads can contain
private diagnostics and must not be returned or logged indiscriminately.
-}
data ProviderError
  = -- | Neither effective context nor account preferences select a model.
    ModelNotSelected
  | -- | Reserved for an AI operation without an implementation.
    ProviderNotImplemented
  | -- | Missing backend setting names or diagnostic.
    ProviderConfigurationMissing Text
  | -- | Invalid setting name, such as @OPENAI_BASE_URL@.
    ProviderConfigurationInvalid Text
  | -- | Connection/response timeout or the operation's outer deadline.
    ProviderTimedOut
  | -- | Transport failed without a more specific classification.
    ProviderConnectionFailed
  | -- | Malformed/incomplete output or an invalid grading assessment.
    ProviderInvalidResponse
  | -- | Upstream status and optional private error message.
    ProviderHttpError Int (Maybe Text)
  | -- | Internal fallback, also used for an invalid normalization total.
    GenerationFailed Text
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)
