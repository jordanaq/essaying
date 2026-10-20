{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module Essaying.Types.Context
  ( -- * Resolved and source context
    EffectiveContext (..)
  , ContextLayer (..)
    -- * Layer operations
  , ScalarOverride (..)
  , ListOverride (..)
  , RubricOverride (..)
  , RubricCriterion (..)
    -- * Loading errors
  , ContextLayerError (..)
  , EffectiveContextError (..)
    -- * Context mutation requests (workspace root is supplied by the server)
  , CreateContextRequest (..)
  , UpdateContextRequest (..)
  , DeleteContextRequest (..)
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


-- | Context available to an essay after all ancestor layers have been applied.
-- Unset scalars are 'Nothing'; collections contain their resolved values.
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

-- | One directory's optional context settings. An omitted or @null@ field
-- inherits its parent's value; supplied fields carry explicit operations.
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

-- | Set a scalar value or explicitly clear an inherited one.
data ScalarOverride a
  = SetScalar a
  | ClearScalar
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Append to an inherited list or replace it entirely. Replacing with an
-- empty list clears the field.
data ListOverride a
  = AppendList [a]
  | ReplaceList [a]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Merge named rubric criteria with inherited ones or replace the rubric.
-- A criterion in the child replaces its entire parent definition.
data RubricOverride
  = MergeRubric (Map Text RubricCriterion)
  | ReplaceRubric (Map Text RubricCriterion)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | One named rubric criterion. Its weight must be finite and nonnegative;
-- a supplied description must contain non-whitespace text.
data RubricCriterion = RubricCriterion
  { weight :: Double
  , description :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Reason a single context file could not be loaded.
-- Filesystem errors use workspace-relative paths; invalid-path errors retain
-- the supplied path.
data ContextLayerError
  = ContextLayerInvalidPath FilePath
  | ContextLayerSymbolicLink FilePath
  | ContextLayerIoError FilePath String
  | ContextLayerJsonError FilePath String
  deriving stock (Eq, Show)

-- | Reason context could not be resolved for an essay.
-- Errors from an ancestor @context.json@ retain their 'ContextLayerError'.
data EffectiveContextError
  = EffectiveContextInvalidPath FilePath
  | EffectiveContextEssayNotFound FilePath
  | EffectiveContextSymbolicLink FilePath
  | EffectiveContextIoError FilePath String
  | EffectiveContextJsonError FilePath String
  | EffectiveContextLayerError ContextLayerError
  deriving stock (Eq, Show)

data CreateContextRequest = CreateContextRequest
  { path :: FilePath
  , contextLayer :: ContextLayer
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data UpdateContextRequest = UpdateContextRequest
  { path :: FilePath
  , contextLayer :: ContextLayer
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data DeleteContextRequest = DeleteContextRequest
  { path :: FilePath
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

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

-- | Require exactly the listed keys in a tagged operation object.
-- Non-object values are left to the operation's decoder.
checkShape :: String -> [Key] -> Value -> Parser ()
checkShape fieldName requiredKeys (Object object)
  | Set.fromList (KeyMap.keys object) /= Set.fromList requiredKeys =
      fail (fieldName <> " has missing or unexpected fields")
  | otherwise = pure ()
checkShape _ _ _ = pure ()

-- | Reject a blank supplied scalar while allowing inheritance and clearing.
validateScalar :: String -> Maybe (ScalarOverride Text) -> Parser ()
validateScalar field (Just (SetScalar text))
  | Text.null (Text.strip text) = fail (field <> " must not be blank")
validateScalar _ _ = pure ()

-- | Check every supplied item for either list operation.
validateList :: String -> Maybe (ListOverride Text) -> Parser ()
validateList field (Just (AppendList items)) = validateItems field items
validateList field (Just (ReplaceList items)) = validateItems field items
validateList _ Nothing = pure ()

-- | Reject whitespace-only list items without changing valid text.
validateItems :: String -> [Text] -> Parser ()
validateItems field items
  | any (Text.null . Text.strip) items = fail (field <> " must not contain blank items")
  | otherwise = pure ()
