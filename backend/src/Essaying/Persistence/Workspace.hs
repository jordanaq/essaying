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
import Essaying.Types.Storage (WorkspaceRoot (..))
import Essaying.Types.Workspace
  ( WorkspaceEssayContent (..)
  , WorkspaceNode (..)
  , WorkspaceNodeType (..)
  )
import Essaying.Utils (debug_)
import System.FilePath ((</>))


debug :: Int -> String -> IO ()
debug = debug_ "[Workspace]"


-- | Result of attempting to create a directory in the workspace.
data CreateWorkspaceDirectoryResult
  = WorkspaceDirectoryCreated WorkspaceNode
  | WorkspaceDirectoryAlreadyExists
  deriving (Eq, Show)

-- | Result of attempting to create an essay in the workspace.
data CreateWorkspaceEssayResult
  = WorkspaceEssayCreated WorkspaceEssayContent
  | WorkspaceEssayAlreadyExists
  deriving (Eq, Show)


-- | Extension used for essay files on disk.
essayFileName :: Text -> FilePath
essayFileName essayName = Text.unpack essayName <> ".md"

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
listWorkspaceTree workspaceRoot = do
  let rootPath = unWorkspaceRoot workspaceRoot
  entries <- listDirectory rootPath
  nodes <- forM entries $ \entry -> do
    let fullPath = rootPath </> entry
    isDir <- doesDirectoryExist fullPath
    if isDir
      then do
        subNodes <- listWorkspaceTree (WorkspaceRoot fullPath)
        return $ WorkspaceDirectoryNode entry subNodes
      else if isEssayFile entry
        then return $ WorkspaceEssayNode entry
        else return Nothing
  return $ catMaybes nodes

-- | Load a single essay's content.  The path segments should NOT include
-- the @.md@ extension (e.g. @[\"History\", \"French-Revolution\"]@).
-- Returns 'Nothing' if the file does not exist or the path is unsafe.
loadWorkspaceEssay :: WorkspaceRoot -> [Text] -> IO (Maybe WorkspaceEssayContent)
loadWorkspaceEssay = error "TODO: implement — safeResolvePath, readFile, build WorkspaceEssayContent"

-- | Create a new directory under @parentPath@.  If the directory already
-- exists, return 'WorkspaceDirectoryAlreadyExists'.
createWorkspaceDirectory
  :: WorkspaceRoot
  -> [Text]    -- ^ parent path (may be empty for workspace root)
  -> Text      -- ^ new directory name
  -> IO CreateWorkspaceDirectoryResult
createWorkspaceDirectory = error "TODO: implement — validate, createDirectory, build WorkspaceNode"

-- | Create a new essay file under @parentPath@.  If the essay already
-- exists, return 'WorkspaceEssayAlreadyExists'.  When @markdown@ is
-- 'Nothing', write an empty file (or a minimal stub).
createWorkspaceEssay
  :: WorkspaceRoot
  -> [Text]    -- ^ parent path
  -> Text      -- ^ essay name (without extension)
  -> Maybe Text -- ^ initial markdown content
  -> IO CreateWorkspaceEssayResult
createWorkspaceEssay = error "TODO: implement — validate, writeFile, build WorkspaceEssayContent"

-- | Overwrite the content of an existing essay.  Used by the save-draft
-- flow (next-step #4).  Returns 'False' if the essay does not exist.
saveWorkspaceEssay
  :: WorkspaceRoot
  -> [Text]    -- ^ essay path (without extension)
  -> Text      -- ^ new markdown content
  -> IO Bool
saveWorkspaceEssay = error "TODO: implement — check exists, writeFile, return True/False"
