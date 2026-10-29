{-# LANGUAGE OverloadedStrings #-}

module WorkspaceDiscovery (tests) where

import Control.Exception (IOException, bracket, try)
import Essaying.Persistence.Utils (PathCheckError (..), checkPathEntries)
import Essaying.Persistence.Workspace
  ( deleteWorkspaceDirectory, deleteWorkspaceEssay, isEssayDir, listWorkspaceTree, loadWorkspaceNode
  , loadWorkspaceEssay, saveWorkspaceEssay )
import Essaying.Types.Storage (WorkspaceRoot (..))
import Essaying.Types.Workspace
  ( WorkspaceDeleteError (..), WorkspaceDeleteResult (..), WorkspaceEssayContent (..)
  , WorkspaceNode (..), WorkspaceNodeType (..) )
import System.Directory
  ( createDirectory, createDirectoryLink, createFileLink, getTemporaryDirectory
  , pathIsSymbolicLink, removeFile, removePathForcibly
  )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.HUnit (Test (..), assertEqual, assertFailure)

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
  [ TestLabel "shared path check distinguishes missing target and parent" $ TestCase $
      withWorkspace $ \root _ -> do
        present <- checkPathEntries root [root]
        case present of
          Right True -> pure ()
          other -> assertFailure ("expected existing path: " <> show other)
        absent <- checkPathEntries root [root, root </> "Missing"]
        case absent of
          Right False -> pure ()
          other -> assertFailure ("expected missing target: " <> show other)
        missingParent <- checkPathEntries root
          [root, root </> "Missing", root </> "Missing" </> "Child"]
        case missingParent of
          Left (PathMissingParent "Missing" _) -> pure ()
          other -> assertFailure ("expected relative missing parent: " <> show other)
  , TestLabel "shared path check stops at dangling links" $ TestCase $
      withWorkspace $ \root _ -> do
        createDirectoryLink (root </> "Absent") (root </> "Linked")
        checked <- checkPathEntries root
          [root, root </> "Linked", root </> "Linked" </> "Child"]
        case checked of
          Left (PathSymbolicLink "Linked") -> pure ()
          other -> assertFailure ("expected link before missing child: " <> show other)
  , TestLabel "empty draft identifies an essay leaf" $ TestCase $
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
  , TestLabel "prompt loading preservation update and explicit clearing" $ TestCase $
      withWorkspace $ \root workspace -> do
        createDirectory (root </> "Essay")
        writeFile (root </> "Essay" </> "essay.md") "Draft"
        assertEqual "absent prompt loads as empty"
          (Just (WorkspaceEssayContent ["Essay"] "Essay" "" "Draft"))
          =<< loadWorkspaceEssay workspace ["Essay"]
        assertEqual "empty update is rejected" False
          =<< saveWorkspaceEssay workspace ["Essay"] Nothing Nothing
        assertEqual "two-file update is rejected" False
          =<< saveWorkspaceEssay workspace ["Essay"] (Just "Do not write") (Just "Do not write")
        assertEqual "rejected updates leave the draft intact"
          (Just (WorkspaceEssayContent ["Essay"] "Essay" "" "Draft"))
          =<< loadWorkspaceEssay workspace ["Essay"]
        assertEqual "prompt can be saved" True
          =<< saveWorkspaceEssay workspace ["Essay"] (Just "Assignment") Nothing
        assertEqual "prompt survives reload in the correct field"
          (Just (WorkspaceEssayContent ["Essay"] "Essay" "Assignment" "Draft"))
          =<< loadWorkspaceEssay workspace ["Essay"]
        assertEqual "omitting prompt preserves it" True
          =<< saveWorkspaceEssay workspace ["Essay"] Nothing (Just "Updated")
        assertEqual "draft and prompt remain distinct"
          (Just (WorkspaceEssayContent ["Essay"] "Essay" "Assignment" "Updated"))
          =<< loadWorkspaceEssay workspace ["Essay"]
        assertEqual "explicit empty prompt clears it" True
          =<< saveWorkspaceEssay workspace ["Essay"] (Just "") Nothing
        assertEqual "empty prompt survives reload"
          (Just (WorkspaceEssayContent ["Essay"] "Essay" "" "Updated"))
          =<< loadWorkspaceEssay workspace ["Essay"]
  , TestLabel "saving a prompt rejects a link and preserves its target" $ TestCase $
      withWorkspace $ \root workspace -> withWorkspace $ \outside _ -> do
        createDirectory (root </> "Essay")
        writeFile (root </> "Essay/essay.md") "Keep draft"
        writeFile (outside </> "assignment.md") "Keep external prompt"
        createFileLink (outside </> "assignment.md") (root </> "Essay/prompt.md")
        assertIOException $ saveWorkspaceEssay workspace ["Essay"] (Just "Do not write") Nothing
        assertEqual "linked prompt target is unchanged" "Keep external prompt"
          =<< readFile (outside </> "assignment.md")
        assertEqual "draft is unchanged after rejected prompt save" "Keep draft"
          =<< readFile (root </> "Essay/essay.md")
        assertEqual "prompt link is preserved" True
          =<< pathIsSymbolicLink (root </> "Essay/prompt.md")
  , TestLabel "draft saving ignores an invalid linked prompt" $ TestCase $
      withWorkspace $ \root workspace -> withWorkspace $ \outside _ -> do
        createDirectory (root </> "Essay")
        writeFile (root </> "Essay/essay.md") "Original draft"
        writeFile (outside </> "assignment.md") "Keep external prompt"
        createFileLink (outside </> "assignment.md") (root </> "Essay/prompt.md")
        assertEqual "draft save does not require a valid prompt" True
          =<< saveWorkspaceEssay workspace ["Essay"] Nothing (Just "Updated draft")
        assertEqual "draft was saved" "Updated draft"
          =<< readFile (root </> "Essay/essay.md")
        assertEqual "prompt target is unchanged" "Keep external prompt"
          =<< readFile (outside </> "assignment.md")
        assertEqual "prompt link is unchanged" True
          =<< pathIsSymbolicLink (root </> "Essay/prompt.md")
  , TestLabel "a prompt directory blocks prompt writes but not draft writes" $ TestCase $
      withWorkspace $ \root workspace -> do
        createDirectory (root </> "Essay")
        writeFile (root </> "Essay/essay.md") "Original draft"
        createDirectory (root </> "Essay/prompt.md")
        writeFile (root </> "Essay/prompt.md/reference.txt") "Keep reference"
        assertIOException $ saveWorkspaceEssay workspace ["Essay"] (Just "Do not write") Nothing
        assertEqual "failed prompt write leaves draft intact" "Original draft"
          =<< readFile (root </> "Essay/essay.md")
        assertEqual "draft save ignores prompt directory" True
          =<< saveWorkspaceEssay workspace ["Essay"] Nothing (Just "Updated draft")
        assertEqual "draft was saved" "Updated draft"
          =<< readFile (root </> "Essay/essay.md")
        assertEqual "prompt directory contents are preserved" "Keep reference"
          =<< readFile (root </> "Essay/prompt.md/reference.txt")
  , TestLabel "linked ancestors prevent both prompt and draft writes" $ TestCase $
      withWorkspace $ \root workspace -> withWorkspace $ \outside _ -> do
        createDirectory (outside </> "Essay")
        writeFile (outside </> "Essay/essay.md") "Keep external draft"
        writeFile (outside </> "Essay/prompt.md") "Keep external prompt"
        createDirectoryLink outside (root </> "Linked")
        assertIOException $
          saveWorkspaceEssay workspace ["Linked", "Essay"] (Just "Do not write") Nothing
        assertIOException $
          saveWorkspaceEssay workspace ["Linked", "Essay"] Nothing (Just "Do not write")
        assertEqual "ancestor link target draft is unchanged" "Keep external draft"
          =<< readFile (outside </> "Essay/essay.md")
        assertEqual "ancestor link target prompt is unchanged" "Keep external prompt"
          =<< readFile (outside </> "Essay/prompt.md")
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

-- Filesystem validation failures currently propagate as IOException.
assertIOException :: IO a -> IO ()
assertIOException action = do
  result <- try (action >> pure ()) :: IO (Either IOException ())
  case result of
    Left _ -> pure ()
    Right () -> assertFailure "expected save to reject the filesystem target"
