{-# LANGUAGE OverloadedStrings #-}

module Essaying.Handler.Context
  ( contextHandler
  , loadContextHandler
  , effectiveContextHandler
  , createContextHandler
  , updateContextHandler
  , deleteContextHandler
  )
where

import Essaying.API.V1 (ContextApi)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (encode, object, (.=))
import Data.Text (Text)
import Essaying.Persistence.Context (saveContextLayer, deleteContextLayer, loadContextLayer, loadEffectiveContext)
import Essaying.Types.Context
  ( ContextLayer, EffectiveContext, ContextLayerError (..), EffectiveContextError (..)
  , CreateContextRequest (..), UpdateContextRequest (..), DeleteContextRequest (..)
  )
import Essaying.Types.Storage (WorkspaceRoot)
import Servant
  ( Handler, Server, (:<|>) (..), NoContent (NoContent), ServerError (..)
  , throwError, err400, err403, err404, err409, err422, err500
  )

-- | Resolve the trusted workspace root for each request.
contextHandler :: Handler WorkspaceRoot -> Server ContextApi
contextHandler resolveRoot =
  (\path -> withRoot (\root -> effectiveContextHandler root path))
    :<|> (\path -> withRoot (\root -> loadContextHandler root path))
    :<|> (\req -> withRoot (\root -> createContextHandler root req))
    :<|> (\req -> withRoot (\root -> updateContextHandler root req))
    :<|> (\req -> withRoot (\root -> deleteContextHandler root req))
  where
    withRoot :: (WorkspaceRoot -> Handler a) -> Handler a
    withRoot action = resolveRoot >>= action

loadContextHandler :: WorkspaceRoot -> FilePath -> Handler ContextLayer
loadContextHandler root path = do
  result <- liftIO $ loadContextLayer root path
  case result of
    Left err -> handleContextError err
    Right Nothing -> contextError err404 "CONTEXT_NOT_FOUND" path "Context does not exist."
    Right (Just layer) -> pure layer

effectiveContextHandler :: WorkspaceRoot -> FilePath -> Handler EffectiveContext
effectiveContextHandler root path = do
  result <- liftIO $ loadEffectiveContext root path
  case result of
    Right context -> pure context
    Left (EffectiveContextLayerError err) -> handleContextError err
    Left (EffectiveContextInvalidPath invalid) -> contextError err400 "INVALID_ESSAY_PATH" invalid "Use a workspace-relative markdown essay path."
    Left (EffectiveContextEssayNotFound missing) -> contextError err404 "ESSAY_NOT_FOUND" missing "Essay does not exist."
    Left (EffectiveContextSymbolicLink linked) -> contextError err403 "CONTEXT_SYMBOLIC_LINK" linked "Context paths must not pass through symbolic links."
    Left (EffectiveContextJsonError invalid message) -> contextError err422 "INVALID_CONTEXT" invalid message
    Left (EffectiveContextIoError invalid _) -> contextError err500 "CONTEXT_IO_ERROR" invalid "Unable to resolve essay context."

-- The caller resolves this trusted root from the selected account. Request
-- bodies contain only a workspace-relative context.json path and layer.
createContextHandler :: WorkspaceRoot -> CreateContextRequest -> Handler ContextLayer
createContextHandler root (CreateContextRequest path layer) = do
  existing <- liftIO $ loadContextLayer root path
  case existing of
    Right Nothing -> pure ()
    Right (Just _) -> contextError err409 "CONTEXT_EXISTS" path "Context already exists."
    Left (ContextLayerJsonError _ _) -> contextError err409 "CONTEXT_EXISTS" path "Context already exists."
    Left err -> handleContextError err
  persistLayer root path layer

updateContextHandler :: WorkspaceRoot -> UpdateContextRequest -> Handler ContextLayer
updateContextHandler root (UpdateContextRequest path layer) = do
  existing <- liftIO $ loadContextLayer root path
  case existing of
    Right Nothing -> contextError err404 "CONTEXT_NOT_FOUND" path "Context does not exist."
    Right (Just _) -> pure ()
    -- Allow a valid update to repair malformed context on disk.
    Left (ContextLayerJsonError _ _) -> pure ()
    Left err -> handleContextError err
  persistLayer root path layer

deleteContextHandler :: WorkspaceRoot -> DeleteContextRequest -> Handler NoContent
deleteContextHandler root (DeleteContextRequest path) = do
  result <- liftIO $ deleteContextLayer root path
  case result of
    Left err -> handleContextError err
    Right False -> contextError err404 "CONTEXT_NOT_FOUND" path "Context does not exist."
    Right True -> pure NoContent

persistLayer :: WorkspaceRoot -> FilePath -> ContextLayer -> Handler ContextLayer
persistLayer root path layer = do
  result <- liftIO $ saveContextLayer root path layer
  case result of
    Left err -> handleContextError err
    Right () -> pure layer

handleContextError :: ContextLayerError -> Handler a
handleContextError err = case err of
  ContextLayerInvalidPath path -> contextError err400 "INVALID_CONTEXT_PATH" path "Use an existing directory and a workspace-relative context.json path."
  ContextLayerSymbolicLink path -> contextError err403 "CONTEXT_SYMBOLIC_LINK" path "Context paths must not pass through symbolic links."
  ContextLayerJsonError path message -> contextError err422 "INVALID_CONTEXT" path message
  -- Do not send operating-system error strings, which may contain absolute paths.
  ContextLayerIoError path _ -> contextError err500 "CONTEXT_IO_ERROR" path "Unable to access the context file."

contextError :: ServerError -> Text -> FilePath -> String -> Handler a
contextError status code path message = throwError status
  { errBody = encode $ object
      [ "error" .= object
          [ "code" .= code
          , "message" .= message
          , "details" .= object ["path" .= path]
          ]
      ]
  , errHeaders = [("Content-Type", "application/json")]
  }
