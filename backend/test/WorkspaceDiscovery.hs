{-# LANGUAGE OverloadedStrings #-}

module WorkspaceDiscovery (tests) where

import Control.Exception (bracket)
import Essaying.Persistence.Workspace
  ( deleteWorkspaceDirectory, deleteWorkspaceEssay, isEssayDir, listWorkspaceTree, loadWorkspaceNode )
import Essaying.Types.Storage (WorkspaceRoot (..))
import Essaying.Types.Workspace
  ( WorkspaceDeleteError (..), WorkspaceDeleteResult (..), WorkspaceNode (..), WorkspaceNodeType (..) )
import System.Directory
  ( createDirectory, createDirectoryLink, createFileLink, getTemporaryDirectory
  , removeFile, removePathForcibly
  )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.HUnit (Test (..), assertEqual)

withWorkspace :: (FilePath -> WorkspaceRoot -> IO a) -> IO a
withWorkspace action = bracket acquire removePathForcibly $ \root ->
  action root (WorkspaceRoot root)
  where
    acquire = do
      tmp <- getTemporaryDirectory
      (path, handle) <- openTempFile tmp "essaying-discovery"
      hClose handle
      removeFile path
      createDirectory path
      pure path

tests :: Test
tests = TestLabel "essay directory discovery" $ TestList
  [ TestLabel "empty draft identifies an essay leaf" $ TestCase $
      withWorkspace $ \root workspace -> do
        let essay = root </> "My Essay"
        createDirectory essay
        writeFile (essay </> "essay.md") ""
        writeFile (essay </> "prompt.md") "Assignment"
        writeFile (essay </> "context.json") "{invalid"
        createDirectory (essay </> "References")
        assertEqual "marker does not require nonempty draft or valid context" True
          =<< isEssayDir essay
        let expected = WorkspaceNode "My Essay" ["My Essay"] WorkspaceEssayNode []
        assertEqual "essay files and directories stay internal" (Just expected)
          =<< loadWorkspaceNode workspace ["My Essay"]
        assertEqual "tree uses directory identity" [expected]
          =<< listWorkspaceTree workspace
  , TestLabel "skipped children do not discard their parent" $ TestCase $
      withWorkspace $ \root workspace -> do
        let folder = root </> "History"
            essay = folder </> "Causes"
        createDirectory folder
        createDirectory essay
        writeFile (essay </> "essay.md") "Draft"
        writeFile (folder </> "legacy.md") "Legacy draft"
        writeFile (folder </> "context.json") "{}"
        createDirectoryLink root (folder </> "Loop")
        let expected = WorkspaceNode "History" ["History"] WorkspaceDirectoryNode
              [WorkspaceNode "Causes" ["History", "Causes"] WorkspaceEssayNode []]
        assertEqual "files and linked directories are skipped independently"
          (Just expected) =<< loadWorkspaceNode workspace ["History"]
        assertEqual "both discovery entry points agree" [expected]
          =<< listWorkspaceTree workspace
  , TestLabel "empty unsafe missing and file paths are rejected" $ TestCase $
      withWorkspace $ \root workspace -> do
        writeFile (root </> "notes.md") "Notes"
        mapM_ (\segments -> assertEqual (show segments) Nothing
          =<< loadWorkspaceNode workspace segments)
          [[], [".."], ["Missing"], ["Missing", "Child"], ["notes.md"]]
  , TestLabel "ordinary folder needs no marker" $ TestCase $
      withWorkspace $ \root workspace -> do
        createDirectory (root </> "Notes")
        assertEqual "missing marker is not an error" False
          =<< isEssayDir (root </> "Notes")
        assertEqual "missing directory is not an error" False
          =<< isEssayDir (root </> "Missing")
        assertEqual "empty folder is retained"
          (Just (WorkspaceNode "Notes" ["Notes"] WorkspaceDirectoryNode []))
          =<< loadWorkspaceNode workspace ["Notes"]
  , TestLabel "symlinked directories and markers are not essays" $ TestCase $
      withWorkspace $ \root workspace -> do
        createDirectory (root </> "Original")
        writeFile (root </> "Original" </> "essay.md") "Draft"
        createDirectoryLink (root </> "Original") (root </> "Alias")
        createDirectoryLink (root </> "Absent") (root </> "Dangling")
        mapM_ (\name -> assertEqual "linked directory is skipped" Nothing
          =<< loadWorkspaceNode workspace [name]) ["Alias", "Dangling"]
        createDirectory (root </> "LinkedMarker")
        createFileLink (root </> "Original" </> "essay.md")
          (root </> "LinkedMarker" </> "essay.md")
        assertEqual "linked marker cannot identify an essay" False
          =<< isEssayDir (root </> "LinkedMarker")
        assertEqual "directory with linked marker remains an ordinary folder"
          (Just (WorkspaceNode "LinkedMarker" ["LinkedMarker"] WorkspaceDirectoryNode []))
          =<< loadWorkspaceNode workspace ["LinkedMarker"]
  , TestLabel "folder deletion rejects descendants of essays" $ TestCase $
      withWorkspace $ \root workspace -> do
        createDirectory (root </> "Essay")
        writeFile (root </> "Essay" </> "essay.md") "Keep draft"
        createDirectory (root </> "Essay" </> "References")
        createDirectory (root </> "Essay" </> "References" </> "Notes")
        writeFile (root </> "Essay" </> "References" </> "Notes" </> "source.md") "Keep source"
        let target = ["Essay", "References", "Notes"]
        assertEqual "an earlier essay ancestor blocks folder deletion"
          (WorkspaceDeleteFailed (WorkspaceDeleteWrongTargetType target))
          =<< deleteWorkspaceDirectory workspace target
        assertEqual "reference contents survive" "Keep source"
          =<< readFile (root </> "Essay" </> "References" </> "Notes" </> "source.md")
  , TestLabel "essay deletion rejects nested essay targets" $ TestCase $
      withWorkspace $ \root workspace -> do
        createDirectory (root </> "Essay")
        writeFile (root </> "Essay" </> "essay.md") "Keep outer"
        createDirectory (root </> "Essay" </> "Nested")
        writeFile (root </> "Essay" </> "Nested" </> "essay.md") "Keep inner"
        let target = ["Essay", "Nested"]
        assertEqual "an essay cannot be deleted from inside another essay"
          (WorkspaceDeleteFailed (WorkspaceDeleteWrongTargetType target))
          =<< deleteWorkspaceEssay workspace target
        assertEqual "nested draft survives" "Keep inner"
          =<< readFile (root </> "Essay" </> "Nested" </> "essay.md")
  , TestLabel "ordinary essay and folder deletion remain available" $ TestCase $
      withWorkspace $ \root workspace -> do
        createDirectory (root </> "History")
        createDirectory (root </> "History" </> "Essay")
        writeFile (root </> "History" </> "Essay" </> "essay.md") "Draft"
        assertEqual "target essay does not count as its own ancestor"
          WorkspaceDeleteSucceeded =<< deleteWorkspaceEssay workspace ["History", "Essay"]
        assertEqual "ordinary folder can still be deleted"
          WorkspaceDeleteSucceeded =<< deleteWorkspaceDirectory workspace ["History"]
  ]
