{-# LANGUAGE OverloadedStrings #-}

module Essaying.Handler.Workspace
  ( workspaceHandler
  )
where

import Essaying.API.V1 (ContextApi)
import Control.Monad.IO.Class (liftIO)
import Control.Exception (IOException, try)
import Essaying.Handler.ContextError (contextError)
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
  , WorkspaceDeleteError (..)
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
workspaceHandler accountIdText =
  listWorkspaceTreeHandler accountIdText
    :<|> essayRoutes accountIdText
    :<|> createWorkspaceEssayHandler accountIdText
    :<|> deleteWorkspaceDirectoryHandler accountIdText
    :<|> createWorkspaceDirectoryHandler accountIdText
    :<|> contextHandler (resolveContextWorkspaceRoot accountIdText)

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
  handleWorkspaceDeleteResult result

deleteWorkspaceDirectoryHandler :: Text -> [Text] -> Handler NoContent
deleteWorkspaceDirectoryHandler accountIdText directoryPath = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  result <- liftIO $ deleteWorkspaceDirectory wsRoot directoryPath
  handleWorkspaceDeleteResult result

handleWorkspaceDeleteResult :: WorkspaceDeleteResult -> Handler NoContent
handleWorkspaceDeleteResult WorkspaceDeleteSucceeded = pure NoContent
handleWorkspaceDeleteResult (WorkspaceDeleteFailed deleteError) =
  case deleteError of
    WorkspaceDeleteInvalidPath _ -> throwError err400
    WorkspaceDeleteRootDenied -> throwError err400
    WorkspaceDeleteTargetNotFound _ -> throwError err404
    WorkspaceDeleteWrongTargetType _ -> throwError err400
    WorkspaceDeleteSymbolicLink _ -> throwError err403

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
saveWorkspaceEssayHandler accountIdText essayPath (SaveWorkspaceEssayRequest newMarkdown) = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  didSave <- liftIO $ saveWorkspaceEssay wsRoot essayPath newMarkdown
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
createWorkspaceEssayHandler accountIdText (CreateWorkspaceEssayRequest reqParentPath reqEssayName reqMarkdown) = do
  wsRoot <- resolveWorkspaceRoot accountIdText
  result <- liftIO $ createWorkspaceEssay wsRoot reqParentPath reqEssayName reqMarkdown
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
