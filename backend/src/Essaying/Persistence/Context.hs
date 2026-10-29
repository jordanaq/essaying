{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

module Essaying.Persistence.Context
  ( loadContextLayer
  , loadEffectiveContext
  , saveContextLayer
  , deleteContextLayer
  )
where

import Control.Exception (IOException, try)
import Control.Monad (foldM, unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Essaying.Context (emptyEffectiveContext, applyLayer)
import Essaying.Persistence.Workspace (essayDraftFileName, isEssayDir, isSafeSegment, requireNonEssayParents, safeResolvePath)
import Essaying.Persistence.Utils (PathCheckError (..), checkPathEntries)
import Essaying.Types.Context (decodeContextLayer, ContextLayer, ContextLayerError (..), EffectiveContext, EffectiveContextError (..))
import Essaying.Types.Storage (WorkspaceRoot (..))
import Essaying.Utils (debug_)
import System.Directory (removeFile, doesFileExist)
import System.FilePath ((</>), isAbsolute)
import System.IO.Error (ioeGetErrorString)

-- | Emit context filesystem messages when @HESSAY_DEBUG@ is at least 3.
debug :: Int -> String -> IO ()
debug = debug_ "[Context]"

-- | Load and apply @context.json@ files from the workspace root through the
-- essay directory itself, in that order. The essay path must be a safe,
-- workspace-relative directory containing a regular @essay.md@ file. Missing
-- context files are skipped; invalid or unreadable ones return an error.
loadEffectiveContext :: WorkspaceRoot -> FilePath -> IO (Either EffectiveContextError EffectiveContext)
loadEffectiveContext workspaceRoot essayPath = do
  validated <- validateEssayPath workspaceRoot essayPath
  case validated of
    Left err -> pure (Left err)
    Right essaySegments -> do
      let contextDirs = scanl (</>) "" essaySegments
          contextPaths = map (</> "context.json") contextDirs
      resolved <- foldM foldContextH (Right emptyEffectiveContext) contextPaths
      case resolved of
        Right _ -> debug 3 $ "Resolved context for essay=" <> show essayPath
        Left _ -> pure ()
      pure resolved
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

-- | Validate an essay directory and return its workspace-relative directory
-- segments. Reject unsafe paths, symbolic links (including the draft marker),
-- missing markers, and targets nested inside another essay.
validateEssayPath :: WorkspaceRoot -> FilePath -> IO (Either EffectiveContextError [FilePath])
validateEssayPath workspaceRoot@(WorkspaceRoot root) essayPath = runExceptT $ do
  segments <- ExceptT $ pure $
    maybe (Left (EffectiveContextInvalidPath essayPath)) Right (relativeSegments essayPath)

  fullPath <- ExceptT $ pure $
    maybe (Left (EffectiveContextInvalidPath essayPath)) Right
      (safeResolvePath workspaceRoot (map Text.pack segments))

  isFile <- checkedIO $ doesFileExist fullPath
  when isFile $ throwE (EffectiveContextEssayNotFound essayPath)

  let directoryPaths = scanl (</>) root segments
      draftPath = fullPath </> essayDraftFileName

  checked <- liftIO $ checkEntries root (directoryPaths <> [draftPath])
  exists <- ExceptT $ pure $
    either (Left . essayPathError essayPath) Right checked
  unless exists $ throwE (EffectiveContextEssayNotFound essayPath)

  isEssay <- checkedIO $ isEssayDir fullPath
  unless isEssay $ throwE (EffectiveContextEssayNotFound essayPath)

  parentCheck <- checkedIO $ runExceptT $
    requireNonEssayParents (EffectiveContextInvalidPath essayPath)
      workspaceRoot (map Text.pack (init segments))
  either throwE pure parentCheck

  pure segments
  where
    checkedIO :: IO a -> ExceptT EffectiveContextError IO a
    checkedIO action = ExceptT $ do
      result <- try action
      pure $ case result of
        Left (err :: IOException) -> Left (EffectiveContextIoError essayPath (ioeGetErrorString err))
        Right value -> Right value

-- | Translate a path-check error into the corresponding essay-path error.
essayPathError :: FilePath -> ContextLayerError -> EffectiveContextError
essayPathError essayPath (ContextLayerInvalidPath _) = EffectiveContextEssayNotFound essayPath
essayPathError _ (ContextLayerSymbolicLink path) = EffectiveContextSymbolicLink path
essayPathError _ (ContextLayerIoError path message) = EffectiveContextIoError path message
essayPathError _ (ContextLayerJsonError path message) = EffectiveContextJsonError path message

-- | Load one workspace-relative @context.json@ file. Return 'Right' 'Nothing'
-- when the file itself is absent. Unsafe paths, missing parent directories,
-- symbolic links, I/O failures, duplicate JSON keys, and invalid JSON are errors.
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
              case decodeContextLayer bytes of
                Left diagnostic -> do
                  debug 3 $ "Invalid context file=" <> show relativePath
                  pure (Left (ContextLayerJsonError relativePath diagnostic))
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
checkEntries root paths = do
  checked <- checkPathEntries root paths
  pure $ case checked of
    Right exists -> Right exists
    Left (PathSymbolicLink label) -> Left (ContextLayerSymbolicLink label)
    Left (PathMissingParent label _) -> Left (ContextLayerInvalidPath label)
    Left (PathIoError label err) -> Left (ContextLayerIoError label (ioeGetErrorString err))

-- | Write a validated layer below a trusted workspace root. Parent directories
-- must already exist; symbolic links are rejected just as they are on reads.
saveContextLayer :: WorkspaceRoot -> FilePath -> ContextLayer -> IO (Either ContextLayerError ())
saveContextLayer workspace path layer = do
  target <- resolveContextTarget workspace path
  case target of
    Left err -> pure (Left err)
    Right (fullPath, _) -> do
      let bytes = BL.toStrict (encode layer)
      case decodeContextLayer bytes of
        Left diagnostic -> pure (Left (ContextLayerJsonError path diagnostic))
        Right (_ :: ContextLayer) -> do
          result <- try (BS.writeFile fullPath bytes) :: IO (Either IOException ())
          pure $ case result of
            Left err -> Left (ContextLayerIoError path (ioeGetErrorString err))
            Right () -> Right ()

-- | Delete only a workspace-relative context file. False means it was absent.
deleteContextLayer :: WorkspaceRoot -> FilePath -> IO (Either ContextLayerError Bool)
deleteContextLayer workspace path = do
  target <- resolveContextTarget workspace path
  case target of
    Left err -> pure (Left err)
    Right (_, False) -> pure (Right False)
    Right (fullPath, True) -> do
      result <- try (removeFile fullPath) :: IO (Either IOException ())
      pure $ case result of
        Left err -> Left (ContextLayerIoError path (ioeGetErrorString err))
        Right () -> Right True

-- | Resolve paths from the workspace, never from the process working directory.
resolveContextTarget :: WorkspaceRoot -> FilePath -> IO (Either ContextLayerError (FilePath, Bool))
resolveContextTarget (WorkspaceRoot root) path =
  case contextSegments path of
    Nothing -> pure (Left (ContextLayerInvalidPath path))
    Just segments -> do
      let paths = scanl (</>) root segments
      checked <- checkEntries root paths
      pure $ fmap (\exists -> (last paths, exists)) checked
