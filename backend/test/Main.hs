{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Main where

import ContextErrors qualified
import ContextHandlers qualified
import WorkspaceDiscovery qualified

import ContextAcceptance qualified
import Control.Exception (finally)
import Control.Monad (when)
import Data.Aeson (decode, encode, toJSON)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Essaying.API.V1 (Api)
import Essaying.Context (applyLayer, emptyEffectiveContext)
import Essaying.Handler.Health (healthResponse, readyResponseFromContext)
import Essaying.Persistence.Account (createAccountProfile, readAccountProfile)
import Essaying.Persistence.Context
  ( loadContextLayer
  , loadEffectiveContext
  )
import Essaying.Persistence.Workspace
  ( createWorkspaceDirectory
  , createWorkspaceEssay
  , deleteWorkspaceDirectory
  , deleteWorkspaceEssay
  , isSafeSegment
  , listWorkspaceTree
  , loadWorkspaceEssay
  , safeResolvePath
  , saveWorkspaceEssay
  )
import Essaying.Server (app)
import Essaying.Storage (accountRoot, profileRoot, resolveCacheRoot, usersRoot, workspaceRoot)
import Essaying.Types.Account (AccountId (..), AccountProfile (..), CreateAccountProfileResult (..), CreateAccountRequest (..), UpdateAccountRequest)
import Essaying.Types.Context
  ( ContextWriteRequest (..), ContextLayer, DeleteContextRequest (..)
  , ContextLayerError (..)
  , EffectiveContext (..)
  , EffectiveContextError (..)
  , ListOverride (..)
  , RubricCriterion (..)
  , RubricOverride (..)
  , ScalarOverride (..)
  )
import Essaying.Types.Context qualified as ContextType (ContextLayer (..))
import Essaying.Types.Health (HealthResponse (..), ReadyResponse (..))
import Essaying.Types.Storage (CacheRoot (..), WorkspaceRoot (..))
import Essaying.Types.Workspace
  ( CreateWorkspaceDirectoryRequest
  , CreateWorkspaceDirectoryResult (..)
  , CreateWorkspaceEssayRequest
  , CreateWorkspaceEssayResult (..)
  , WorkspaceEssayContent (..)
  , WorkspaceNode (..)
  , WorkspaceNodeType (..)
  , WorkspaceTreeResponse
  , SaveWorkspaceEssayRequest (SaveWorkspaceEssayRequest)
  , WorkspaceDeleteError (..)
  , WorkspaceDeleteResult (..)
  )
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.Wai.Handler.Warp (testWithApplication)
import Servant.Client
  ( BaseUrl (..)
  , ClientM
  , Scheme (Http)
  , client
  , mkClientEnv
  , runClientM
  )
import Servant (NoContent (NoContent), (:<|>) ((:<|>)) )
import System.Directory (createDirectoryIfMissing, createDirectoryLink, createFileLink, doesDirectoryExist, getCurrentDirectory, removeFile, removePathForcibly)
import System.Environment (getArgs, lookupEnv, setEnv, unsetEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>), normalise, takeDirectory)
import Test.HUnit (Counts (..), Test (..), assertEqual, assertFailure, runTestTT)
import qualified Data.ByteString.Lazy as BL

healthClient :: ClientM HealthResponse
readyClient :: ClientM ReadyResponse
listAccountsClient :: ClientM [AccountProfile]
createAccountClient :: CreateAccountRequest -> ClientM AccountProfile
type WorkspaceClientRoutes =
  ClientM WorkspaceTreeResponse
    :<|> ([Text] -> (ClientM WorkspaceEssayContent :<|> ((SaveWorkspaceEssayRequest -> ClientM WorkspaceEssayContent) :<|> ClientM NoContent)))
    :<|> (CreateWorkspaceEssayRequest -> ClientM WorkspaceEssayContent)
    :<|> ([Text] -> ClientM NoContent)
    :<|> (CreateWorkspaceDirectoryRequest -> ClientM WorkspaceNode)
    :<|> ((FilePath -> ClientM EffectiveContext)
      :<|> (FilePath -> ClientM ContextLayer)
      :<|> (ContextWriteRequest -> ClientM ContextLayer)
      :<|> (ContextWriteRequest -> ClientM ContextLayer)
      :<|> (DeleteContextRequest -> ClientM NoContent))

accountByIdClient :: Text -> (ClientM AccountProfile :<|> (UpdateAccountRequest -> ClientM AccountProfile) :<|> ClientM NoContent :<|> WorkspaceClientRoutes)
(healthClient :<|> readyClient :<|> (listAccountsClient :<|> createAccountClient :<|> accountByIdClient)) = client (Proxy @Api)

main :: IO ()
main = do
  args <- getArgs
  counts <- runTestTT (if args == ["--workspace"] then workspaceTests else tests)
  if errors counts > 0 || failures counts > 0 then exitFailure else pure ()

