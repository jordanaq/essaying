{-# LANGUAGE OverloadedStrings #-}

module ContextHandlers (tests) where

import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson (decode, encode, object, (.=))
import Essaying.Handler.Context
import Essaying.Persistence.Context (loadContextLayer)
import Essaying.Context (emptyEffectiveContext)
import Essaying.Types.Context
  ( ContextLayer (..), EffectiveContext, ScalarOverride (..), CreateContextRequest (..)
  , UpdateContextRequest (..), DeleteContextRequest (..)
  )
import Essaying.Types.Storage (WorkspaceRoot (..))
import Servant (Handler, ServerError (..), runHandler)
import System.Directory
  ( createDirectory, createDirectoryLink, createFileLink, getTemporaryDirectory
  , removeFile, removePathForcibly
  )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.HUnit

withWorkspace :: (FilePath -> WorkspaceRoot -> IO a) -> IO a
withWorkspace action = bracket acquire removePathForcibly $ \root -> action root (WorkspaceRoot root)
  where
    acquire = do
      tmp <- getTemporaryDirectory
      (path, handle) <- openTempFile tmp "essaying-context-handlers"
      hClose handle
      removeFile path
      createDirectory path
      pure path

layer :: ContextLayer
layer = case decode "{}" of
  Just value -> value
  Nothing -> error "empty context fixture must decode"

assertStatus :: Int -> Handler a -> IO ()
assertStatus expected action = do
  result <- runHandler action
  case result of
    Left err -> do
      assertEqual "HTTP status" expected (errHTTPCode err)
      assertEqual "JSON content type" (Just "application/json") (lookup "Content-Type" (errHeaders err))
    Right _ -> assertFailure ("expected HTTP error " <> show expected)

tests :: Test
tests = TestList
  [ TestLabel "context reads return layers and inherited essay settings" $ TestCase $ withWorkspace $ \root workspace -> do
      createDirectory (root </> "Subject")
      writeFile (root </> "Subject/essay.md") "# Essay"
      assertStatus 404 (loadContextHandler workspace "context.json")
      assertEqual "missing layers resolve to empty settings" (Right emptyEffectiveContext)
        =<< runHandler (effectiveContextHandler workspace "Subject")
      let parentLayer = layer {title = Just (SetScalar "Inherited title")}
      _ <- runHandler (createContextHandler workspace (CreateContextRequest "context.json" parentLayer))
      assertEqual "read returns saved operations" (Right parentLayer)
        =<< runHandler (loadContextHandler workspace "context.json")
      inherited <- runHandler (effectiveContextHandler workspace "Subject")
      let expected = decode "{\"title\":\"Inherited title\",\"audience\":null,\"model\":null,\"tags\":[],\"instructions\":[],\"grading_directions\":[],\"rubric\":{}}" :: Maybe EffectiveContext
      assertEqual "ancestor layer is applied" (Right <$> expected) (Just inherited)
      assertStatus 400 (loadContextHandler workspace "../context.json")
      assertStatus 400 (effectiveContextHandler workspace "../Essay")
      assertStatus 404 (effectiveContextHandler workspace "Missing")
      writeFile (root </> "context.json") "invalid json"
      assertStatus 422 (loadContextHandler workspace "context.json")
      assertStatus 422 (effectiveContextHandler workspace "Subject")
      removeFile (root </> "context.json")
      createFileLink (root </> "Subject/essay.md") (root </> "context.json")
      assertStatus 403 (loadContextHandler workspace "context.json")
      assertStatus 403 (effectiveContextHandler workspace "Subject")
  , TestLabel "context handler lifecycle and account isolation" $ TestCase $ withWorkspace $ \root workspace -> do
      createDirectory (root </> "Subject")
      createDirectory (root </> "OtherAccount")
      let path = "Subject/context.json"
          otherWorkspace = WorkspaceRoot (root </> "OtherAccount")
      assertEqual "create returns persisted layer" (Right layer)
        =<< runHandler (createContextHandler workspace (CreateContextRequest path layer))
      assertEqual "file is inside the selected workspace" (Right (Just layer))
        =<< loadContextLayer workspace path
      assertEqual "other workspace is unchanged" (Right Nothing)
        =<< loadContextLayer otherWorkspace "context.json"
      assertStatus 409 (createContextHandler workspace (CreateContextRequest path layer))
      assertStatus 404 (updateContextHandler workspace (UpdateContextRequest "context.json" layer))
      writeFile (root </> path) "broken JSON"
      assertStatus 409 (createContextHandler workspace (CreateContextRequest path layer))
      assertEqual "update repairs malformed context" (Right layer)
        =<< runHandler (updateContextHandler workspace (UpdateContextRequest path layer))
      deleted <- runHandler (deleteContextHandler workspace (DeleteContextRequest path))
      case deleted of
        Left err -> assertFailure (show err)
        Right _ -> pure ()
      assertEqual "deleted file is absent" (Right Nothing) =<< loadContextLayer workspace path
      assertStatus 404 (deleteContextHandler workspace (DeleteContextRequest path))
  , TestLabel "context mutations reject unsafe paths and symlinks" $ TestCase $ withWorkspace $ \root workspace -> do
      forM_ ["../context.json", "/context.json", "essay.md", "Missing/context.json"] $ \path -> do
        assertStatus 400 (createContextHandler workspace (CreateContextRequest path layer))
        assertStatus 400 (updateContextHandler workspace (UpdateContextRequest path layer))
        assertStatus 400 (deleteContextHandler workspace (DeleteContextRequest path))
      let outside = root </> "outside.json"
      writeFile outside "{}"
      createFileLink outside (root </> "context.json")
      assertStatus 403 (createContextHandler workspace (CreateContextRequest "context.json" layer))
      assertStatus 403 (updateContextHandler workspace (UpdateContextRequest "context.json" layer))
      assertStatus 403 (deleteContextHandler workspace (DeleteContextRequest "context.json"))
      assertEqual "linked target unchanged" "{}" =<< readFile outside
      createDirectoryLink root (root </> "Linked")
      assertStatus 403 (createContextHandler workspace (CreateContextRequest "Linked/context.json" layer))
  , TestLabel "invalid layers and filesystem errors are reported" $ TestCase $ withWorkspace $ \root workspace -> do
      let invalid = layer {title = Just (SetScalar " ")}
      assertStatus 422 (createContextHandler workspace (CreateContextRequest "context.json" invalid))
      assertEqual "invalid data is not persisted" (Right Nothing) =<< loadContextLayer workspace "context.json"
      createDirectory (root </> "context.json")
      assertStatus 500 (createContextHandler workspace (CreateContextRequest "context.json" layer))
  , TestLabel "context request bodies do not accept workspace roots" $ TestCase $ do
      let request = CreateContextRequest "context.json" layer
      assertEqual "request contains only relative path and layer"
        (object ["path" .= ("context.json" :: String), "contextLayer" .= layer])
        (case decode (encode request) of Just value -> value; Nothing -> error "invalid encoded request")
      assertEqual "request round trip" (Just request) (decode (encode request))
  ]
