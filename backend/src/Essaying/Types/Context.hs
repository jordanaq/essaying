{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

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
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, Value (..))
import Data.Aeson.Key (Key)
import Data.Text qualified as Text
import Data.Map.Strict qualified as Map
import Data.Map.Strict (Map)
import Data.Set qualified as Set


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
  parseJSON value = do
    case value of
      Object object
        | KeyMap.lookup "tag" object == Just (String "ClearScalar")
        -> checkShape "ScalarOverride" ["tag"] value
      Object object
        | KeyMap.lookup "tag" object == Just (String "SetScalar")
        -> checkShape "ScalarOverride" ["tag", "contents"] value
      _ -> fail "Invalid ScalarOverride tag"

    genericParseJSON defaultOptions { rejectUnknownFields = True } value

instance FromJSON a => FromJSON (ListOverride a) where
  parseJSON value = do
    checkShape "ListOverride" ["tag", "contents"] value

    genericParseJSON defaultOptions { rejectUnknownFields = True } value

instance FromJSON RubricOverride where
  parseJSON value = do
    checkShape "RubricOverride" ["tag", "contents"] value

    override <- genericParseJSON defaultOptions { rejectUnknownFields = True } value

    let criteria = case override of
          MergeRubric m -> m
          ReplaceRubric m -> m

    if any (Text.null . Text.strip) (Map.keys criteria)
      then fail "Rubric contains empty criterion keys"
      else pure override

instance FromJSON RubricCriterion where
  parseJSON value = do
    criterion <- genericParseJSON defaultOptions { rejectUnknownFields = True } value
    case criterion of
      RubricCriterion { weight = w } | w < 0 || isNaN w || isInfinite w ->
        fail "Rubric criterion contains invalid weight"
      RubricCriterion { description = Just desc } | Text.null (Text.strip desc) ->
        fail "Rubric criterion contains empty description"
      _ -> pure criterion

instance FromJSON ContextLayer where
  parseJSON value = do
    layer <- genericParseJSON defaultOptions { rejectUnknownFields = True } value
    let ContextLayer
          { title = titleOverride
          , audience = audienceOverride
          , model = modelOverride
          , tags = tagsOverride
          , instructions = instructionsOverride
          , grading_directions = gradingDirectionsOverride
          } = layer

    mapM_ (uncurry validateScalar)
      [ ("title", titleOverride)
      , ("audience", audienceOverride)
      , ("model", modelOverride)
      ]

    mapM_ (uncurry validateList)
      [ ("tags", tagsOverride)
      , ("instructions", instructionsOverride)
      , ("grading_directions", gradingDirectionsOverride)
      ]
    pure layer

checkShape :: String -> [Key] -> Value -> Parser ()
checkShape fieldName requiredKeys (Object object)
  | Set.fromList (KeyMap.keys object) /= Set.fromList requiredKeys =
      fail (fieldName <> " has missing or unexpected fields")
  | otherwise = pure ()
checkShape _ _ _ = pure ()

validateScalar :: String -> Maybe (ScalarOverride Text) -> Parser ()
validateScalar field (Just (SetScalar text))
  | Text.null (Text.strip text) = fail (field <> " must not be blank")
validateScalar _ _ = pure ()

validateList :: String -> Maybe (ListOverride Text) -> Parser ()
validateList field (Just (AppendList items)) = validateItems field items
validateList field (Just (ReplaceList items)) = validateItems field items
validateList _ Nothing = pure ()

validateItems :: String -> [Text] -> Parser ()
validateItems field items
  | any (Text.null . Text.strip) items = fail (field <> " must not contain blank items")
  | otherwise = pure ()