tests :: Test
tests = TestList
  [ ContextErrors.tests
  , ContextHandlers.tests
  , TestLabel "context acceptance" ContextAcceptance.tests
  , TestLabel "health response value" healthResponseValue
  , TestLabel "health response json" healthResponseJson
  , TestLabel "ready response value" readyResponseValue
  , TestLabel "ready response json" readyResponseJson
  , TestLabel "context layer merge rules" contextLayerMergeRules
  , TestLabel "context layer JSON representation" contextLayerJson
  , TestLabel "context layer rejects blank strings" contextLayerRejectsBlankStrings
  , TestLabel "context layer rejects invalid operation shapes" contextLayerRejectsInvalidOperationShapes
  , TestLabel "context layer validates rubric criteria" contextLayerValidatesRubricCriteria
  , TestLabel "load one context layer" loadOneContextLayer
  , TestLabel "validate essay path for context" validateEssayPathForContext
  , TestLabel "resolve inherited context files" resolveInheritedContextFiles
  , TestLabel "resolveCacheRoot fallback" resolveCacheRootFallback
  , TestLabel "resolveCacheRoot env override" resolveCacheRootEnvOverride
  , TestLabel "context API mutations" contextApiMutations
  , TestLabel "health endpoint" healthEndpoint
  , TestLabel "ready endpoint" readyEndpoint
  , TestLabel "list accounts endpoint with sample cache" listAccountsEndpointWithSampleCache
  , TestLabel "account create and delete endpoints" createAndDeleteAccountEndpoints
  , TestLabel "create account profile duplicate returns already-exists" createAccountProfileDuplicate
  , TestLabel "read account profile rejects mismatched accountId" readAccountProfileRejectsMismatchedAccountId
  , workspaceTests
  ]

workspaceTests :: Test
workspaceTests = TestLabel "workspace" $ TestList
  [ WorkspaceDiscovery.tests
  , TestLabel "workspace path helpers" workspacePathHelpers
  , TestLabel "workspace directory and essay persistence" workspacePersistence
  , TestLabel "workspace delete endpoints" workspaceDeleteEndpoints
  ]

workspacePathHelpers :: Test
workspacePathHelpers = TestCase $ withEphemeralCacheRoot $ \cachePath -> do
  let promptUpdate = SaveWorkspaceEssayRequest (Just "Assignment") Nothing
      draftUpdate = SaveWorkspaceEssayRequest Nothing (Just "")
  assertEqual "prompt-only request round-trips without a null markdown field"
    (Just promptUpdate) (decode (encode promptUpdate))
  assertEqual "empty draft request round-trips without a null prompt field"
    (Just draftUpdate) (decode (encode draftUpdate))
  assertEqual "ordinary segment is safe" True (isSafeSegment "History")
  assertEqual "empty segment is unsafe" False (isSafeSegment "")
  assertEqual "dot-dot segment is unsafe" False (isSafeSegment "..")
  assertEqual "slash-containing segment is unsafe" False (isSafeSegment "a/b")
  let root = WorkspaceRoot (cachePath </> "workspace")
      expectedRoot = cachePath </> "workspace"
  createDirectoryIfMissing True expectedRoot
  assertEqual "safe path resolves beneath root"
    (Just (expectedRoot </> "History" </> "Essay"))
    (safeResolvePath root ["History", "Essay"])
  assertEqual "unsafe path is rejected" Nothing (safeResolvePath root ["..", "outside"])

