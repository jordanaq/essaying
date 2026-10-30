{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

module Essaying.Types.Ai (
    PromptRequest (..),
    PromptResponse (..),
    GradeRequest (..),
    GradeResponse (..),
    CriterionGrade (..),
    PromptProviderError (..)
)
where

import Data.Text (Text)
import Data.Map (Map)

import GHC.Generics (Generic)
import Data.Aeson (FromJSON, ToJSON)


data PromptRequest = PromptRequest
  { path :: FilePath
  , instructions :: Maybe Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PromptResponse = PromptResponse
  { prompts :: [Text] }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)


data GradeRequest = GradeRequest
  { path :: FilePath }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data GradeResponse = GradeResponse
  { overallScore :: Double
  , feedback :: Text
  , criteria :: Map Text CriterionGrade
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CriterionGrade = CriterionGrade
  { score :: Double
  , feedback :: Text
  , normalizedWeight :: Double
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PromptProviderError
  = ModelNotSelected
  | PromptProviderNotImplemented
  | ProviderConfigurationMissing Text
  | GenerationFailed Text
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)
