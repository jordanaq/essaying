{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Essaying.Persistence.Context
  ( -- * Result types
    ContextLayerError (..)
  , EffectiveContextError (..)
    -- * Context loading
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
import Essaying.Utils (debug_)
import System.Directory (doesFileExist, pathIsSymbolicLink)
import System.FilePath ((</>), isAbsolute, makeRelative)
import System.IO.Error (ioeGetErrorString, isDoesNotExistError)

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


-- | Emit context filesystem messages when @HESSAY_DEBUG@ is at least 3.
debug :: Int -> String -> IO ()
debug = debug_ "[Context]"

-- | Load and apply @context.json@ files from the workspace root through the
-- essay's parent directory, in that order. The essay path must be a safe,
-- workspace-relative @.md@ path to an existing file. Missing context files
-- are skipped; invalid or unreadable ones return an error.
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

-- | Validate an existing essay path and return its workspace-relative
-- segments. Reject unsafe paths, non-@.md@ targets, and symbolic links.
-- Context discovery reuses the segments to find ancestor directories.
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

-- | Translate a path-check error into the corresponding essay-path error.
essayPathError :: FilePath -> ContextLayerError -> EffectiveContextError
essayPathError essayPath (ContextLayerInvalidPath _) = EffectiveContextEssayNotFound essayPath
essayPathError _ (ContextLayerSymbolicLink path) = EffectiveContextSymbolicLink path
essayPathError _ (ContextLayerIoError path message) = EffectiveContextIoError path message
essayPathError _ (ContextLayerJsonError path message) = EffectiveContextJsonError path message

-- | Load one workspace-relative @context.json@ file. Return 'Right' 'Nothing'
-- when the file itself is absent. Unsafe paths, missing parent directories,
-- symbolic links, I/O failures, and invalid JSON are errors.
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
          case contents of
            Left err -> pure (Left (ContextLayerIoError relativePath (ioeGetErrorString err)))
            Right bytes ->
              case eitherDecodeStrict' bytes of
                Left message -> pure (Left (ContextLayerJsonError relativePath message))
                Right layer -> do
                  debug 3 $ "Loaded context file=" <> show relativePath
                  pure (Right (Just layer))

-- | Accept a safe relative path ending in @context.json@ and split it into
-- segments. Return 'Nothing' for any other path.
contextSegments :: FilePath -> Maybe [FilePath]
contextSegments path = do
  segments <- relativeSegments path
  if last segments == "context.json" then Just segments else Nothing

-- | Split a forward-slash-separated workspace path into safe, nonempty
-- segments. Reject absolute paths and unsafe segments.
relativeSegments :: FilePath -> Maybe [FilePath]
relativeSegments path
  | isAbsolute path = Nothing
  | otherwise =
      let segments = map Text.unpack (Text.splitOn "/" (Text.pack path))
       in if all (isSafeSegment . Text.pack) segments
            then Just segments
            else Nothing

-- | Check each path from the workspace root through the target for symbolic
-- links. Return 'False' only when the final entry is absent; a missing
-- intermediate entry or a symbolic link is an error.
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