workspacePersistence :: Test
workspacePersistence = TestCase $ withEphemeralCacheRoot $ \cachePath -> do
  let rootPath = cachePath </> "workspace"
      workspace = WorkspaceRoot rootPath
  createDirectoryIfMissing True rootPath

  createdDirectory <- createWorkspaceDirectory workspace [] "History"
  assertEqual "directory creation returns its node"
    (WorkspaceDirectoryCreated (WorkspaceNode "History" ["History"] WorkspaceDirectoryNode []))
    createdDirectory
  duplicateDirectory <- createWorkspaceDirectory workspace [] "History"
  assertEqual "duplicate directory is reported" WorkspaceDirectoryAlreadyExists duplicateDirectory

  createdEssay <- createWorkspaceEssay workspace ["History"] "French-Revolution" Nothing (Just "# Causes\n")
  let expectedEssay = WorkspaceEssayContent ["History", "French-Revolution"] "French-Revolution" "" "# Causes\n"
  assertEqual "essay creation returns content" (WorkspaceEssayCreated expectedEssay) createdEssay
  duplicateEssay <- createWorkspaceEssay workspace ["History"] "French-Revolution" Nothing Nothing
  assertEqual "duplicate essay is reported" WorkspaceEssayAlreadyExists duplicateEssay

  loadedEssay <- loadWorkspaceEssay workspace ["History", "French-Revolution"]
  assertEqual "created essay can be loaded" (Just expectedEssay) loadedEssay
  didSave <- saveWorkspaceEssay workspace ["History", "French-Revolution"] Nothing (Just "# Updated\n")
  assertEqual "existing essay can be saved" True didSave
  savedEssay <- loadWorkspaceEssay workspace ["History", "French-Revolution"]
  assertEqual "saved content can be loaded" (Just (expectedEssay {markdown = "# Updated\n"})) savedEssay

  let essayDirectory = rootPath </> "History" </> "French-Revolution"
  writeFile (essayDirectory </> "prompt.md") "Keep assignment"
  writeFile (essayDirectory </> "context.json") "{invalid"
  emptySaved <- saveWorkspaceEssay workspace ["History", "French-Revolution"] Nothing (Just "")
  assertEqual "empty draft save succeeds despite broken context" True emptySaved
  assertEqual "empty draft survives reload"
    (Just (expectedEssay {markdown = "", prompt = "Keep assignment"}))
    =<< loadWorkspaceEssay workspace ["History", "French-Revolution"]
  assertEqual "saving leaves the prompt unchanged" "Keep assignment"
    =<< readFile (essayDirectory </> "prompt.md")
  assertEqual "saving leaves local context unchanged" "{invalid"
    =<< readFile (essayDirectory </> "context.json")

  tree <- listWorkspaceTree workspace
  assertEqual "tree includes an essay directory as a leaf"
    [WorkspaceNode "History" ["History"] WorkspaceDirectoryNode
      [WorkspaceNode "French-Revolution" ["History", "French-Revolution"] WorkspaceEssayNode []]]
    tree
  writeFile (rootPath </> "History" </> "context.json") "private context"
  invalidEssayDelete <- deleteWorkspaceEssay workspace ["History", "context.json"]
  assertEqual "non-essay target is distinguished"
    (WorkspaceDeleteFailed (WorkspaceDeleteWrongTargetType ["History", "context.json"]))
    invalidEssayDelete
  missingEssayDelete <- deleteWorkspaceEssay workspace ["History", "Missing"]
  assertEqual "missing essay is distinguished"
    (WorkspaceDeleteFailed (WorkspaceDeleteTargetNotFound ["History", "Missing"]))
    missingEssayDelete
  invalidPathDelete <- deleteWorkspaceEssay workspace ["..", "outside.md"]
  assertEqual "invalid essay path is distinguished"
    (WorkspaceDeleteFailed (WorkspaceDeleteInvalidPath ["..", "outside.md"]))
    invalidPathDelete
  essayDirectoryDelete <- deleteWorkspaceEssay workspace ["History"]
  assertEqual "essay delete identifies directory targets"
    (WorkspaceDeleteFailed (WorkspaceDeleteWrongTargetType ["History"]))
    essayDirectoryDelete
  directoryEssayDelete <- deleteWorkspaceDirectory workspace ["History", "French-Revolution"]
  assertEqual "directory delete rejects essay directories"
    (WorkspaceDeleteFailed (WorkspaceDeleteWrongTargetType ["History", "French-Revolution"]))
    directoryEssayDelete
  rootDelete <- deleteWorkspaceDirectory workspace []
  assertEqual "workspace root deletion is denied"
    (WorkspaceDeleteFailed WorkspaceDeleteRootDenied)
    rootDelete
  let outsideFile = cachePath </> "outside.md"
      linkedEssay = rootPath </> "History" </> "linked.md"
  writeFile outsideFile "outside workspace"
  createFileLink outsideFile linkedEssay
  symlinkDelete <- deleteWorkspaceEssay workspace ["History", "linked.md"]
  assertEqual "essay symlink failure reports its exact path"
    (WorkspaceDeleteFailed (WorkspaceDeleteSymbolicLink ["History", "linked.md"]))
    symlinkDelete
  removeFile linkedEssay
  didDeleteEssay <- deleteWorkspaceEssay workspace ["History", "French-Revolution"]
  assertEqual "existing essay deletion succeeds" WorkspaceDeleteSucceeded didDeleteEssay
  essayAfterDelete <- loadWorkspaceEssay workspace ["History", "French-Revolution"]
  assertEqual "deleted essay no longer loads" Nothing essayAfterDelete
  assertEqual "essay deletion removes all internal files" False
    =<< doesDirectoryExist essayDirectory
  emptyCreated <- createWorkspaceEssay workspace ["History"] "Empty" Nothing Nothing
  assertEqual "creation without text creates an empty draft"
    (WorkspaceEssayCreated (WorkspaceEssayContent ["History", "Empty"] "Empty" "" "")) emptyCreated
  _ <- createWorkspaceDirectory workspace ["History"] "Notes"
  _ <- createWorkspaceEssay workspace ["History", "Notes"] "Nested" Nothing (Just "# Nested\n")
  didDeleteDirectory <- deleteWorkspaceDirectory workspace ["History"]
  assertEqual "recursive directory deletion succeeds" WorkspaceDeleteSucceeded didDeleteDirectory
  directoryAfterDelete <- doesDirectoryExist (rootPath </> "History")
  assertEqual "deleted directory is gone" False directoryAfterDelete
  missingEssay <- loadWorkspaceEssay workspace ["History", "Missing"]
  assertEqual "missing essay loads as Nothing" Nothing missingEssay
  savedMissing <- saveWorkspaceEssay workspace ["History", "Missing"] Nothing (Just "nope")
  assertEqual "missing essay cannot be saved" False savedMissing

