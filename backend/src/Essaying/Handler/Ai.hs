{-# LANGUAGE OverloadedStrings #-}

module Essaying.Handler.Ai

where

import Control.Applicative ((<|>))
import Control.Monad.IO.Class (liftIO)
import Essaying.Provider.OpenAiCompatible (generatePrompts)
import Essaying.Handler.Context (effectiveContextHandler)
import Essaying.Persistence.Account (readAccountProfile)
import Essaying.Persistence.Workspace (isSafeSegment)
import Essaying.Storage (accountRoot, resolveCacheRoot, usersRoot, workspaceRoot)
import Essaying.Types.Ai
    (PromptRequest (..), PromptResponse (..), GradeRequest (..), GradeResponse (..), CriterionGrade (..), PromptProviderError(..) )
import Essaying.API.V1 (AiApi)
import Essaying.Types.Storage (WorkspaceRoot)
import Essaying.Types.Account (AccountId (..), AccountProfile (..))
import Essaying.Types.Context (EffectiveContext (..))
import Servant
  ( Handler, Server, ServerError (errBody), err400, err404, err422, err500, err501, err502, throwError, (:<|>) (..) )


aiHandler :: AccountId -> Server AiApi
aiHandler accountId =
    (\req -> do
        (root, profile) <- resolveAiAccount accountId
        promptHandler root profile req) :<|>
    (\req -> do
        (root, profile) <- resolveAiAccount accountId
        gradeHandler root profile req)

resolveAiAccount :: AccountId -> Handler (WorkspaceRoot, AccountProfile)
resolveAiAccount accountId@(AccountId accountIdText)
 | not (isSafeSegment accountIdText) = throwError err400 { errBody = "Invalid account ID" }
 | otherwise = do
    cacheRoot <- liftIO $ resolveCacheRoot
    let acctRoot = accountRoot (usersRoot cacheRoot) accountId

    profile <- liftIO $ readAccountProfile acctRoot
    case profile of
      Nothing -> throwError err404 { errBody = "Account profile not found" }
      Just p -> pure (workspaceRoot acctRoot, p)

promptHandler :: WorkspaceRoot -> AccountProfile -> PromptRequest -> Handler PromptResponse
promptHandler workspaceRoot accountProfile (PromptRequest essayPath instructions) = do
    context <- effectiveContextHandler workspaceRoot essayPath

    let AccountProfile { preferredModel = accountModel } = accountProfile
        EffectiveContext { model = contextModel } = context
        selectedModel = contextModel <|> accountModel

    case selectedModel of
        Nothing -> throwError $ handlePromptProviderError ModelNotSelected
        Just model -> do
            res <- liftIO $ generatePrompts model context instructions
            case res of
                Left err -> throwError $ handlePromptProviderError err
                Right prompts -> pure $ PromptResponse prompts


handlePromptProviderError :: PromptProviderError -> ServerError
handlePromptProviderError ModelNotSelected = err422 { errBody = "No model selected" }
handlePromptProviderError PromptProviderNotImplemented = err501 { errBody = "Prompt provider not implemented" }
handlePromptProviderError (GenerationFailed _) = err502 { errBody = "Prompt generation failed" }
handlePromptProviderError (ProviderConfigurationMissing _) = err500 { errBody = "Provider configuration missing " }

gradeHandler :: WorkspaceRoot -> AccountProfile -> GradeRequest -> Handler GradeResponse
gradeHandler workspaceRoot accountProfile gradeRequest = undefined
