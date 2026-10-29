{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module ContextAcceptance (tests) where

import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Essaying.Context (emptyEffectiveContext)
import Essaying.Persistence.Context (loadContextLayer, loadEffectiveContext)
import Essaying.Persistence.Workspace (loadWorkspaceEssay, saveWorkspaceEssay)
import Essaying.Types.Context
  ( ContextLayerError (..), EffectiveContext (..), EffectiveContextError (..)
  , ListOverride (..), RubricCriterion (..), RubricOverride (..), ScalarOverride (..)
  )
import Essaying.Types.Context qualified as Layer (ContextLayer (..))
import Essaying.Types.Storage (WorkspaceRoot (..))
import Essaying.Types.Workspace (WorkspaceEssayContent (WorkspaceEssayContent))
import System.Directory
  ( createDirectory, createDirectoryIfMissing, createDirectoryLink, createFileLink
  , doesDirectoryExist, getTemporaryDirectory, listDirectory, removeFile, removePathForcibly
  )
import System.FilePath ((</>), takeDirectory)
import System.IO (hClose, openTempFile)
import Test.HUnit

-- Every case has a separate temporary workspace; no sample or user data is edited.
withWorkspace :: (FilePath -> WorkspaceRoot -> IO a) -> IO a
withWorkspace action = bracket acquire removePathForcibly $ \root -> action root (WorkspaceRoot root)
  where
    acquire = do
      tmp <- getTemporaryDirectory
      (path, handle) <- openTempFile tmp "essaying-context-acceptance"
      hClose handle
      removeFile path
      createDirectory path
      pure path

writeAt :: FilePath -> FilePath -> String -> IO ()
writeAt root path source = do
  createDirectoryIfMissing True (takeDirectory (root </> path))
  writeFile (root </> path) source

assertContext :: String -> WorkspaceRoot -> FilePath -> EffectiveContext -> IO ()
assertContext label workspace essay expected =
  assertEqual label (Right expected) =<< loadEffectiveContext workspace essay

tests :: Test
tests = TestList
  [ TestLabel "invalid documents fail through file loader" invalidDocuments
  , TestLabel "root-only and empty layers" rootAndEmptyLayers
  , TestLabel "null fields inherit all values" nullInheritance
  , TestLabel "ordered operations across three depths" orderedOperations
  , TestLabel "next resolution sees parent changes" parentChanges
  , TestLabel "filesystem errors are not missing layers" ioFailures
  , TestLabel "additional path and symlink boundaries" pathBoundaries
  , TestLabel "migrated sample hierarchy resolves" sampleHierarchy
  , TestLabel "essay-local context is isolated and reread" essayLocalContext
  , TestLabel "directory essay identity boundaries" directoryIdentity
  ]

invalidDocuments :: Test
invalidDocuments = TestList
  [ TestLabel label $ TestCase $ withWorkspace $ \root workspace -> do
      writeAt root "Root Essay/essay.md" "# Essay"
      writeAt root "context.json" source
      -- A valid child replacement must never hide an invalid ancestor.
      writeAt root "Child/essay.md" "# Child"
      writeAt root "Child/context.json" "{\"tags\":{\"tag\":\"ReplaceList\",\"contents\":[]}}"
      loaded <- loadContextLayer workspace "context.json"
      case loaded of
        Left (ContextLayerJsonError "context.json" _) -> pure ()
        other -> assertFailure ("expected JSON error, got " <> show other)
      resolved <- loadEffectiveContext workspace "Child"
      case resolved of
        Left (EffectiveContextLayerError (ContextLayerJsonError "context.json" _)) -> pure ()
        other -> assertFailure ("expected invalid ancestor error, got " <> show other)
  | (label, source) <-
      [ ("empty file", "")
      , ("whitespace-only file", " \n\t")
      , ("top-level null", "null")
      , ("top-level array", "[]")
      , ("top-level string", "\"context\"")
      , ("top-level number", "42")
      , ("top-level boolean", "true")
      , ("scalar shorthand", "{\"title\":\"Essay\"}")
      , ("list shorthand", "{\"tags\":[\"history\"]}")
      , ("rubric shorthand", "{\"rubric\":{\"clarity\":{\"weight\":1}}}")
      , ("unknown field", "{\"extra\":null}")
      , ("unknown scalar tag", "{\"title\":{\"tag\":\"Set\",\"contents\":\"Essay\"}}")
      , ("unknown list tag", "{\"tags\":{\"tag\":\"ClearList\",\"contents\":[]}}")
      , ("unknown rubric tag", "{\"rubric\":{\"tag\":\"ClearRubric\",\"contents\":{}}}")
      , ("unknown criterion field", "{\"rubric\":{\"tag\":\"MergeRubric\",\"contents\":{\"clarity\":{\"weight\":1,\"extra\":true}}}}")
      , ("wrong list item type", "{\"tags\":{\"tag\":\"AppendList\",\"contents\":[1]}}")
      , ("duplicate criterion", "{\"rubric\":{\"tag\":\"MergeRubric\",\"contents\":{\"clarity\":{\"weight\":1},\"clarity\":{\"weight\":2}}}}")
      , ("trailing document", "{} {}")
      , ("trailing garbage", "{} garbage")
      , ("non-JSON trailing whitespace", "{}\v")
      ]
  ]

rootAndEmptyLayers :: Test
rootAndEmptyLayers = TestCase $ withWorkspace $ \root workspace -> do
  writeAt root "Root Essay/essay.md" "# Root essay"
  assertContext "absent root layer uses defaults" workspace "Root Essay" emptyEffectiveContext
  writeAt root "context.json" "{} \n\t\r"
  assertContext "empty root object uses defaults" workspace "Root Essay" emptyEffectiveContext
  writeAt root "context.json" "{\"title\":{\"tag\":\"SetScalar\",\"contents\":\" Root title \"}}"
  let expected = emptyEffectiveContext {title = Just " Root title "}
  assertContext "root-only essay retains supplied whitespace" workspace "Root Essay" expected
  writeAt root "Parent/Child/essay.md" "# Essay in nested organizational folders"
  writeAt root "Parent/Child/context.json" "{}"
  -- A broken sibling configuration must not contribute.
  writeAt root "Sibling/context.json" "{invalid"
  assertContext "missing intermediate and empty child layers inherit" workspace "Parent/Child" expected

essayLocalContext :: Test
essayLocalContext = TestCase $ withWorkspace $ \root workspace -> do
  writeAt root "Subject/First/essay.md" ""
  writeAt root "Subject/First/prompt.md" "Assignment text is not context JSON."
  writeAt root "Subject/Second/essay.md" "# Another draft"
  writeAt root "Subject/context.json"
    "{\"audience\":{\"tag\":\"SetScalar\",\"contents\":\"shared\"}}"
  writeAt root "Subject/First/context.json"
    "{\"audience\":{\"tag\":\"SetScalar\",\"contents\":\"first only\"}}"
  assertContext "own context is the innermost layer" workspace "Subject/First"
    (emptyEffectiveContext {audience = Just "first only"})
  assertContext "sibling essay does not inherit another essay's layer" workspace "Subject/Second"
    (emptyEffectiveContext {audience = Just "shared"})
  writeAt root "Subject/First/context.json"
    "{\"audience\":{\"tag\":\"SetScalar\",\"contents\":\"updated\"}}"
  assertContext "next request sees own context changes" workspace "Subject/First"
    (emptyEffectiveContext {audience = Just "updated"})
  removeFile (root </> "Subject/First/context.json")
  assertContext "deleting own layer restores inheritance" workspace "Subject/First"
    (emptyEffectiveContext {audience = Just "shared"})
  writeAt root "Subject/First/context.json" "{invalid"
  invalid <- loadEffectiveContext workspace "Subject/First"
  case invalid of
    Left (EffectiveContextLayerError (ContextLayerJsonError "Subject/First/context.json" _)) -> pure ()
    other -> assertFailure ("expected essay-local JSON error, got " <> show other)
  assertEqual "broken own context does not prevent saving" True
    =<< saveWorkspaceEssay workspace ["Subject", "First"] "Updated draft"
  assertEqual "broken own context does not prevent loading"
    (Just (WorkspaceEssayContent ["Subject", "First"] "First" "Updated draft"))
    =<< loadWorkspaceEssay workspace ["Subject", "First"]

directoryIdentity :: Test
directoryIdentity = TestList
  [ TestLabel "prompt and context alone are not an essay" $ TestCase $
      withWorkspace $ \root workspace -> do
        writeAt root "Assignment/prompt.md" "Prompt"
        writeAt root "Assignment/context.json" "{}"
        assertEqual "essay.md is required"
          (Left (EffectiveContextEssayNotFound "Assignment"))
          =<< loadEffectiveContext workspace "Assignment"
  , TestLabel "draft marker must be a file" $ TestCase $
      withWorkspace $ \root workspace -> do
        createDirectoryIfMissing True (root </> "Assignment/essay.md")
        assertEqual "directory named essay.md is not a draft"
          (Left (EffectiveContextEssayNotFound "Assignment"))
          =<< loadEffectiveContext workspace "Assignment"
  , TestLabel "loose Markdown is not an essay identity" $ TestCase $
      withWorkspace $ \root workspace -> do
        writeAt root "legacy.md" "# Legacy essay"
        assertEqual "standalone file is not an essay directory"
          (Left (EffectiveContextEssayNotFound "legacy.md"))
          =<< loadEffectiveContext workspace "legacy.md"
  , TestLabel "essay directory names may contain extensions" $ TestCase $
      withWorkspace $ \root workspace -> do
        writeAt root "My Essay.md/essay.md" ""
        assertContext "identity is determined by marker, not name suffix"
          workspace "My Essay.md" emptyEffectiveContext
  , TestLabel "nested essays are rejected" $ TestCase $
      withWorkspace $ \root workspace -> do
        writeAt root "Outer/essay.md" "# Outer"
        writeAt root "Outer/References/Inner/essay.md" "# Inner"
        assertEqual "earlier essay ancestor is rejected"
          (Left (EffectiveContextInvalidPath "Outer/References/Inner"))
          =<< loadEffectiveContext workspace "Outer/References/Inner"
  , TestLabel "essay directory links are rejected" $ TestCase $
      withWorkspace $ \root workspace -> do
        writeAt root "Original/essay.md" "# Original"
        createDirectoryLink (root </> "Original") (root </> "Alias")
        assertEqual "directory identity cannot be a link"
          (Left (EffectiveContextSymbolicLink "Alias"))
          =<< loadEffectiveContext workspace "Alias"
  ]

nullInheritance :: Test
nullInheritance = TestCase $ withWorkspace $ \root workspace -> do
  let expected = EffectiveContext
        { title = Just "Essay", audience = Just "student", model = Just "text-model"
        , tags = ["history"], instructions = ["Use sources."]
        , grading_directions = ["Check sources."]
        , rubric = Map.singleton "evidence" (RubricCriterion 2 (Just "Cites sources."))
        }
  writeAt root "Child/essay.md" "# Essay"
  writeAt root "context.json"
    "{\"title\":{\"tag\":\"SetScalar\",\"contents\":\"Essay\"},\"audience\":{\"tag\":\"SetScalar\",\"contents\":\"student\"},\"model\":{\"tag\":\"SetScalar\",\"contents\":\"text-model\"},\"tags\":{\"tag\":\"AppendList\",\"contents\":[\"history\"]},\"instructions\":{\"tag\":\"AppendList\",\"contents\":[\"Use sources.\"]},\"grading_directions\":{\"tag\":\"AppendList\",\"contents\":[\"Check sources.\"]},\"rubric\":{\"tag\":\"MergeRubric\",\"contents\":{\"evidence\":{\"weight\":2,\"description\":\"Cites sources.\"}}}}"
  writeAt root "Child/context.json"
    "{\"title\":null,\"audience\":null,\"model\":null,\"tags\":null,\"instructions\":null,\"grading_directions\":null,\"rubric\":null}"
  assertContext "all null fields inherit" workspace "Child" expected

orderedOperations :: Test
orderedOperations = TestCase $ withWorkspace $ \root workspace -> do
  let layer = Layer.ContextLayer Nothing Nothing Nothing Nothing Nothing Nothing Nothing
      rootLayer = layer
        { Layer.title = Just (SetScalar "Root"), Layer.audience = Just (SetScalar "student")
        , Layer.model = Just (SetScalar "text-model")
        , Layer.tags = Just (AppendList ["writing", "History", "writing"])
        , Layer.instructions = Just (AppendList ["Repeat.", "Root."])
        , Layer.grading_directions = Just (AppendList ["Old direction."])
        , Layer.rubric = Just (MergeRubric (Map.fromList
            [("clarity", RubricCriterion 1 (Just "Root description.")), ("evidence", RubricCriterion 2 Nothing)]))
        }
      parentLayer = layer
        { Layer.title = Just ClearScalar, Layer.model = Just ClearScalar
        , Layer.tags = Just (AppendList ["history", "History"])
        , Layer.instructions = Just (ReplaceList ["Repeat."])
        , Layer.grading_directions = Just (ReplaceList [])
        , Layer.rubric = Just (MergeRubric (Map.singleton "clarity" (RubricCriterion 3 Nothing)))
        }
      childLayer = layer
        { Layer.title = Just (SetScalar "Child")
        , Layer.tags = Just (AppendList ["writing", "causes"])
        , Layer.instructions = Just (AppendList ["Repeat.", "Child."])
        , Layer.grading_directions = Just (AppendList ["New direction.", "New direction."])
        }
      parentExpected = emptyEffectiveContext
        { audience = Just "student", tags = ["writing", "History", "history"]
        , instructions = ["Repeat."]
        , rubric = Map.fromList [("clarity", RubricCriterion 3 Nothing), ("evidence", RubricCriterion 2 Nothing)]
        }
      childExpected = parentExpected
        { title = Just "Child", tags = ["writing", "History", "history", "causes"]
        , instructions = ["Repeat.", "Repeat.", "Child."]
        , grading_directions = ["New direction.", "New direction."]
        }
  writeAt root "Parent/Example/essay.md" "# Example"
  writeAt root "Parent/Child/essay.md" "# Child"
  forM_ [("context.json", rootLayer), ("Parent/context.json", parentLayer), ("Parent/Child/context.json", childLayer)] $ \(path, value) -> do
    BL.writeFile (root </> path) (encode value)
    assertEqual "operations round-trip through strict loader" (Right (Just value)) =<< loadContextLayer workspace path
  assertContext "parent clears scalars and directions, replaces instructions, merges entire criterion" workspace "Parent/Example" parentExpected
  assertContext "child appends after replacement and retains instruction/direction duplicates" workspace "Parent/Child" childExpected
  let replacement = childLayer
        { Layer.tags = Just (ReplaceList ["new", "new"])
        , Layer.rubric = Just (ReplaceRubric (Map.singleton "new" (RubricCriterion 0 Nothing)))
        }
  BL.writeFile (root </> "Parent/Child/context.json") (encode replacement)
  assertContext "whole rubric and tag replacements discard inherited entries" workspace "Parent/Child"
    (childExpected {tags = ["new"], rubric = Map.singleton "new" (RubricCriterion 0 Nothing)})
  BL.writeFile (root </> "Parent/Child/context.json") (encode (layer
    { Layer.tags = Just (ReplaceList []), Layer.instructions = Just (ReplaceList [])
    , Layer.rubric = Just (ReplaceRubric Map.empty) }))
  assertContext "empty replacements clear collections independently" workspace "Parent/Child"
    (parentExpected {tags = [], instructions = [], rubric = Map.empty})

parentChanges :: Test
parentChanges = TestCase $ withWorkspace $ \root workspace -> do
  writeAt root "Parent/Child/essay.md" "# Essay"
  let path = "Parent/context.json"
  writeAt root path "{\"audience\":{\"tag\":\"SetScalar\",\"contents\":\"first\"}}"
  first <- loadEffectiveContext workspace "Parent/Child"
  assertEqual "initial parent" (Right (emptyEffectiveContext {audience = Just "first"})) first
  writeAt root path "{\"audience\":{\"tag\":\"SetScalar\",\"contents\":\"second\"}}"
  assertContext "next request reads updated parent" workspace "Parent/Child"
    (emptyEffectiveContext {audience = Just "second"})
  assertEqual "previous value remains a snapshot" (Right (emptyEffectiveContext {audience = Just "first"})) first
  removeFile (root </> path)
  assertContext "next request sees removed layer" workspace "Parent/Child" emptyEffectiveContext
  assertEqual "resolution writes no root artifact" ["Parent"] =<< listDirectory root
  assertEqual "resolution writes no parent artifact" ["Child"] =<< listDirectory (root </> "Parent")
  assertEqual "resolution writes no essay-side artifact" ["essay.md"] =<< listDirectory (root </> "Parent/Child")

ioFailures :: Test
ioFailures = TestCase $ withWorkspace $ \root workspace -> do
  writeAt root "Root Essay/essay.md" "# Essay"
  -- Reading a directory as a file fails deterministically, even as root.
  createDirectory (root </> "context.json")
  loaded <- loadContextLayer workspace "context.json"
  case loaded of
    Left (ContextLayerIoError "context.json" _) -> pure ()
    other -> assertFailure ("expected file I/O failure, got " <> show other)
  resolved <- loadEffectiveContext workspace "Root Essay"
  case resolved of
    Left (EffectiveContextLayerError (ContextLayerIoError "context.json" _)) -> pure ()
    other -> assertFailure ("expected ancestor I/O failure, got " <> show other)
  -- Broken context must leave ordinary essay editing and persistence usable.
  assertEqual "save succeeds with invalid context" True
    =<< saveWorkspaceEssay workspace ["Root Essay"] "# Updated"
  assertEqual "load succeeds with invalid context" (Just (WorkspaceEssayContent ["Root Essay"] "Root Essay" "# Updated"))
    =<< loadWorkspaceEssay workspace ["Root Essay"]

pathBoundaries :: Test
pathBoundaries = TestCase $ withWorkspace $ \root workspace -> do
  forM_ ["", "/Essay", "./Essay", "Parent/../Essay", "Parent//Essay", "Parent\\Essay"] $ \path ->
    assertEqual "unsafe essay path rejected" (Left (EffectiveContextInvalidPath path))
      =<< loadEffectiveContext workspace path
  forM_ ["", "/context.json", "./context.json", "Parent/../context.json", "Parent//context.json", "other.json"] $ \path ->
    assertEqual "unsafe layer path rejected" (Left (ContextLayerInvalidPath path))
      =<< loadContextLayer workspace path
  assertEqual "missing context parent is not a missing layer" (Left (ContextLayerInvalidPath "Missing"))
    =<< loadContextLayer workspace "Missing/context.json"
  writeAt root "Root Essay/essay.md" "# Essay"
  createFileLink (root </> "absent.json") (root </> "context.json")
  assertEqual "dangling context link is rejected" (Left (EffectiveContextLayerError (ContextLayerSymbolicLink "context.json")))
    =<< loadEffectiveContext workspace "Root Essay"
  removeFile (root </> "context.json")
  createDirectoryLink root (root </> "Linked")
  assertEqual "linked workspace root is rejected" (Left (EffectiveContextSymbolicLink "."))
    =<< loadEffectiveContext (WorkspaceRoot (root </> "Linked")) "Root Essay"
  assertEqual "linked context ancestor is rejected" (Left (ContextLayerSymbolicLink "Linked"))
    =<< loadContextLayer workspace "Linked/context.json"

sampleHierarchy :: Test
sampleHierarchy = TestCase $ withWorkspace $ \root workspace -> do
  inMonorepo <- doesDirectoryExist "backend/data/sample"
  let sampleRoot = if inMonorepo then "backend/data/sample" else "data/sample"
      paths = ["context.json", "History/context.json", "History/French-Revolution/context.json"]
  forM_ paths $ \path -> do
    source <- readFile (sampleRoot </> path)
    writeAt root path source
  writeAt root "History/French-Revolution/Causes/essay.md" "# Causes"
  assertContext "migrated fixtures retain original inherited values" workspace "History/French-Revolution/Causes"
    (EffectiveContext
      { title = Just "History Essays", audience = Just "advanced-high-school", model = Just "llama3.1:8b"
      , tags = []
      , instructions = ["Keep writing concise and clear.", "Use markdown headings when useful."
          , "Prioritize historical context and chronology.", "Compare short-term and long-term causes."
          , "Distinguish social, political, and economic factors."]
      , grading_directions = []
      , rubric = Map.fromList
          [ ("clarity", RubricCriterion 0.4 (Just "Writing is coherent and easy to follow."))
          , ("evidence", RubricCriterion 0.6 (Just "Claims are supported by references or examples."))
          , ("historical_accuracy", RubricCriterion 0.5 (Just "Facts and sequence of events are correct."))
          , ("argumentation", RubricCriterion 0.5 (Just "Builds a defensible thesis and supports it."))
          ]
      })