workspaceDeleteEndpoints :: Test
workspaceDeleteEndpoints = TestCase $
  withEphemeralCacheRoot $ \cachePath -> do
    let accountId = AccountId "delete-test"
        wsRoot = workspaceRoot (accountRoot (usersRoot (CacheRoot cachePath)) accountId)
    createDirectoryIfMissing True (unWorkspaceRoot wsRoot)
    _ <- createWorkspaceEssay wsRoot [] "Remove Me" Nothing (Just "# Temporary\n")
    _ <- createWorkspaceDirectory wsRoot [] "History"
    _ <- createWorkspaceEssay wsRoot ["History"] "Nested" Nothing (Just "# Nested\n")

    withEnvVar "HESSAY_CACHE" (Just cachePath) $
      testWithApplication (pure app) $ \port -> do
        manager <- newManager defaultManagerSettings
        let env = mkClientEnv manager (BaseUrl Http "127.0.0.1" port "")
            _ :<|> _ :<|> _ :<|> workspaceRoutes = accountByIdClient "delete-test"
            _ :<|> essayRoutes :<|> _ :<|> deleteDirectory :<|> _ :<|> _ = workspaceRoutes
            _ :<|> (_ :<|> deleteEssay) = essayRoutes ["Remove Me"]

        essayResult <- runClientM deleteEssay env
        case essayResult of
          Left err -> assertFailure ("essay delete endpoint failed: " <> show err)
          Right noContent -> assertEqual "essay delete returns NoContent" NoContent noContent

        directoryResult <- runClientM (deleteDirectory ["History"]) env
        case directoryResult of
          Left err -> assertFailure ("directory delete endpoint failed: " <> show err)
          Right noContent -> assertEqual "directory delete returns NoContent" NoContent noContent

        deletedEssay <- loadWorkspaceEssay wsRoot ["Remove Me"]
        assertEqual "essay endpoint removes the requested directory" Nothing deletedEssay
        nestedEssay <- loadWorkspaceEssay wsRoot ["History", "Nested"]
        assertEqual "directory endpoint removes nested essays" Nothing nestedEssay

healthResponseValue :: Test
healthResponseValue = TestCase $ do
  let expected = HealthResponse {status = "ok"}
  assertEqual "health response should be stable" expected healthResponse

healthResponseJson :: Test
healthResponseJson = TestCase $ do
  let expected = Just healthResponse
  assertEqual "health response JSON should round-trip" expected (decode (encode healthResponse))

readyResponseValue :: Test
readyResponseValue = TestCase $ do
  let sampleContext =
        EffectiveContext
          { title = Just "History Essay"
          , audience = Just "student"
          , model = Just "llama3.1:8b"
          , tags = []
          , instructions = ["Use concise prose."]
          , grading_directions = []
          , rubric = mempty
          }
      expected =
        ReadyResponse
          { message = "System Ready"
          , sampleContext = sampleContext
          }
  assertEqual "ready response should wrap the provided context" expected (readyResponseFromContext sampleContext)

readyResponseJson :: Test
readyResponseJson = TestCase $ do
  let sampleContext =
        emptyEffectiveContext
          { title = Just "Essay"
          , rubric = mempty
          }
      response = readyResponseFromContext sampleContext
      expected = Just response
  assertEqual "ready response JSON should round-trip" expected (decode (encode response))

contextLayerMergeRules :: Test
contextLayerMergeRules = TestCase $ do
  let inherited =
        emptyEffectiveContext
          { audience = Just "student"
          , tags = ["writing"]
          , instructions = ["Be clear."]
          , rubric =
              Map.fromList
                [ ("clarity", RubricCriterion 1 Nothing)
                , ("evidence", RubricCriterion 1 Nothing)
                ]
          }
      layer =
        ContextType.ContextLayer
          { ContextType.title = Just (SetScalar "Causes")
          , ContextType.audience = Just ClearScalar
          , ContextType.model = Nothing
          , ContextType.tags = Just (AppendList ["history", "writing"])
          , ContextType.instructions = Just (ReplaceList ["Use sources."])
          , ContextType.grading_directions = Just (ReplaceList [])
          , ContextType.rubric = Just (MergeRubric (Map.singleton "evidence" (RubricCriterion 2 Nothing)))
          }
      merged = applyLayer inherited layer
  assertEqual "scalar set and clear" (Just "Causes", Nothing) (merged.title, merged.audience)
  assertEqual "tags append and deduplicate" ["writing", "history"] merged.tags
  assertEqual "instructions replace" ["Use sources."] merged.instructions
  assertEqual "empty replacement clears directions" [] merged.grading_directions
  assertEqual "rubric merge retains and overrides criteria"
    (Map.fromList
      [ ("clarity", RubricCriterion 1 Nothing)
      , ("evidence", RubricCriterion 2 Nothing)
      ])
    merged.rubric
  let cleared =
        applyLayer merged
          (layer
            { ContextType.tags = Just (ReplaceList [])
            , ContextType.rubric = Just (ReplaceRubric Map.empty)
            })
  assertEqual "replacement clears tags" [] cleared.tags
  assertEqual "replacement clears rubric" Map.empty cleared.rubric

contextLayerJson :: Test
contextLayerJson = TestCase $ do
  let source =
        "{\"audience\":{\"tag\":\"SetScalar\",\"contents\":\"student\"},\"model\":{\"tag\":\"ClearScalar\"},\"tags\":{\"tag\":\"AppendList\",\"contents\":[\"writing\"]},\"rubric\":{\"tag\":\"MergeRubric\",\"contents\":{\"clarity\":{\"weight\":1,\"description\":null}}}}"
      expected =
        ContextType.ContextLayer
          { ContextType.title = Nothing
          , ContextType.audience = Just (SetScalar "student")
          , ContextType.model = Just ClearScalar
          , ContextType.tags = Just (AppendList ["writing"])
          , ContextType.instructions = Nothing
          , ContextType.grading_directions = Nothing
          , ContextType.rubric = Just (MergeRubric (Map.singleton "clarity" (RubricCriterion 1 Nothing)))
          }
  assertEqual "documented JSON decodes" (Just expected) (decode source)
  assertEqual "layer JSON round-trips" (Just expected) (decode (encode expected))

