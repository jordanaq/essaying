{-# LANGUAGE OverloadedStrings #-}

module Essaying.Persistence.Workspace
  ( -- * Result types
    CreateWorkspaceDirectoryResult (..)
  , CreateWorkspaceEssayResult (..)
    -- * Workspace operations
  , listWorkspaceTree
  , loadWorkspaceEssay
  , createWorkspaceDirectory
  , createWorkspaceEssay
  , saveWorkspaceEssay
    -- * Path helpers (internal, exported for testing)
  , safeResolvePath
  , isSafeSegment
  , essayFileName
  , isEssayFile
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Essaying.Types.Storage (WorkspaceRoot (..))
import Essaying.Types.Workspace
  ( WorkspaceEssayContent (..)
  , WorkspaceNode (..)
  , WorkspaceNodeType (..)
  )
import Essaying.Utils (debug_)
import Control.Monad (forM)
import Data.Maybe (catMaybes, fromJust)
import System.Directory (createDirectory, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>), dropExtension)


debug :: Int -> String -> IO ()
debug = debug_ "[Workspace]"


-- | Result of attempting to create a directory in the workspace.
data CreateWorkspaceDirectoryResult
  = WorkspaceDirectoryCreated WorkspaceNode
  | WorkspaceDirectoryAlreadyExists
  | WorkspaceDirectoryCreationFailed Text
  deriving (Eq, Show)

-- | Result of attempting to create an essay in the workspace.
data CreateWorkspaceEssayResult
  = WorkspaceEssayCreated WorkspaceEssayContent
  | WorkspaceEssayAlreadyExists
  | WorkspaceEssayCreationFailed Text
  deriving (Eq, Show)


-- | Extension used for essay files on disk.
essayFileName :: Text -> FilePath
essayFileName essayName = Text.unpack essayName <> ".md"

-- | Build an essay path from its parent and extensionless title.
essayPathSegments :: [Text] -> Text -> [Text]
essayPathSegments parentPath essayTitle = parentPath <> [Text.pack (essayFileName essayTitle)]

-- | Check whether a filename looks like an essay (ends with .md).
isEssayFile :: FilePath -> Bool
isEssayFile =
  (Text.isSuffixOf ".md") . Text.pack

-- | A path segment is safe if it is non-empty, contains no path
-- separators, and is not \"..\" or \".\".
isSafeSegment :: Text -> Bool
isSafeSegment segment =
  not (Text.null segment) &&
  segment /= "." &&
  segment /= ".." &&
  not (Text.any (`elem` ("/\\" :: String)) segment)

-- | Convert a list of path segments into a concrete 'FilePath' beneath
-- the workspace root.  Returns 'Nothing' if any segment is unsafe or
-- the resolved path would escape the workspace root.
safeResolvePath :: WorkspaceRoot -> [Text] -> Maybe FilePath
safeResolvePath workspaceRoot segments =
  if all isSafeSegment segments
    then Just $ foldl (</>) (unWorkspaceRoot workspaceRoot) (map Text.unpack segments)
    else Nothing
  

-- | Recursively walk the workspace directory and produce a tree of
-- 'WorkspaceNode' values.  Directories become 'WorkspaceDirectoryNode';
-- @.md@ files become 'WorkspaceEssayNode'.  Non-@.md@ files (e.g.
-- @context.yaml@) are skipped.
listWorkspaceTree :: WorkspaceRoot -> IO [WorkspaceNode]
listWorkspaceTree workspaceRoot = listWorkspaceTreeAt [] (unWorkspaceRoot workspaceRoot)

listWorkspaceTreeAt :: [Text] -> FilePath -> IO [WorkspaceNode]
listWorkspaceTreeAt parentSegments rootPath = do
  entries <- listDirectory rootPath
  nodes <- forM entries $ \entry -> do
    let fullPath = rootPath </> entry
        entryText = Text.pack entry
    isDir <- doesDirectoryExist fullPath
    if isDir
      then do
        let nodeSegments = parentSegments <> [entryText]
        subNodes <- listWorkspaceTreeAt nodeSegments fullPath
        return $ Just $ WorkspaceNode entryText nodeSegments WorkspaceDirectoryNode subNodes
      else if isEssayFile entry
        then do
          let nodeSegments = parentSegments <> [entryText]
          return $ Just $ WorkspaceNode entryText nodeSegments WorkspaceEssayNode []
        else return Nothing
  return $ catMaybes nodes


loadWorkspaceNode :: WorkspaceRoot -> [Text] -> IO (Maybe WorkspaceNode)
loadWorkspaceNode workspaceRoot segments = do
  let mPath = safeResolvePath workspaceRoot segments
  case mPath of
    Nothing -> return Nothing
    Just path -> do
      isDir <- doesDirectoryExist path
      if isDir
        then do
          children <- listDirectory path
          childNodes <- mapM (\child -> loadWorkspaceNode workspaceRoot (segments <> [childSegment child])) children
          return $ Just $ WorkspaceNode (last segments) segments WorkspaceDirectoryNode (catMaybes childNodes)
        else do
          isEssay <- doesFileExist path
          if isEssay
            then return $ Just $ WorkspaceNode (last segments) segments WorkspaceEssayNode []
            else return Nothing
  where
    childSegment = Text.pack

-- | Load an essay using path segments that include the @.md@ extension
-- (e.g. @[\"History\", \"French-Revolution.md\"]@).
-- Returns 'Nothing' if the file does not exist or the path is unsafe.
loadWorkspaceEssay :: WorkspaceRoot -> [Text] -> IO (Maybe WorkspaceEssayContent)
loadWorkspaceEssay workspaceRoot segments = do
  case null segments || not (isEssayFile (Text.unpack (last segments))) of
    True -> return Nothing
    False -> do
      let essayTitle = Text.pack (dropExtension (Text.unpack (last segments)))
          mPath = safeResolvePath workspaceRoot segments
      case mPath of
        Nothing -> return Nothing
        Just filePath -> do
          exists <- doesFileExist filePath
          if exists
            then do
              essayMarkdown <- TextIO.readFile filePath
              return $ Just $ WorkspaceEssayContent segments essayTitle essayMarkdown
            else return Nothing

-- | Create a new directory under @parentPath@.  If the directory already
-- exists, return 'WorkspaceDirectoryAlreadyExists'.
createWorkspaceDirectory
  :: WorkspaceRoot
  -> [Text]    -- ^ parent path (may be empty for workspace root)
  -> Text      -- ^ new directory name
  -> IO CreateWorkspaceDirectoryResult
createWorkspaceDirectory workspaceRoot parentPath newDirName = do
  let segments = parentPath <> [newDirName]
      pathM = safeResolvePath workspaceRoot segments
  case pathM of
    Nothing -> return $ WorkspaceDirectoryCreationFailed "Invalid path"
    Just path -> do
      exists <- doesDirectoryExist path
      if exists
        then return WorkspaceDirectoryAlreadyExists
        else do
          createDirectory path
          workspaceNode <- loadWorkspaceNode workspaceRoot segments
          return $ WorkspaceDirectoryCreated $ fromJust workspaceNode

-- | Create a new essay file under @parentPath@.  If the essay already
-- exists, return 'WorkspaceEssayAlreadyExists'.  When @markdown@ is
-- 'Nothing', write an empty file (or a minimal stub).
createWorkspaceEssay
  :: WorkspaceRoot
  -> [Text]    -- ^ parent path
  -> Text      -- ^ essay name (without extension)
  -> Maybe Text -- ^ initial markdown content
  -> IO CreateWorkspaceEssayResult
createWorkspaceEssay workspaceRoot parentPath essayName mMarkdown = do
  let segments = essayPathSegments parentPath essayName
      pathM = safeResolvePath workspaceRoot segments
  case pathM of
    Nothing -> return $ WorkspaceEssayCreationFailed "Invalid path"
    Just path -> do
      exists <- doesFileExist path
      if exists
        then return $ WorkspaceEssayAlreadyExists
        else do
          case mMarkdown of
            Nothing -> writeFile path ""
            Just markdown -> writeFile path (Text.unpack markdown)
          content <- loadWorkspaceEssay workspaceRoot segments
          return $ WorkspaceEssayCreated $ fromJust content

-- | Overwrite the content of an existing essay.  Used by the save-draft
-- flow (next-step #4).  Returns 'False' if the essay does not exist.
saveWorkspaceEssay
  :: WorkspaceRoot
  -> [Text]    -- ^ essay path (including the @.md@ extension)
  -> Text      -- ^ new markdown content
  -> IO Bool
saveWorkspaceEssay workspaceRoot essayPath newMarkdown
  | null essayPath || not (isEssayFile (Text.unpack (last essayPath))) = return False
  | otherwise =
      case safeResolvePath workspaceRoot essayPath of
        Just path -> do
          exists <- doesFileExist path
          if exists
            then do
              TextIO.writeFile path newMarkdown
              return True
            else return False
        Nothing -> return False
