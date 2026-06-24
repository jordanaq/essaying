{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

module Essaying.Context
  ( Context (..)
  , RubricCriterion (..)
  , loadEffectiveContext
  )
where

import Control.Applicative ((<|>))
import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)

-- The context schema can be authored at any folder level and inherited by children.
data Context = Context
  { title :: Maybe Text
  , audience :: Maybe Text
  , model :: Maybe Text
  , instructions :: [Text]
  , rubric :: Map Text RubricCriterion
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data RubricCriterion = RubricCriterion
  { weight :: Double
  , description :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance Semigroup Context where
  -- Right side overrides scalar fields; lists/maps are merged.
  newer <> older =
    Context
      { title = title newer <|> title older
      , audience = audience newer <|> audience older
      , model = model newer <|> model older
      , instructions = instructions older <> instructions newer
      , rubric = rubric older <> rubric newer
      }

instance Monoid Context where
  mempty =
    Context
      { title = Nothing
      , audience = Nothing
      , model = Nothing
      , instructions = []
      , rubric = Map.empty
      }

loadEffectiveContext :: FilePath -> FilePath -> IO Context
loadEffectiveContext _currentPath _rootPath =
  -- Temporary stub: real context.yaml inheritance/parsing will be implemented later.
  pure mempty