contextLayerRejectsBlankStrings :: Test
contextLayerRejectsBlankStrings = TestCase $ do
  let invalidSources :: [(String, BL.ByteString)]
      invalidSources =
        [ ("blank title", "{\"title\":{\"tag\":\"SetScalar\",\"contents\":\"\"}}")
        , ("blank audience", "{\"audience\":{\"tag\":\"SetScalar\",\"contents\":\"  \"}}")
        , ("escaped whitespace model", "{\"model\":{\"tag\":\"SetScalar\",\"contents\":\"\\u0020\\t\"}}")
        , ("blank appended tag", "{\"tags\":{\"tag\":\"AppendList\",\"contents\":[\"valid\",\"  \"]}}")
        , ("blank replaced instruction", "{\"instructions\":{\"tag\":\"ReplaceList\",\"contents\":[\"\"]}}")
        , ("blank grading direction", "{\"grading_directions\":{\"tag\":\"AppendList\",\"contents\":[\"\\t\"]}}")
        ]
  mapM_
    (\(label, source) -> assertEqual label (Nothing :: Maybe ContextType.ContextLayer) (decode source))
    invalidSources

contextLayerRejectsInvalidOperationShapes :: Test
contextLayerRejectsInvalidOperationShapes = TestCase $ do
  let invalidSources :: [(String, BL.ByteString)]
      invalidSources =
        [ ("ClearScalar with contents", "{\"model\":{\"tag\":\"ClearScalar\",\"contents\":\"ignored\"}}")
        , ("SetScalar with extra field", "{\"title\":{\"tag\":\"SetScalar\",\"contents\":\"Essay\",\"extra\":1}}")
        , ("SetScalar without contents", "{\"title\":{\"tag\":\"SetScalar\"}}")
        , ("AppendList with extra field", "{\"tags\":{\"tag\":\"AppendList\",\"contents\":[],\"extra\":1}}")
        , ("ReplaceList without contents", "{\"instructions\":{\"tag\":\"ReplaceList\"}}")
        , ("ReplaceList with extra field", "{\"instructions\":{\"tag\":\"ReplaceList\",\"contents\":[],\"extra\":1}}")
        , ("MergeRubric with extra field", "{\"rubric\":{\"tag\":\"MergeRubric\",\"contents\":{},\"extra\":1}}")
        , ("ReplaceRubric without contents", "{\"rubric\":{\"tag\":\"ReplaceRubric\"}}")
        , ("ReplaceRubric with extra field", "{\"rubric\":{\"tag\":\"ReplaceRubric\",\"contents\":{},\"extra\":1}}")
        ]
  mapM_
    (\(label, source) -> assertEqual label (Nothing :: Maybe ContextType.ContextLayer) (decode source))
    invalidSources

contextLayerValidatesRubricCriteria :: Test
contextLayerValidatesRubricCriteria = TestCase $ do
  let invalidSources :: [(String, BL.ByteString)]
      invalidSources =
        [ ("blank merged criterion name", "{\"rubric\":{\"tag\":\"MergeRubric\",\"contents\":{\"  \":{\"weight\":1}}}}")
        , ("blank replaced criterion name", "{\"rubric\":{\"tag\":\"ReplaceRubric\",\"contents\":{\"\":{\"weight\":1}}}}")
        , ("negative weight", "{\"rubric\":{\"tag\":\"MergeRubric\",\"contents\":{\"clarity\":{\"weight\":-1}}}}")
        , ("non-finite weight", "{\"rubric\":{\"tag\":\"MergeRubric\",\"contents\":{\"clarity\":{\"weight\":1e9999}}}}")
        , ("missing weight", "{\"rubric\":{\"tag\":\"MergeRubric\",\"contents\":{\"clarity\":{}}}}")
        , ("blank description", "{\"rubric\":{\"tag\":\"MergeRubric\",\"contents\":{\"clarity\":{\"weight\":1,\"description\":\"  \"}}}}")
        ]
  mapM_
    (\(label, source) -> assertEqual label (Nothing :: Maybe ContextType.ContextLayer) (decode source))
    invalidSources
  case decode "{\"rubric\":{\"tag\":\"ReplaceRubric\",\"contents\":{\"clarity\":{\"weight\":0}}}}" :: Maybe ContextType.ContextLayer of
    Nothing -> assertFailure "zero-weight rubric criterion should be valid in a layer"
    Just _ -> pure ()

