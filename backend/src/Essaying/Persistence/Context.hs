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
import Control.Monad (foldM)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BL
import Data.Aeson.Parser (eitherDecodeStrictWith, jsonNoDup')
import Data.Aeson.Types (ifromJSON)
import Data.Attoparsec.ByteString (endOfInput, skipWhile)
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Data.Word (Word8)
import Essaying.Context (emptyEffectiveContext, applyLayer)
import Essaying.Persistence.Workspace (isEssayFile, isSafeSegment, safeResolvePath)
import Essaying.Types.Context (ContextLayer, ContextLayerError (..), EffectiveContext, EffectiveContextError (..))
import Essaying.Types.Storage (WorkspaceRoot (..))
import Essaying.Utils (debug_)
import System.Directory (doesFileExist, pathIsSymbolicLink, removeFile)
import System.FilePath ((</>), isAbsolute, makeRelative)
import System.IO.Error (ioeGetErrorString, isDoesNotExistError)

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
              case eitherDecodeStrictWith (jsonNoDup' <* skipWhile isJsonSpace <* endOfInput) ifromJSON bytes of
                Left (_, message) -> do
                  debug 3 $ "Invalid context file=" <> show relativePath <> ": " <> message
                  pure (Left (ContextLayerJsonError relativePath message))
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

-- | JSON permits only these four whitespace bytes after the single document.
-- The low-level duplicate-checking parser alone accepts trailing input.
isJsonSpace :: Word8 -> Bool
isJsonSpace byte = byte == 32 || byte == 10 || byte == 13 || byte == 9

-- | Write a validated layer below a trusted workspace root. Parent directories
-- must already exist; symbolic links are rejected just as they are on reads.
saveContextLayer :: WorkspaceRoot -> FilePath -> ContextLayer -> IO (Either ContextLayerError ())
saveContextLayer workspace path layer = do
  target <- resolveContextTarget workspace path
  case target of
    Left err -> pure (Left err)
    Right (fullPath, _) -> do
      let bytes = BL.toStrict (encode layer)
      case eitherDecodeStrictWith (jsonNoDup' <* skipWhile isJsonSpace <* endOfInput) ifromJSON bytes of
        Left (_, message) -> pure (Left (ContextLayerJsonError path message))
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
