{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}

module Essaying.Types.Context
  ( EffectiveContext (..)
  , ContextLayer (..)
  , ScalarOverride (..)
  , ListOverride (..)
  , RubricOverride (..)
  , RubricCriterion (..)
  )
where

import GHC.Generics (Generic)
import Data.Text (Text)
import Data.Aeson
  ( FromJSON (..)
  , ToJSON
  , defaultOptions
  , genericParseJSON
  , rejectUnknownFields
  )
import Data.Map.Strict (Map)


data EffectiveContext = EffectiveContext
  { title :: Maybe Text
  , audience :: Maybe Text
  , model :: Maybe Text
  , tags :: [Text]
  , instructions :: [Text]
  , grading_directions :: [Text]
  , rubric :: Map Text RubricCriterion
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ContextLayer = ContextLayer
  { title :: Maybe (ScalarOverride Text)
  , audience :: Maybe (ScalarOverride Text)
  , model :: Maybe (ScalarOverride Text)
  , tags :: Maybe (ListOverride Text)
  , instructions :: Maybe (ListOverride Text)
  , grading_directions :: Maybe (ListOverride Text)
  , rubric :: Maybe RubricOverride
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data ScalarOverride a
  = SetScalar a
  | ClearScalar
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data ListOverride a
  = AppendList [a]
  | ReplaceList [a]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data RubricOverride
  = MergeRubric (Map Text RubricCriterion)
  | ReplaceRubric (Map Text RubricCriterion)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data RubricCriterion = RubricCriterion
  { weight :: Double
  , description :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON a => FromJSON (ScalarOverride a) where
  parseJSON =
    genericParseJSON defaultOptions { rejectUnknownFields = True }

instance FromJSON a => FromJSON (ListOverride a) where
  parseJSON =
    genericParseJSON defaultOptions { rejectUnknownFields = True }

instance FromJSON RubricOverride where
  parseJSON =
    genericParseJSON defaultOptions { rejectUnknownFields = True }

instance FromJSON RubricCriterion where
  parseJSON =
    genericParseJSON defaultOptions { rejectUnknownFields = True }

instance FromJSON ContextLayer where
  parseJSON =
    genericParseJSON defaultOptions { rejectUnknownFields = True }