loadOneContextLayer :: Test
loadOneContextLayer = TestCase $ withEphemeralCacheRoot $ \cachePath -> do
  let rootPath = cachePath </> "workspace"
      workspace = WorkspaceRoot rootPath
      relativePath = "History/context.json"
      contextPath = rootPath </> relativePath
  createDirectoryIfMissing True (takeDirectory contextPath)
  missing <- loadContextLayer workspace relativePath
  assertEqual "missing context file contributes nothing" (Right Nothing) missing

  writeFile contextPath "{\"audience\":{\"tag\":\"SetScalar\",\"contents\":\"student\"}}"
  loaded <- loadContextLayer workspace relativePath
  let expected =
        ContextType.ContextLayer
          { ContextType.title = Nothing
          , ContextType.audience = Just (SetScalar "student")
          , ContextType.model = Nothing
          , ContextType.tags = Nothing
          , ContextType.instructions = Nothing
          , ContextType.grading_directions = Nothing
          , ContextType.rubric = Nothing
          }
  assertEqual "valid context file decodes" (Right (Just expected)) loaded

  let duplicateKeys =
        [ ("top-level key", "{\"title\":null,\"title\":null}")
        , ("escaped top-level key", "{\"title\":null,\"\\u0074itle\":null}")
        , ("nested operation key", "{\"model\":{\"tag\":\"ClearScalar\",\"tag\":\"ClearScalar\"}}")
        ]
  mapM_ (\(label, source) -> do
    writeFile contextPath source
    result <- loadContextLayer workspace relativePath
    case result of
      Left (ContextLayerJsonError _ _) -> pure ()
      other -> assertFailure ("expected duplicate " <> label <> " to fail, got " <> show other)) duplicateKeys

  writeFile contextPath "{invalid"
  invalid <- loadContextLayer workspace relativePath
  case invalid of
    Left (ContextLayerJsonError _ _) -> pure ()
    other -> assertFailure ("expected JSON error, got " <> show other)

  escaped <- loadContextLayer workspace "../context.json"
  assertEqual "workspace escape is rejected"
    (Left (ContextLayerInvalidPath "../context.json")) escaped

  removeFile contextPath
  let linkedPath = cachePath </> "linked-context.json"
  writeFile linkedPath "{}"
  createFileLink linkedPath contextPath
  linked <- loadContextLayer workspace relativePath
  assertEqual "context symlink is rejected"
    (Left (ContextLayerSymbolicLink relativePath)) linked

validateEssayPathForContext :: Test
validateEssayPathForContext = TestCase $ withEphemeralCacheRoot $ \cachePath -> do
  let rootPath = cachePath </> "workspace"
      workspace = WorkspaceRoot rootPath
      essayPath = "History/Causes"
      essayDirectory = rootPath </> essayPath
      draftPath = essayDirectory </> "essay.md"
  createDirectoryIfMissing True (rootPath </> "History")

  assertEqual "missing essay is an error"
    (Left (EffectiveContextEssayNotFound essayPath))
    =<< loadEffectiveContext workspace essayPath
  assertEqual "missing ancestor is an error"
    (Left (EffectiveContextEssayNotFound "Missing/Causes"))
    =<< loadEffectiveContext workspace "Missing/Causes"
  assertEqual "path traversal is rejected"
    (Left (EffectiveContextInvalidPath "../Causes"))
    =<< loadEffectiveContext workspace "../Causes"

  createDirectoryIfMissing True essayDirectory
  assertEqual "ordinary directory without a draft marker is not an essay"
    (Left (EffectiveContextEssayNotFound essayPath))
    =<< loadEffectiveContext workspace essayPath
  writeFile draftPath ""
  assertEqual "directory with an empty draft is an essay" (Right emptyEffectiveContext)
    =<< loadEffectiveContext workspace essayPath

  removeFile draftPath
  let outsidePath = cachePath </> "outside.md"
  writeFile outsidePath "# Outside\n"
  createFileLink outsidePath draftPath
  assertEqual "draft marker symlink is rejected"
    (Left (EffectiveContextSymbolicLink "History/Causes/essay.md"))
    =<< loadEffectiveContext workspace essayPath

  let outsideDirectory = cachePath </> "outside-folder"
  createDirectoryIfMissing True (outsideDirectory </> "Causes")
  writeFile (outsideDirectory </> "Causes" </> "essay.md") "# Linked directory\n"
  createDirectoryLink outsideDirectory (rootPath </> "Linked")
  assertEqual "ancestor directory symlink is rejected"
    (Left (EffectiveContextSymbolicLink "Linked"))
    =<< loadEffectiveContext workspace "Linked/Causes"

resolveInheritedContextFiles :: Test
resolveInheritedContextFiles = TestCase $ withEphemeralCacheRoot $ \cachePath -> do
  let rootPath = cachePath </> "workspace"
      workspace = WorkspaceRoot rootPath
      essayPath = "History/French-Revolution"
      historyPath = rootPath </> "History"
      essayDirectory = historyPath </> "French-Revolution"
  createDirectoryIfMissing True essayDirectory
  writeFile (essayDirectory </> "essay.md") "# Causes\n"
  writeFile (rootPath </> "context.json")
    "{\"audience\":{\"tag\":\"SetScalar\",\"contents\":\"student\"},\"tags\":{\"tag\":\"AppendList\",\"contents\":[\"writing\"]}}"
  writeFile (historyPath </> "context.json")
    "{\"audience\":{\"tag\":\"SetScalar\",\"contents\":\"advanced\"},\"tags\":{\"tag\":\"AppendList\",\"contents\":[\"history\"]}}"

  inherited <- loadEffectiveContext workspace essayPath
  let expected =
        emptyEffectiveContext
          { audience = Just "advanced"
          , tags = ["writing", "history"]
          }
  assertEqual "root and parent contexts resolve in order" (Right expected) inherited

  writeFile (essayDirectory </> "context.json")
    "{\"tags\":{\"tag\":\"ReplaceList\",\"contents\":[\"causes\"]}}"
  replaced <- loadEffectiveContext workspace essayPath
  assertEqual "nearest directory can replace inherited tags"
    (Right (expected {tags = ["causes"]})) replaced

  writeFile (rootPath </> "context.json") "{invalid"
  invalidAncestor <- loadEffectiveContext workspace essayPath
  case invalidAncestor of
    Left (EffectiveContextLayerError (ContextLayerJsonError "context.json" _)) -> pure ()
    other -> assertFailure ("expected invalid ancestor error, got " <> show other)

