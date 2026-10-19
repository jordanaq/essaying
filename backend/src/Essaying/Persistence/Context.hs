{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Essaying.Persistence.Context
  ( ContextLayerError (..)
  , EffectiveContextError (..)
  , loadContextLayer
  , loadEffectiveContext
  )
where

import Control.Exception (IOException, try)
import Control.Monad (foldM)
import Data.Aeson (eitherDecodeStrict')
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Essaying.Context (emptyEffectiveContext, applyLayer)
import Essaying.Persistence.Workspace (isEssayFile, isSafeSegment, safeResolvePath)
import Essaying.Types.Context (ContextLayer, EffectiveContext)
import Essaying.Types.Storage (WorkspaceRoot (..))
import System.Directory (doesFileExist, pathIsSymbolicLink)
import System.FilePath ((</>), isAbsolute, makeRelative)
import System.IO.Error (ioeGetErrorString, isDoesNotExistError)

data ContextLayerError
  = ContextLayerInvalidPath FilePath
  | ContextLayerSymbolicLink FilePath
  | ContextLayerIoError FilePath String
  | ContextLayerJsonError FilePath String
  deriving stock (Eq, Show)

data EffectiveContextError
  = EffectiveContextInvalidPath FilePath
  | EffectiveContextEssayNotFound FilePath
  | EffectiveContextSymbolicLink FilePath
  | EffectiveContextIoError FilePath String
  | EffectiveContextJsonError FilePath String
  | EffectiveContextLayerError ContextLayerError
  deriving stock (Eq, Show)


-- | Resolve the context files from the workspace root to the essay's directory.
loadEffectiveContext :: WorkspaceRoot -> FilePath -> IO (Either EffectiveContextError EffectiveContext)
loadEffectiveContext workspaceRoot essayPath = do
  validated <- validateEssayPath workspaceRoot essayPath
  case validated of
    Left err -> pure (Left err)
    Right essaySegments -> do
      let contextDirs = scanl (</>) "" (init essaySegments)
          contextPaths = map (</> "context.json") contextDirs
      foldM foldContextH (Right emptyEffectiveContext) contextPaths
  where
    foldContextH
      :: Either EffectiveContextError EffectiveContext
      -> FilePath
      -> IO (Either EffectiveContextError EffectiveContext)
    foldContextH (Left err) _ = pure (Left err)
    foldContextH (Right ctx) path = do
      layerResult <- loadContextLayer workspaceRoot path
      case layerResult of
        Left layerErr -> pure $ Left (EffectiveContextLayerError layerErr)
        Right Nothing -> pure (Right ctx)
        Right (Just layer) -> pure (Right (applyLayer ctx layer))

-- | Validate an essay path and return its safe, workspace-relative segments.
-- Context discovery can reuse these segments without parsing the path again.
validateEssayPath :: WorkspaceRoot -> FilePath -> IO (Either EffectiveContextError [FilePath])
validateEssayPath workspaceRoot@(WorkspaceRoot root) essayPath =
  case relativeSegments essayPath of
    Nothing -> pure (Left (EffectiveContextInvalidPath essayPath))
    Just segments
      | not (isEssayFile (last segments)) ->
          pure (Left (EffectiveContextInvalidPath essayPath))
      | otherwise ->
          case safeResolvePath workspaceRoot (map Text.pack segments) of
            Nothing -> pure (Left (EffectiveContextInvalidPath essayPath))
            Just fullPath -> do
              checked <- checkEntries root (scanl (</>) root segments)
              case checked of
                Left err -> pure (Left (essayPathError essayPath err))
                Right False -> pure (Left (EffectiveContextEssayNotFound essayPath))
                Right True -> do
                  checkedFile <- try (doesFileExist fullPath) :: IO (Either IOException Bool)
                  pure $ case checkedFile of
                    Left err -> Left (EffectiveContextIoError essayPath (ioeGetErrorString err))
                    Right False -> Left (EffectiveContextEssayNotFound essayPath)
                    Right True -> Right segments

essayPathError :: FilePath -> ContextLayerError -> EffectiveContextError
essayPathError essayPath (ContextLayerInvalidPath _) = EffectiveContextEssayNotFound essayPath
essayPathError _ (ContextLayerSymbolicLink path) = EffectiveContextSymbolicLink path
essayPathError _ (ContextLayerIoError path message) = EffectiveContextIoError path message
essayPathError _ (ContextLayerJsonError path message) = EffectiveContextJsonError path message

-- | Load one workspace-relative context.json file. Only a missing file is
-- optional; invalid paths, links, I/O failures, and invalid JSON are errors.
loadContextLayer :: WorkspaceRoot -> FilePath -> IO (Either ContextLayerError (Maybe ContextLayer))
loadContextLayer (WorkspaceRoot root) relativePath =
  case contextSegments relativePath of
    Nothing -> pure (Left (ContextLayerInvalidPath relativePath))
    Just segments -> do
      let paths = scanl (</>) root segments
      checked <- checkEntries root paths
      case checked of
        Left err -> pure (Left err)
        Right False -> pure (Right Nothing)
        Right True -> do
          contents <- try (BS.readFile (last paths)) :: IO (Either IOException BS.ByteString)
          pure $ case contents of
            Left err -> Left (ContextLayerIoError relativePath (ioeGetErrorString err))
            Right bytes ->
              case eitherDecodeStrict' bytes of
                Left message -> Left (ContextLayerJsonError relativePath message)
                Right layer -> Right (Just layer)

contextSegments :: FilePath -> Maybe [FilePath]
contextSegments path = do
  segments <- relativeSegments path
  if last segments == "context.json" then Just segments else Nothing

relativeSegments :: FilePath -> Maybe [FilePath]
relativeSegments path
  | isAbsolute path = Nothing
  | otherwise =
      let segments = map Text.unpack (Text.splitOn "/" (Text.pack path))
       in if all (isSafeSegment . Text.pack) segments
            then Just segments
            else Nothing

checkEntries :: FilePath -> [FilePath] -> IO (Either ContextLayerError Bool)
checkEntries _ [] = pure (Right True)
checkEntries root (fullPath : remaining) = do
  let label = makeRelative root fullPath
  checked <- try (pathIsSymbolicLink fullPath) :: IO (Either IOException Bool)
  case checked of
    Right True -> pure (Left (ContextLayerSymbolicLink label))
    Right False -> checkEntries root remaining
    Left err
      | isDoesNotExistError err && null remaining -> pure (Right False)
      | isDoesNotExistError err -> pure (Left (ContextLayerInvalidPath label))
      | otherwise -> pure (Left (ContextLayerIoError label (ioeGetErrorString err)))
