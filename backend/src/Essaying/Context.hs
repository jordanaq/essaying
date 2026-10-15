{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE DisambiguateRecordFields #-}

module Essaying.Context
  ( EffectiveContext (..)
  , emptyEffectiveContext
  , applyLayer
  , loadEffectiveContext
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Essaying.Types.Context
  ( ContextLayer (..)
  , EffectiveContext (..)
  , ListOverride (..)
  , RubricOverride (..)
  , RubricCriterion
  , ScalarOverride (..)
  )
import Essaying.Types.Storage (WorkspaceRoot)

emptyEffectiveContext :: EffectiveContext
emptyEffectiveContext =
  EffectiveContext
    { title = Nothing
    , audience = Nothing
    , model = Nothing
    , tags = []
    , instructions = []
    , grading_directions = []
    , rubric = Map.empty
    }

applyLayer :: EffectiveContext -> ContextLayer -> EffectiveContext
applyLayer parent layer =
  EffectiveContext
    { title = applyScalar parent.title layer.title
    , audience = applyScalar parent.audience layer.audience
    , model = applyScalar parent.model layer.model
    , tags = deduplicateTags (applyList parent.tags layer.tags)
    , instructions = applyList parent.instructions layer.instructions
    , grading_directions = applyList parent.grading_directions layer.grading_directions
    , rubric = applyRubric parent.rubric layer.rubric
    }

applyScalar :: Maybe a -> Maybe (ScalarOverride a) -> Maybe a
applyScalar inherited Nothing = inherited
applyScalar _ (Just (SetScalar value)) = Just value
applyScalar _ (Just ClearScalar) = Nothing

applyList :: [a] -> Maybe (ListOverride a) -> [a]
applyList inherited Nothing = inherited
applyList inherited (Just (AppendList items)) = inherited <> items
applyList _ (Just (ReplaceList items)) = items

applyRubric :: Map.Map Text RubricCriterion -> Maybe RubricOverride -> Map.Map Text RubricCriterion
applyRubric inherited Nothing = inherited
applyRubric inherited (Just (MergeRubric criteria)) = Map.union criteria inherited
applyRubric _ (Just (ReplaceRubric criteria)) = criteria

deduplicateTags :: Ord a => [a] -> [a]
deduplicateTags = go Set.empty
  where
    go _ [] = []
    go seen (item : rest)
      | Set.member item seen = go seen rest
      | otherwise = item : go (Set.insert item seen) rest

loadEffectiveContext :: WorkspaceRoot -> FilePath -> IO EffectiveContext
loadEffectiveContext _currentPath _rootPath =
  -- Temporary stub: context.json inheritance/parsing will be implemented later.
  pure emptyEffectiveContext