resolveCacheRootFallback :: Test
resolveCacheRootFallback = TestCase $ withEphemeralCacheRoot $ \cachePath -> do
  let home = cachePath </> "home"
      expected = normalise (home </> ".cache" </> "hessaying")
  createDirectoryIfMissing True home
  withEnvVar "HOME" (Just home) $
    withEnvVar "HESSAY_CACHE" Nothing $ do
      CacheRoot resolved <- resolveCacheRoot
      assertEqual "fallback should resolve to ~/.cache/hessaying" expected resolved

resolveCacheRootEnvOverride :: Test
resolveCacheRootEnvOverride = TestCase $ do
  let requested = "/tmp/hessay-cache-test"
      expected = normalise requested
  withEnvVar "HESSAY_CACHE" (Just requested) $ do
    CacheRoot resolved <- resolveCacheRoot
    assertEqual "env override should be used when HESSAY_CACHE is set" expected resolved

withEnvVar :: String -> Maybe String -> IO a -> IO a
withEnvVar key newValue action = do
  oldValue <- lookupEnv key
  setMaybe key newValue
  action `finally` setMaybe key oldValue
  where
    setMaybe k (Just v) = setEnv k v
    setMaybe k Nothing = unsetEnv k

healthEndpoint :: Test
healthEndpoint = TestCase $
  testWithApplication (pure app) $ \port -> do
    manager <- newManager defaultManagerSettings
    let env = mkClientEnv manager (BaseUrl Http "127.0.0.1" port "")
    result <- runClientM healthClient env
    case result of
      Left err -> assertFailure (show err)
      Right response -> assertEqual "health endpoint should return ok" (HealthResponse {status = "ok"}) response

readyEndpoint :: Test
readyEndpoint = TestCase $ withEphemeralCacheRoot $ \cachePath -> do
  let profile = AccountProfile (AccountId "alice") "Alice" Nothing
      WorkspaceRoot root = workspaceRoot (accountRoot (usersRoot (CacheRoot cachePath)) (accountId profile))
  writeAccountProfileFixture cachePath profile
  createDirectoryIfMissing True root
  withEnvVar "HESSAY_CACHE" (Just cachePath) $
    testWithApplication (pure app) $ \port -> do
      manager <- newManager defaultManagerSettings
      let env = mkClientEnv manager (BaseUrl Http "127.0.0.1" port "")
          checkReady = do
            result <- runClientM readyClient env
            case result of
              Left err -> assertFailure (show err)
              Right response -> do
                assertEqual "ready endpoint message" "System Ready" (message response)
                assertEqual "readiness remains independent of user context" emptyEffectiveContext (sampleContext response)
      checkReady
      writeFile (root </> "context.json") "{\"title\":{\"tag\":\"SetScalar\",\"contents\":\"User context\"}}"
      checkReady
      writeFile (root </> "context.json") "{invalid"
      checkReady

listAccountsEndpointWithSampleCache :: Test
listAccountsEndpointWithSampleCache = TestCase $ withEphemeralCacheRoot $ \cachePath -> do
  let expectedProfiles =
        [ AccountProfile (AccountId "alice") "Alice" (Just "llama3.1:8b")
        , AccountProfile (AccountId "bob") "Bob" Nothing
        ]
  mapM_ (writeAccountProfileFixture cachePath) expectedProfiles
  withEnvVar "HESSAY_CACHE" (Just cachePath) $
    testWithApplication (pure app) $ \port -> do
      manager <- newManager defaultManagerSettings
      let env = mkClientEnv manager (BaseUrl Http "127.0.0.1" port "")
      result <- runClientM listAccountsClient env
      case result of
        Left err -> assertFailure (show err)
        Right profiles -> do
          let sortProfiles = sortOn (unAccountId . accountId)
          assertEqual "list accounts endpoint should return fixture accounts"
            (sortProfiles expectedProfiles)
            (sortProfiles profiles)

writeAccountProfileFixture :: FilePath -> AccountProfile -> IO ()
writeAccountProfileFixture cachePath profile = do
  let acctRoot = accountRoot (usersRoot (CacheRoot cachePath)) (accountId profile)
      path = profileRoot acctRoot
  createDirectoryIfMissing True (takeDirectory path)
  BL.writeFile path (encode profile)

createAccountProfileDuplicate :: Test
createAccountProfileDuplicate = TestCase $ withEphemeralCacheRoot $ \cachePath -> do
  let acctId = AccountId "alice"
      profile = AccountProfile acctId "Alice" (Just "llama3.1:8b")
      acctRoot = accountRoot (usersRoot (CacheRoot cachePath)) acctId

  firstCreate <- createAccountProfile acctRoot profile
  assertEqual "first account create should succeed" AccountCreated firstCreate
  result <- createAccountProfile acctRoot profile
  assertEqual "duplicate account create should be rejected"
    AccountAlreadyExists
    result

