{-# LANGUAGE OverloadedStrings #-}

module Essaying.Handler.Workspace (
  workspaceHandler,
)
where

import Control.Exception (IOException, try)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Essaying.API.V1 (EssayApi, WorkspaceApi)
import Essaying.Handler.Ai (aiHandler)
import Essaying.Handler.Context (contextHandler)
import Essaying.Handler.ContextError (contextError)
import Essaying.Persistence.Account (readAccountProfile)
import Essaying.Persistence.Workspace (
  createWorkspaceDirectory,
  createWorkspaceEssay,
  deleteWorkspaceDirectory,
  deleteWorkspaceEssay,
  isSafeSegment,
  listWorkspaceTree,
  loadWorkspaceEssay,
  saveWorkspaceEssay,
 )
import Essaying.Storage (accountRoot, resolveCacheRoot, usersRoot, workspaceRoot)
import Essaying.Types.Account (AccountId (..))
import Essaying.Types.Storage (WorkspaceRoot)
import Essaying.Types.Workspace (
  CreateWorkspaceDirectoryRequest (..),
  CreateWorkspaceDirectoryResult (..),
  CreateWorkspaceEssayRequest (..),
  CreateWorkspaceEssayResult (..),
  SaveWorkspaceEssayRequest (..),
  WorkspaceDeleteResult (..),
  WorkspaceEssayContent (..),
  WorkspaceNode (..),
  WorkspacePathError (..),
  WorkspaceTreeResponse (..),
 )
import Servant (Handler, NoContent (NoContent), Server, err400, err403, err404, err409, err500, throwError, (:<|>) (..))

-- | Compose tree, essay, directory, context, and AI routes for one account ID.
workspaceHandler :: Text -> Server WorkspaceApi
workspaceHandler accountIdText =
  listWorkspaceTreeHandler accountIdText
    :<|> essayRoutes accountIdText
    :<|> createWorkspaceEssayHandler accountIdText
    :<|> deleteWorkspaceDirectoryHandler accountIdText
    :<|> createWorkspaceDirectoryHandler accountIdText
    :<|> contextHandler (resolveContextWorkspaceRoot accountIdText)
    :<|> aiHandler (AccountId accountIdText)

-- | Bind essay read, save, and deletion routes to the captured path segments.
essayRoutes :: Text -> [Text] -> Server EssayApi
essayRoutes accountIdText essayPath =
  loadWorkspaceEssayHandler accountIdText essayPath
    :<|> ( saveWorkspaceEssayHandler accountIdText essayPath
             :<|> deleteWorkspaceEssayHandler accountIdText essayPath
         )

{- | Delete an essay directory and return no content, translating path failures
through 'handleWorkspacePathError'. Filesystem exceptions propagate.
-}
deleteWorkspaceEssayHandler :: Text -> [Text] -> Handler NoContent
deleteWorkspaceEssayHandler accountIdText essayPath = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  result <- liftIO $ deleteWorkspaceEssay wsRoot essayPath
  case result of
    WorkspaceDeleteSucceeded -> pure NoContent
    WorkspaceDeleteFailed pathError -> handleWorkspacePathError pathError

{- | Recursively delete an ordinary workspace directory, including nested essays.
Translate path failures to HTTP errors; filesystem exceptions propagate.
-}
deleteWorkspaceDirectoryHandler :: Text -> [Text] -> Handler NoContent
deleteWorkspaceDirectoryHandler accountIdText directoryPath = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  result <- liftIO $ deleteWorkspaceDirectory wsRoot directoryPath
  case result of
    WorkspaceDeleteSucceeded -> pure NoContent
    WorkspaceDeleteFailed pathError -> handleWorkspacePathError pathError

{- | Translate missing targets to 404 and symbolic links to 403.
Invalid paths, nested essays, root deletion, and wrong target types return 400.
-}
handleWorkspacePathError :: WorkspacePathError -> Handler a
handleWorkspacePathError pathError =
  case pathError of
    WorkspacePathInvalidPath _ -> throwError err400
    WorkspacePathNestedEssay _ -> throwError err400
    WorkspacePathRootDenied -> throwError err400
    WorkspacePathTargetNotFound _ -> throwError err404
    WorkspacePathWrongTargetType _ -> throwError err400
    WorkspacePathSymbolicLink _ -> throwError err403

-- | Resolve the on-disk workspace root for the given account.
resolveWorkspaceRoot :: Text -> Handler WorkspaceRoot
resolveWorkspaceRoot accountIdText = do
  cacheRoot <- liftIO resolveCacheRoot
  let acctRoot = accountRoot (usersRoot cacheRoot) (AccountId accountIdText)
  pure $ workspaceRoot acctRoot

-- | Return the selected workspace tree using essay directories as leaf nodes.
listWorkspaceTreeHandler :: Text -> Handler WorkspaceTreeResponse
listWorkspaceTreeHandler accountIdText = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  nodes <- liftIO $ listWorkspaceTree wsRoot
  pure $ WorkspaceTreeResponse nodes

{- | Load saved essay content, returning 404 when persistence yields Nothing.
Filesystem exceptions propagate.
-}
loadWorkspaceEssayHandler :: Text -> [Text] -> Handler WorkspaceEssayContent
loadWorkspaceEssayHandler accountIdText essayPath = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  mContent <- liftIO $ loadWorkspaceEssay wsRoot essayPath
  case mContent of
    Nothing -> throwError err404
    Just content -> pure content

{- | Save the supplied prompt or draft field and reload the resulting essay.
Return 404 if saving fails validation or reloading yields Nothing. The HTTP
request decoder requires exactly one field; filesystem exceptions propagate.
-}
saveWorkspaceEssayHandler :: Text -> [Text] -> SaveWorkspaceEssayRequest -> Handler WorkspaceEssayContent
saveWorkspaceEssayHandler accountIdText essayPath (SaveWorkspaceEssayRequest newPrompt newMarkdown) = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  didSave <- liftIO $ saveWorkspaceEssay wsRoot essayPath newPrompt newMarkdown
  if didSave
    then do
      mContent <- liftIO $ loadWorkspaceEssay wsRoot essayPath
      case mContent of
        Nothing -> throwError err404
        Just content -> pure content
    else throwError err404

{- | Create a directory and return its node. Existing targets return 409;
reported creation failures return 400. Filesystem exceptions propagate.
-}
createWorkspaceDirectoryHandler :: Text -> CreateWorkspaceDirectoryRequest -> Handler WorkspaceNode
createWorkspaceDirectoryHandler accountIdText (CreateWorkspaceDirectoryRequest reqParentPath reqDirectoryName) = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  result <- liftIO $ createWorkspaceDirectory wsRoot reqParentPath reqDirectoryName
  case result of
    WorkspaceDirectoryCreated node -> pure node
    WorkspaceDirectoryAlreadyExists -> throwError err409
    WorkspaceDirectoryCreationFailed _ -> throwError err400

{- | Create an essay directory and return its saved content. Existing essays
or conflicting directories return 409; reported creation failures return 400.
-}
createWorkspaceEssayHandler :: Text -> CreateWorkspaceEssayRequest -> Handler WorkspaceEssayContent
createWorkspaceEssayHandler accountIdText (CreateWorkspaceEssayRequest reqParentPath reqEssayName reqPrompt reqMarkdown) = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  result <- liftIO $ createWorkspaceEssay wsRoot reqParentPath reqEssayName reqPrompt reqMarkdown
  case result of
    WorkspaceEssayCreated content -> pure content
    WorkspaceEssayAlreadyExists -> throwError err409
    WorkspaceEssayClobbersDirectory -> throwError err409
    WorkspaceEssayCreationFailed _ -> throwError err400

{- | Validate the account ID and require a readable, consistent account profile
before context access. Return structured errors: 400 for an invalid ID, 404
for an unavailable profile, and 500 for filesystem exceptions.
-}
resolveContextWorkspaceRoot :: Text -> Handler WorkspaceRoot
resolveContextWorkspaceRoot accountIdText
  | not (isSafeSegment accountIdText) =
      contextError err400 "INVALID_ACCOUNT_ID" "" "Select a valid account."
  | otherwise = do
      result <- liftIO (try resolve :: IO (Either IOException (Maybe WorkspaceRoot)))
      case result of
        Left _ -> contextError err500 "CONTEXT_IO_ERROR" "" "Unable to access the selected account."
        Right Nothing -> contextError err404 "ACCOUNT_NOT_FOUND" "" "Select an existing account."
        Right (Just root) -> pure root
 where
  resolve = do
    cacheRoot <- resolveCacheRoot
    let root = accountRoot (usersRoot cacheRoot) (AccountId accountIdText)
    profile <- readAccountProfile root
    pure (workspaceRoot root <$ profile)
