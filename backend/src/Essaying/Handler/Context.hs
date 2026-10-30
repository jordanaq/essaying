{-# LANGUAGE OverloadedStrings #-}

module Essaying.Handler.Context (
  contextHandler,
  loadContextHandler,
  effectiveContextHandler,
  createContextHandler,
  updateContextHandler,
  deleteContextHandler,
)
where

import Control.Monad.IO.Class (liftIO)
import Essaying.API.V1 (ContextApi)
import Essaying.Handler.ContextError (contextError, contextValidationError)
import Essaying.Persistence.Context (deleteContextLayer, loadContextLayer, loadEffectiveContext, saveContextLayer)
import Essaying.Types.Context (
  ContextLayer,
  ContextLayerError (..),
  ContextWriteRequest (..),
  CreateContextRequest (..),
  DeleteContextRequest (..),
  EffectiveContext,
  EffectiveContextError (..),
  UpdateContextRequest (..),
  parseContextLayer,
 )
import Essaying.Types.Storage (WorkspaceRoot)
import Servant (
  Handler,
  NoContent (NoContent),
  Server,
  err400,
  err403,
  err404,
  err409,
  err500,
  (:<|>) (..),
 )

-- | Resolve the trusted workspace root for each request.
contextHandler :: Handler WorkspaceRoot -> Server ContextApi
contextHandler resolveRoot =
  (\path -> withRoot (\root -> effectiveContextHandler root path))
    :<|> (\path -> withRoot (\root -> loadContextHandler root path))
    :<|> (\req -> withRoot (\root -> createRequest root req))
    :<|> (\req -> withRoot (\root -> updateRequest root req))
    :<|> (\req -> withRoot (\root -> deleteContextHandler root req))
 where
  withRoot :: (WorkspaceRoot -> Handler a) -> Handler a
  withRoot action = resolveRoot >>= action

{- | Load one workspace-relative @context.json@ layer; absence returns 404.
Other persistence failures use the structured context error envelope.
-}
loadContextHandler :: WorkspaceRoot -> FilePath -> Handler ContextLayer
loadContextHandler root path = do
  result <- liftIO $ loadContextLayer root path
  case result of
    Left err -> handleContextError err
    Right Nothing -> contextError err404 "CONTEXT_NOT_FOUND" path "Context does not exist."
    Right (Just layer) -> pure layer

{- | Resolve inherited context for an essay directory containing @essay.md@.
Translate invalid paths, missing essays, links, invalid layers, and I/O errors
to structured 400, 404, 403, 422, and 500 responses respectively.
-}
effectiveContextHandler :: WorkspaceRoot -> FilePath -> Handler EffectiveContext
effectiveContextHandler root path = do
  result <- liftIO $ loadEffectiveContext root path
  case result of
    Right context -> pure context
    Left (EffectiveContextLayerError err) -> handleContextError err
    Left (EffectiveContextInvalidPath invalid) -> contextError err400 "INVALID_ESSAY_PATH" invalid "Use a workspace-relative markdown essay path."
    Left (EffectiveContextEssayNotFound missing) -> contextError err404 "ESSAY_NOT_FOUND" missing "Essay does not exist."
    Left (EffectiveContextSymbolicLink linked) -> contextError err403 "CONTEXT_SYMBOLIC_LINK" linked "Context paths must not pass through symbolic links."
    Left (EffectiveContextJsonError invalid diagnostic) -> contextValidationError invalid Nothing diagnostic
    Left (EffectiveContextIoError invalid _) -> contextError err500 "CONTEXT_IO_ERROR" invalid "Unable to resolve essay context."

{- | Create a layer below a trusted, account-resolved workspace root.
An existing context file returns 409, even when its JSON is malformed.
Request paths identify workspace-relative @context.json@ files.
-}
createContextHandler :: WorkspaceRoot -> CreateContextRequest -> Handler ContextLayer
createContextHandler root (CreateContextRequest path layer) = do
  existing <- liftIO $ loadContextLayer root path
  case existing of
    Right Nothing -> pure ()
    Right (Just _) -> contextError err409 "CONTEXT_EXISTS" path "Context already exists."
    Left (ContextLayerJsonError _ _) -> contextError err409 "CONTEXT_EXISTS" path "Context already exists."
    Left err -> handleContextError err
  persistLayer root path layer

{- | Replace an existing layer, allowing valid input to repair malformed JSON.
An absent file returns 404; other persistence failures retain their error mapping.
-}
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

{- | Delete a workspace-relative context file and return no content.
An absent file returns 404; other failures use structured context errors.
-}
deleteContextHandler :: WorkspaceRoot -> DeleteContextRequest -> Handler NoContent
deleteContextHandler root (DeleteContextRequest path) = do
  result <- liftIO $ deleteContextLayer root path
  case result of
    Left err -> handleContextError err
    Right False -> contextError err404 "CONTEXT_NOT_FOUND" path "Context does not exist."
    Right True -> pure NoContent

{- | Save a validated layer and return it, translating persistence failures
through 'handleContextError'. Parent directories must already exist.
-}
persistLayer :: WorkspaceRoot -> FilePath -> ContextLayer -> Handler ContextLayer
persistLayer root path layer = do
  result <- liftIO $ saveContextLayer root path layer
  case result of
    Left err -> handleContextError err
    Right () -> pure layer

{- | Map invalid paths, links, invalid JSON, and I/O failures to structured
400, 403, 422, and 500 errors. Raw operating-system diagnostics stay private.
-}
handleContextError :: ContextLayerError -> Handler a
handleContextError err = case err of
  ContextLayerInvalidPath path -> contextError err400 "INVALID_CONTEXT_PATH" path "Use an existing directory and a workspace-relative context.json path."
  ContextLayerSymbolicLink path -> contextError err403 "CONTEXT_SYMBOLIC_LINK" path "Context paths must not pass through symbolic links."
  ContextLayerJsonError path diagnostic -> contextValidationError path Nothing diagnostic
  -- Do not send operating-system error strings, which may contain absolute paths.
  ContextLayerIoError path _ -> contextError err500 "CONTEXT_IO_ERROR" path "Unable to access the context file."

{- | Validate the raw layer after envelope decoding, returning 422 with the
@contextLayer@ parameter on failure, then apply create semantics.
-}
createRequest :: WorkspaceRoot -> ContextWriteRequest -> Handler ContextLayer
createRequest root (ContextWriteRequest path value) =
  case parseContextLayer value of
    Left diagnostic -> contextValidationError path (Just "contextLayer") diagnostic
    Right layer -> createContextHandler root (CreateContextRequest path layer)

{- | Validate the raw layer after envelope decoding, returning 422 with the
@contextLayer@ parameter on failure, then apply update semantics.
-}
updateRequest :: WorkspaceRoot -> ContextWriteRequest -> Handler ContextLayer
updateRequest root (ContextWriteRequest path value) =
  case parseContextLayer value of
    Left diagnostic -> contextValidationError path (Just "contextLayer") diagnostic
    Right layer -> updateContextHandler root (UpdateContextRequest path layer)