createAndDeleteAccountEndpoints :: Test
createAndDeleteAccountEndpoints = TestCase $
  withEphemeralCacheRoot $ \cachePath ->
    withEnvVar "HESSAY_CACHE" (Just cachePath) $
      testWithApplication (pure app) $ \port -> do
        manager <- newManager defaultManagerSettings
        let env = mkClientEnv manager (BaseUrl Http "127.0.0.1" port "")
            createReq = CreateAccountRequest "Charlie" (Just "llama3.1:8b")

        created <- runClientM (createAccountClient createReq) env
        case created of
          Left err -> assertFailure ("create failed: " <> show err)
          Right profile ->
            assertEqual
              "create endpoint should return created profile"
              (AccountProfile (AccountId "charlie") "Charlie" (Just "llama3.1:8b"))
              profile

        let getClient :<|> _ :<|> deleteClient :<|> _ = accountByIdClient "charlie"

        fetched <- runClientM getClient env
        case fetched of
          Left err -> assertFailure ("fetch after create failed: " <> show err)
          Right profile ->
            assertEqual
              "get endpoint should return created profile"
              (AccountProfile (AccountId "charlie") "Charlie" (Just "llama3.1:8b"))
              profile

        deleted <- runClientM deleteClient env
        case deleted of
          Left err -> assertFailure ("delete failed: " <> show err)
          Right noContent -> assertEqual "delete endpoint should return NoContent" NoContent noContent

        fetchedAfterDelete <- runClientM getClient env
        case fetchedAfterDelete of
          Left _ -> pure ()
          Right profile ->
            assertFailure ("expected missing account after delete, but got: " <> show profile)

readAccountProfileRejectsMismatchedAccountId :: Test
readAccountProfileRejectsMismatchedAccountId = TestCase $
  withEphemeralCacheRoot $ \cachePath -> do
    let acctRoot = accountRoot (usersRoot (CacheRoot cachePath)) (AccountId "alice")
        mismatchedProfile = AccountProfile (AccountId "bob") "Bob" Nothing
        profilePath = profileRoot acctRoot

    createDirectoryIfMissing True (takeDirectory profilePath)
    BL.writeFile profilePath (encode mismatchedProfile)

    loaded <- readAccountProfile acctRoot
    assertEqual
      "mismatched accountId in profile should be treated as invalid"
      Nothing
      loaded

withEphemeralCacheRoot :: (FilePath -> IO a) -> IO a
withEphemeralCacheRoot action = do
  cwd <- getCurrentDirectory
  let direct = normalise (cwd </> "data" </> "tmp-test-cache")
      monorepo = normalise (cwd </> "backend" </> "data" </> "tmp-test-cache")

  backendDirExists <- doesDirectoryExist (cwd </> "backend")
  let cachePath = if backendDirExists then monorepo else direct

  ensureCleanDir cachePath
  action cachePath `finally` ensureCleanDir cachePath

ensureCleanDir :: FilePath -> IO ()
ensureCleanDir dirPath = do
  exists <- doesDirectoryExist dirPath
  when exists $ removePathForcibly dirPath
  createDirectoryIfMissing True dirPath

-- Exercise the account/workspace route wiring through the generated client.
contextApiMutations :: Test
contextApiMutations = TestCase $
  withEphemeralCacheRoot $ \cachePath ->
    withEnvVar "HESSAY_CACHE" (Just cachePath) $
      testWithApplication (pure app) $ \port -> do
        manager <- newManager defaultManagerSettings
        let env = mkClientEnv manager (BaseUrl Http "127.0.0.1" port "")
            _ :<|> _ :<|> _ :<|> workspaceRoutes = accountByIdClient "contextapi"
            _ :<|> _ :<|> _ :<|> _ :<|> _ :<|> contextRoutes = workspaceRoutes
            _ :<|> _ :<|> createLayer :<|> updateLayer :<|> deleteLayer = contextRoutes
            layer = ContextType.ContextLayer Nothing Nothing Nothing Nothing Nothing Nothing Nothing
            updated = layer {ContextType.title = Just (SetScalar "Updated")}
            root = workspaceRoot (accountRoot (usersRoot (CacheRoot cachePath)) (AccountId "contextapi"))
        account <- runClientM (createAccountClient (CreateAccountRequest "ContextAPI" Nothing)) env
        case account of
          Left err -> assertFailure (show err)
          Right _ -> pure ()
        created <- runClientM (createLayer (ContextWriteRequest "context.json" (toJSON layer))) env
        case created of
          Left err -> assertFailure (show err)
          Right actual -> assertEqual "create returns layer" layer actual
        assertEqual "create persists to selected account" (Right (Just layer)) =<< loadContextLayer root "context.json"
        saved <- runClientM (updateLayer (ContextWriteRequest "context.json" (toJSON updated))) env
        case saved of
          Left err -> assertFailure (show err)
          Right actual -> assertEqual "update returns layer" updated actual
        assertEqual "update persists layer" (Right (Just updated)) =<< loadContextLayer root "context.json"
        deleted <- runClientM (deleteLayer (DeleteContextRequest "context.json")) env
        case deleted of
          Left err -> assertFailure (show err)
          Right actual -> assertEqual "delete returns no content" NoContent actual
        assertEqual "delete removes layer" (Right Nothing) =<< loadContextLayer root "context.json"
