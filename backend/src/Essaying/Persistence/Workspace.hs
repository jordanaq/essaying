{-# LANGUAGE OverloadedStrings #-}

module Essaying.Persistence.Workspace
  ( -- * Workspace operations
    listWorkspaceTree
  , loadWorkspaceEssay
  , createWorkspaceDirectory
  , createWorkspaceEssay
  , saveWorkspaceEssay
  , deleteWorkspaceEssay
  , deleteWorkspaceDirectory
    -- * Path helpers (internal, exported for testing)
  , loadWorkspaceNode
  , safeResolvePath
  , isSafeSegment
  , essayDraftPath
  , essayPromptPath
  , isEssayDir
  , requireNonEssayParents
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Essaying.Types.Storage (WorkspaceRoot (..))
import Essaying.Types.Workspace
  ( CreateWorkspaceDirectoryResult (..)
  , CreateWorkspaceEssayResult (..)
  , WorkspacePathError (..)
  , WorkspaceDeleteResult (..)
  , WorkspaceEssayContent (..)
  , WorkspaceNode (..)
  , WorkspaceNodeType (..)
  )
import Essaying.Utils (debug_)
import Essaying.Persistence.Utils (PathCheckError (..), checkPathEntries)
import Control.Exception (bracketOnError)
import Control.Monad (forM, guard, when, unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Control.Monad.Trans.Maybe (runMaybeT, MaybeT (..))
import Data.Maybe (catMaybes, fromJust, isJust)
import System.Directory (createDirectory, doesDirectoryExist, doesPathExist, doesFileExist, listDirectory, pathIsSymbolicLink, removeFile, removeDirectoryRecursive)
import System.FilePath ((</>), dropExtension, splitDirectories, takeDirectory, takeFileName)
import System.IO.Error (doesNotExistErrorType, mkIOError)


-- | Emit a workspace message when @HESSAY_DEBUG@ is at least the given level.
-- Workspace filesystem details use level 3.
debug :: Int -> String -> IO ()
debug = debug_ "[Workspace]"

-- | Required draft filename inside an essay directory.
essayDraftFileName :: FilePath
essayDraftFileName = "essay.md"

-- | Name of the prompt file inside an essay directory.
essayPromptFileName :: FilePath
essayPromptFileName = "prompt.md"

-- | Build the full path to the essay draft file within an essay directory.
essayDraftPath :: FilePath -> FilePath
essayDraftPath = (</> essayDraftFileName)

-- | Build the full path to the essay prompt file within an essay directory.
essayPromptPath :: FilePath -> FilePath
essayPromptPath = (</> essayPromptFileName)

-- | Check whether a path is a directory and contains an `essay.md` file.
isEssayDir :: FilePath -> IO Bool
isEssayDir path = do
  isDir <- doesDirectoryExist path
  if not isDir
    then return False
    else do
      isSymLink <- pathIsSymbolicLink path
      let essayPath = path </> essayDraftFileName
      if not isSymLink
        then
          doesFileExist essayPath >>= \exists ->
            if exists then not <$> pathIsSymbolicLink essayPath else return False
        else return False

-- | A path segment is safe if it is non-empty, contains no path
-- separators, and is not \"..\" or \".\".
isSafeSegment :: Text -> Bool
isSafeSegment segment =
  not (Text.null segment) &&
  segment /= "." &&
  segment /= ".." &&
  not (Text.any (`elem` ("/\\" :: String)) segment)

-- | Convert a list of path segments into a concrete 'FilePath' beneath
-- the workspace root. Returns 'Nothing' if any segment is unsafe.
-- This is lexical validation; it does not resolve symbolic links.
safeResolvePath :: WorkspaceRoot -> [Text] -> Maybe FilePath
safeResolvePath workspaceRoot segments =
  if all isSafeSegment segments
    then Just $ foldl (</>) (unWorkspaceRoot workspaceRoot) (map Text.unpack segments)
    else Nothing

-- | Resolve a non-root node, using the caller's error type.
resolveWorkspaceNodePath :: e -> WorkspaceRoot -> [Text] -> ExceptT e IO FilePath
resolveWorkspaceNodePath invalidPath workspaceRoot segments = do
  unless (not (null segments)) $ throwE invalidPath
  ExceptT $ pure $ maybe (Left invalidPath) Right (safeResolvePath workspaceRoot segments)

-- | Require organizational parents below the workspace root. Call after path
-- and symlink validation; the target itself is not included in parentSegments.
requireNonEssayParents :: e -> WorkspaceRoot -> [Text] -> ExceptT e IO ()
requireNonEssayParents nestedError workspaceRoot parentSegments = do
  let parents = drop 1 $
        scanl (</>) (unWorkspaceRoot workspaceRoot) (map Text.unpack parentSegments)
  mapM_ (\parent -> do
    isEssay <- liftIO $ isEssayDir parent
    when isEssay $ throwE nestedError) parents

-- | Validate an existing essay target without reading or modifying its draft.
requireWorkspaceEssay :: WorkspaceRoot -> [Text] -> ExceptT WorkspacePathError IO FilePath
requireWorkspaceEssay workspaceRoot segments = do
  path <- resolveWorkspaceNodePath (WorkspacePathInvalidPath segments) workspaceRoot segments
  exists <- liftIO $ doesPathExist path
  unless exists $ throwE (WorkspacePathTargetNotFound segments)
  isSymlink <- liftIO $ pathIsSymbolicLink path
  when isSymlink $ throwE (WorkspacePathSymbolicLink segments)
  isEssay <- liftIO $ isEssayDir path
  unless isEssay $ throwE (WorkspacePathWrongTargetType segments)
  requireNonEssayParents (WorkspacePathNestedEssay segments) workspaceRoot (init segments)
  pure path

-- | Reads and saves expose validation failure as Nothing rather than an error.
workspaceEssayPath :: WorkspaceRoot -> [Text] -> MaybeT IO FilePath
workspaceEssayPath workspaceRoot segments = MaybeT $
  either (const Nothing) Just <$> runExceptT (requireWorkspaceEssay workspaceRoot segments)

-- | Check if a given path has any symbolic link in its components.
hasSymlinkInPath :: FilePath -> IO Bool
hasSymlinkInPath path = do
  checked <- checkPathEntries "" (scanl1 (</>) (splitDirectories path))
  case checked of
    Left (PathSymbolicLink _) -> pure True
    Left (PathMissingParent _ err) -> ioError err
    Left (PathIoError _ err) -> ioError err
    Right True -> pure False
    Right False -> ioError (mkIOError doesNotExistErrorType "hasSymlinkInPath" Nothing (Just path))

-- | Recursively walk the workspace directory and produce a tree of
-- 'WorkspaceNode' values.  Directories become 'WorkspaceDirectoryNode';
-- @.md@ files become 'WorkspaceEssayNode'.  Non-@.md@ files (e.g.
-- @context.json@) are skipped.
listWorkspaceTree :: WorkspaceRoot -> IO [WorkspaceNode]
listWorkspaceTree workspaceRoot = listWorkspaceTreeAt [] (unWorkspaceRoot workspaceRoot)

-- | Scan a directory recursively, keeping directories and @.md@ files.
-- The supplied segments record its location relative to the workspace.
listWorkspaceTreeAt :: [Text] -> FilePath -> IO [WorkspaceNode]
listWorkspaceTreeAt parentSegments rootPath = do
  entries <- listDirectory rootPath
  nodes <- forM entries $ \entry -> do
    let fullPath = rootPath </> entry
        entryText = Text.pack entry

    isSym <- pathIsSymbolicLink fullPath
    if isSym
      then return Nothing
      else do
      isEssay <- isEssayDir fullPath
      if isEssay
        then do
          let nodeSegments = parentSegments <> [entryText]
          return $ Just $ WorkspaceNode entryText nodeSegments WorkspaceEssayNode []
        else do
          isDir <- doesDirectoryExist fullPath
          if isDir
            then do
              let nodeSegments = parentSegments <> [entryText]
              subNodes <- listWorkspaceTreeAt nodeSegments fullPath
              return $ Just $ WorkspaceNode entryText nodeSegments WorkspaceDirectoryNode subNodes
            else return Nothing

  return $ catMaybes nodes


-- | Load metadata for an existing node, recursively including all children.
-- Requires a nonempty path; unsafe or missing paths return 'Nothing'.
loadWorkspaceNode :: WorkspaceRoot -> [Text] -> IO (Maybe WorkspaceNode)
loadWorkspaceNode workspaceRoot segments = do
  let mPath = safeResolvePath workspaceRoot segments
  case mPath of
    Nothing -> return Nothing
    Just path -> runMaybeT $ do
      guard (not (null segments))
      isDir <- liftIO $ doesDirectoryExist path
      guard isDir
      isSym <- liftIO $ pathIsSymbolicLink path
      guard (not isSym)

      isEssay <- liftIO $ isEssayDir path
      if isEssay
        then pure $ WorkspaceNode (last segments) segments WorkspaceEssayNode []
        else do
          children <- liftIO $ listDirectory path
          childNodes <- liftIO $ mapM (\child -> loadWorkspaceNode workspaceRoot (segments <> [childSegment child])) children
          pure $ WorkspaceNode (last segments) segments WorkspaceDirectoryNode (catMaybes childNodes)
  where
    childSegment = Text.pack

-- | Load an essay using path segments that point to an essay dir.
-- Returns 'Nothing' if the directory is not an essay or the path is unsafe.
loadWorkspaceEssay :: WorkspaceRoot -> [Text] -> IO (Maybe WorkspaceEssayContent)
loadWorkspaceEssay workspaceRoot@(WorkspaceRoot root) segments = runMaybeT $ do
  path <- workspaceEssayPath workspaceRoot segments

  let promptPath = essayPromptPath path
      paths = scanl (</>) root (map Text.unpack segments)

  checked <- liftIO $ checkPathEntries root (paths <> [promptPath])

  promptText <- liftIO $ case checked of
    Right False -> pure ""
    Right True -> do
      isFile <- doesFileExist promptPath
      unless isFile $ ioError (userError "prompt.md must be a regular file")
      TextIO.readFile promptPath

    Left (PathSymbolicLink _) -> ioError (userError "Essay paths must not contain symbolic links")
    Left (PathMissingParent _ err) -> ioError err
    Left (PathIoError _ err) -> ioError err

  essayMarkdown <- liftIO $ TextIO.readFile (essayDraftPath path)

  pure $ WorkspaceEssayContent segments (last segments) promptText essayMarkdown

-- | Create a new directory under @parentPath@.  If the directory already
-- exists, return 'WorkspaceDirectoryAlreadyExists'. The parent must
-- already exist; unsafe paths return a failure and IO errors propagate.
createWorkspaceDirectory
  :: WorkspaceRoot
  -> [Text]    -- ^ parent path (may be empty for workspace root)
  -> Text      -- ^ new directory name
  -> IO CreateWorkspaceDirectoryResult
createWorkspaceDirectory workspaceRoot parentPath newDirName = do
  result <- runExceptT $ do
    let newPath = parentPath <> [newDirName]

    path <- resolveWorkspaceNodePath
      (WorkspaceDirectoryCreationFailed "Invalid path") workspaceRoot newPath

    doesParentExist <- liftIO $ doesDirectoryExist (takeDirectory path)
    unless doesParentExist $ throwE $ WorkspaceDirectoryCreationFailed "Parent directory does not exist"

    hasSymlink <- liftIO $ hasSymlinkInPath (takeDirectory path)
    when hasSymlink $ throwE $ WorkspaceDirectoryCreationFailed "Path contains a symbolic link"

    requireNonEssayParents (WorkspaceDirectoryCreationFailed "Path contains an essay directory") workspaceRoot parentPath

    doesExist <- liftIO $ doesPathExist path
    when doesExist $ throwE WorkspaceDirectoryAlreadyExists

    liftIO $ debug 3 ("Creating directory " <> show newDirName
                       <> " in workspace=" <> show (unWorkspaceRoot workspaceRoot)
                       <> " path=" <> show path)

    liftIO $ createDirectory path
    liftIO $ loadWorkspaceNode workspaceRoot newPath

  case result of
    Left failure -> return failure
    Right (Just workspaceNode) -> return $ WorkspaceDirectoryCreated workspaceNode
    Right Nothing -> return $ WorkspaceDirectoryCreationFailed "Failed to load created workspace node"

-- | Create a new essay directory under @parentPath@. If the essay already
-- exists, return 'WorkspaceEssayAlreadyExists'.  When @markdown@ is
-- 'Nothing', write an empty file. The parent must already exist;
-- unsafe paths return a failure and filesystem errors propagate.
createWorkspaceEssay
  :: WorkspaceRoot
  -> [Text]    -- ^ parent path
  -> Text      -- ^ essay name (without extension)
  -> Maybe Text -- ^ initial prompt content
  -> Maybe Text -- ^ initial markdown content
  -> IO CreateWorkspaceEssayResult
createWorkspaceEssay workspaceRoot parentPath essayName mPrompt mMarkdown = do
  result <- runExceptT $ do
    let segments = parentPath <> [essayName]

    path <- resolveWorkspaceNodePath
      (WorkspaceEssayCreationFailed "Invalid path") workspaceRoot segments

    doesParentExist <- liftIO $ doesDirectoryExist (takeDirectory path)
    unless doesParentExist $ throwE (WorkspaceEssayCreationFailed "Parent directory does not exist")

    hasSymlink <- liftIO $ hasSymlinkInPath (takeDirectory path)
    when hasSymlink $ throwE (WorkspaceEssayCreationFailed "Path contains a symbolic link")

    requireNonEssayParents (WorkspaceEssayCreationFailed "Nested essay detected")
      workspaceRoot parentPath

    isEssay <- liftIO $ isEssayDir path
    when isEssay $ throwE WorkspaceEssayAlreadyExists

    isDir <- liftIO $ doesDirectoryExist path
    when isDir $ throwE WorkspaceEssayClobbersDirectory

    -- Doesn't check for dangling symlinks but whatever
    pathHasTarget <- liftIO $ doesPathExist path
    when pathHasTarget $ throwE (WorkspaceEssayCreationFailed "Path already exists")

    liftIO $ debug 3 $ "Creating essay in workspace=" <> show (unWorkspaceRoot workspaceRoot)
      <> " path=" <> show path

    content <- liftIO $ bracketOnError
      (createDirectory path >> pure path)
      removeDirectoryRecursive
        (\createdPath -> do
          TextIO.writeFile (essayPromptPath createdPath) (maybe "" id mPrompt)
          TextIO.writeFile (essayDraftPath createdPath) (maybe "" id mMarkdown)
          loadWorkspaceEssay workspaceRoot segments)

    case content of
      Nothing -> do
        liftIO $ removeDirectoryRecursive path
        throwE (WorkspaceEssayCreationFailed "Unable to load created essay")
      Just essay -> pure essay

  pure $ case result of
    Left failure -> failure
    Right essay -> WorkspaceEssayCreated essay

-- | Update exactly one essay file. Omitted fields are preserved and supplied
-- empty strings clear the file. Invalid updates or targets return False;
-- filesystem errors propagate.
saveWorkspaceEssay
  :: WorkspaceRoot
  -> [Text]    -- ^ essay path
  -> Maybe Text -- ^ new prompt content
  -> Maybe Text -- ^ new markdown content
  -> IO Bool
saveWorkspaceEssay workspaceRoot@(WorkspaceRoot root) essayPath newPrompt newMarkdown = do
  fmap isJust . runMaybeT $ do
    guard (isJust newPrompt /= isJust newMarkdown)
    path <- workspaceEssayPath workspaceRoot essayPath

    let promptFilePath = essayPromptPath path
        essayFilePath = essayDraftPath path
        paths' = scanl (</>) root (map Text.unpack essayPath)
        paths = paths' <> (if isJust newPrompt then [promptFilePath] else []) <> (if isJust newMarkdown then [essayFilePath] else [])

    checked <- liftIO $ checkPathEntries root paths
    _ <- liftIO $ case checked of
      Left (PathSymbolicLink _) -> ioError (userError "Path contains symbolic link")
      Left (PathMissingParent _ err) -> ioError err
      Left (PathIoError _ err) -> ioError err
      Right _ -> pure ()

    liftIO $ debug 3 $ "Saving essay in workspace=" <> show (unWorkspaceRoot workspaceRoot)
      <> " path=" <> show path

    when (isJust newPrompt) $ liftIO $ TextIO.writeFile promptFilePath (maybe "" id newPrompt)
    when (isJust newMarkdown) $ liftIO $ TextIO.writeFile essayFilePath (maybe "" id newMarkdown)

-- | Delete an existing essay directory.
deleteWorkspaceEssay :: WorkspaceRoot -> [Text] -> IO WorkspaceDeleteResult
deleteWorkspaceEssay workspaceRoot essayPath = do
  result <- runExceptT $ do
    path <- requireWorkspaceEssay workspaceRoot essayPath

    hasSymlink <- liftIO $ hasSymlinkInPath path
    unless (not hasSymlink) $ throwE (WorkspacePathSymbolicLink essayPath)

    requireNonEssayParents (WorkspacePathNestedEssay essayPath)
      workspaceRoot (take (length essayPath - 1) essayPath)

    liftIO $ debug 3 $ "Deleting essay in workspace=" <> show (unWorkspaceRoot workspaceRoot)
      <> " path=" <> show path
    liftIO $ removeDirectoryRecursive path

  case result of
    Left failure -> pure (WorkspaceDeleteFailed failure)
    Right _ -> pure WorkspaceDeleteSucceeded

-- | Recursively delete a directory and its contents. Refuse the workspace
-- root, unsafe paths, files, and symbolic-link targets. IO errors propagate.
deleteWorkspaceDirectory :: WorkspaceRoot -> [Text] -> IO WorkspaceDeleteResult
deleteWorkspaceDirectory _ [] = pure $ WorkspaceDeleteFailed WorkspacePathRootDenied
deleteWorkspaceDirectory workspaceRoot dirPath = do
  result <- runExceptT $ do
    path <- resolveWorkspaceNodePath (WorkspacePathInvalidPath dirPath) workspaceRoot dirPath

    exists <- liftIO $ doesPathExist path
    unless exists $ throwE (WorkspacePathTargetNotFound dirPath)

    hasSymlink <- liftIO $ hasSymlinkInPath path
    when hasSymlink $ throwE (WorkspacePathSymbolicLink dirPath)

    requireNonEssayParents (WorkspacePathNestedEssay dirPath)
      workspaceRoot (take (length dirPath - 1) dirPath)

    isEssay <- liftIO $ isEssayDir path
    when isEssay $ throwE (WorkspacePathWrongTargetType dirPath)

    isFile <- liftIO $ doesFileExist path
    when isFile $ throwE (WorkspacePathWrongTargetType dirPath)

    liftIO $ debug 3 $ "Deleting directory recursively in workspace=" <> show (unWorkspaceRoot workspaceRoot)
      <> " path=" <> show path
    liftIO $ removeDirectoryRecursive path

  case result of
    Left failure -> pure (WorkspaceDeleteFailed failure)
    Right _ -> pure WorkspaceDeleteSucceeded
