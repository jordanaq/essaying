{-# LANGUAGE OverloadedStrings #-}

module Essaying.Handler.Workspace
  ( workspaceHandler
  )
where

import Essaying.API.V1 (AiApi, ContextApi)
import Control.Monad.IO.Class (liftIO)
import Control.Exception (IOException, try)
import Essaying.Handler.ContextError (contextError)
import Essaying.Handler.Ai (aiHandler)
import Essaying.Persistence.Account (readAccountProfile)
import Data.Text (Text)
import Essaying.Handler.Context (contextHandler)
import Essaying.Persistence.Workspace
  ( isSafeSegment
  , createWorkspaceDirectory
  , createWorkspaceEssay
  , deleteWorkspaceDirectory
  , deleteWorkspaceEssay
  , listWorkspaceTree
  , loadWorkspaceEssay
  , saveWorkspaceEssay
  )
import Essaying.Storage (accountRoot, resolveCacheRoot, usersRoot, workspaceRoot)
import Essaying.Types.Account (AccountId (..))
import Essaying.Types.Workspace
  ( CreateWorkspaceDirectoryRequest (..)
  , CreateWorkspaceDirectoryResult (..)
  , CreateWorkspaceEssayRequest (..)
  , CreateWorkspaceEssayResult (..)
  , WorkspaceEssayContent (..)
  , WorkspaceNode (..)
  , WorkspaceTreeResponse (..)
  , SaveWorkspaceEssayRequest (..)
  , WorkspacePathError (..)
  , WorkspaceDeleteResult (..)
  )
import Essaying.Types.Storage (WorkspaceRoot)
import Servant (Server, Handler, NoContent (NoContent), err400, err403, err404, err409, err500, throwError, (:<|>) (..))

workspaceHandler ::
  Text ->
  Handler WorkspaceTreeResponse
    :<|> ([Text] -> (Handler WorkspaceEssayContent :<|> ((SaveWorkspaceEssayRequest -> Handler WorkspaceEssayContent) :<|> Handler NoContent)))
    :<|> (CreateWorkspaceEssayRequest -> Handler WorkspaceEssayContent)
    :<|> ([Text] -> Handler NoContent)
    :<|> (CreateWorkspaceDirectoryRequest -> Handler WorkspaceNode)
    :<|> Server ContextApi
    :<|> Server AiApi
workspaceHandler accountIdText =
  listWorkspaceTreeHandler accountIdText
    :<|> essayRoutes accountIdText
    :<|> createWorkspaceEssayHandler accountIdText
    :<|> deleteWorkspaceDirectoryHandler accountIdText
    :<|> createWorkspaceDirectoryHandler accountIdText
    :<|> contextHandler (resolveContextWorkspaceRoot accountIdText)
    :<|> aiHandler (AccountId accountIdText)

essayRoutes :: Text -> [Text] -> Handler WorkspaceEssayContent :<|> ((SaveWorkspaceEssayRequest -> Handler WorkspaceEssayContent) :<|> Handler NoContent)
essayRoutes accountIdText essayPath =
  loadWorkspaceEssayHandler accountIdText essayPath
    :<|> ( saveWorkspaceEssayHandler accountIdText essayPath
        :<|> deleteWorkspaceEssayHandler accountIdText essayPath
        )

deleteWorkspaceEssayHandler :: Text -> [Text] -> Handler NoContent
deleteWorkspaceEssayHandler accountIdText essayPath = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  result <- liftIO $ deleteWorkspaceEssay wsRoot essayPath
  case result of
    WorkspaceDeleteSucceeded -> pure NoContent
    WorkspaceDeleteFailed pathError -> handleWorkspacePathError pathError

deleteWorkspaceDirectoryHandler :: Text -> [Text] -> Handler NoContent
deleteWorkspaceDirectoryHandler accountIdText directoryPath = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  result <- liftIO $ deleteWorkspaceDirectory wsRoot directoryPath
  case result of
    WorkspaceDeleteSucceeded -> pure NoContent
    WorkspaceDeleteFailed pathError -> handleWorkspacePathError pathError

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

listWorkspaceTreeHandler :: Text -> Handler WorkspaceTreeResponse
listWorkspaceTreeHandler accountIdText = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  nodes <- liftIO $ listWorkspaceTree wsRoot
  pure $ WorkspaceTreeResponse nodes

loadWorkspaceEssayHandler :: Text -> [Text] -> Handler WorkspaceEssayContent
loadWorkspaceEssayHandler accountIdText essayPath = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  mContent <- liftIO $ loadWorkspaceEssay wsRoot essayPath
  case mContent of
    Nothing -> throwError err404
    Just content -> pure content

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

createWorkspaceDirectoryHandler :: Text -> CreateWorkspaceDirectoryRequest -> Handler WorkspaceNode
createWorkspaceDirectoryHandler accountIdText (CreateWorkspaceDirectoryRequest reqParentPath reqDirectoryName) = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  result <- liftIO $ createWorkspaceDirectory wsRoot reqParentPath reqDirectoryName
  case result of
    WorkspaceDirectoryCreated node -> pure node
    WorkspaceDirectoryAlreadyExists -> throwError err409
    WorkspaceDirectoryCreationFailed _ -> throwError err400

createWorkspaceEssayHandler :: Text -> CreateWorkspaceEssayRequest -> Handler WorkspaceEssayContent
createWorkspaceEssayHandler accountIdText (CreateWorkspaceEssayRequest reqParentPath reqEssayName reqPrompt reqMarkdown) = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  result <- liftIO $ createWorkspaceEssay wsRoot reqParentPath reqEssayName reqPrompt reqMarkdown
  case result of
    WorkspaceEssayCreated content -> pure content
    WorkspaceEssayAlreadyExists -> throwError err409
    WorkspaceEssayClobbersDirectory -> throwError err409
    WorkspaceEssayCreationFailed _ -> throwError err400

-- Context endpoints require a real selected account before inspecting its files.
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
