{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DisambiguateRecordFields #-}

-- | Account-scoped AI orchestration and safe public failure mapping.
-- Context and saved essay inputs are loaded here; network details stay in the
-- provider adapter, and AI results do not modify workspace files.
module Essaying.Handler.Ai
where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Control.Monad.IO.Class (liftIO)
import Control.Monad (when)
import Data.Text (Text)
import Data.Text qualified as Text
import Essaying.API.V1 (AiApi)
import Essaying.Handler.Context (effectiveContextHandler)
import Essaying.Persistence.Account (readAccountProfile)
import Essaying.Persistence.Workspace (isSafeSegment, loadWorkspaceEssay)
import Essaying.Provider.OpenAiCompatible (generateGrade, generatePrompts)
import Essaying.Storage (accountRoot, resolveCacheRoot, usersRoot, workspaceRoot)
import Essaying.Types.Account (AccountId (..), AccountProfile (..))
import Essaying.Types.Ai (
    CriterionGrade (..)
  , GradeRequest (..)
  , GradeResponse (..)
  , ProviderError (..)
  , PromptRequest (..)
  , PromptResponse (..)
  , ProviderGrade (..)
  , ProviderCriterionGrade (..)
  )
import Essaying.Types.Context (EffectiveContext (..), RubricCriterion (..))
import Essaying.Types.Storage (WorkspaceRoot)
import Essaying.Types.Workspace (WorkspaceEssayContent (..))
import Servant (
    Handler
  , Server
  , ServerError (errBody)
  , err400
  , err404
  , err422
  , err500
  , err501
  , err502
  , err504
  , throwError
  , (:<|>) (..)
  )

-- | Compose prompt and grade routes, resolving the selected account per request.
aiHandler :: AccountId -> Server AiApi
aiHandler accountId =
  ( \req -> do
      (root, profile) <- resolveAiAccount accountId
      promptHandler root profile req
  )
    :<|> ( \req -> do
             (root, profile) <- resolveAiAccount accountId
             gradeHandler root profile req
         )

-- | Validate the account ID and load its profile and workspace root.
-- Account selection is local routing context, not authentication.
resolveAiAccount :: AccountId -> Handler (WorkspaceRoot, AccountProfile)
resolveAiAccount accountId@(AccountId accountIdText)
  | not (isSafeSegment accountIdText) = throwError err400{errBody = "Invalid account ID"}
  | otherwise = do
      cacheRoot <- liftIO $ resolveCacheRoot
      let acctRoot = accountRoot (usersRoot cacheRoot) accountId

      profile <- liftIO $ readAccountProfile acctRoot
      case profile of
        Nothing -> throwError err404{errBody = "Account profile not found"}
        Just p -> pure (workspaceRoot acctRoot, p)

-- | Resolve context once, prefer its model over the account default, and return
-- fresh assignment candidates without loading the draft or saving an assignment.
promptHandler :: WorkspaceRoot -> AccountProfile -> PromptRequest -> Handler PromptResponse
promptHandler workspaceRoot accountProfile (PromptRequest essayPath instructions) = do
  context <- effectiveContextHandler workspaceRoot essayPath

  let AccountProfile{preferredModel = accountModel} = accountProfile
      EffectiveContext{model = contextModel} = context
      selectedModel = contextModel <|> accountModel

  case selectedModel of
    Nothing -> throwError $ handleProviderError ModelNotSelected
    Just model -> do
      res <- liftIO $ generatePrompts model context instructions
      case res of
        Left err -> throwError $ handleProviderError err
        Right prompts -> pure $ PromptResponse prompts

-- | Map internal failures to corrective, application-owned public messages.
-- Never echo raw provider/configuration diagnostics. Upstream authentication
-- failures remain gateway errors rather than asking the browser to authenticate.
handleProviderError :: ProviderError -> ServerError
handleProviderError ModelNotSelected = err422{errBody = "Select a model in the essay context or account preferences."}
handleProviderError ProviderNotImplemented = err501{errBody = "This AI operation is not implemented."}
handleProviderError (GenerationFailed _) = err502{errBody = "The AI operation failed. Check the input and retry."}
handleProviderError (ProviderConfigurationMissing _) = err500{errBody = "Set OPENAI_BASE_URL and OPENAI_API_KEY in the backend environment."}
handleProviderError (ProviderConfigurationInvalid "OPENAI_BASE_URL") = err500{errBody = "Check OPENAI_BASE_URL. Use an absolute HTTP or HTTPS provider API base URL."}
handleProviderError (ProviderConfigurationInvalid "OPENAI_API_KEY") = err500{errBody = "Check OPENAI_API_KEY. The provider API key must be a single line."}
handleProviderError (ProviderConfigurationInvalid _) = err500{errBody = "Check OPENAI_BASE_URL and OPENAI_API_KEY in the backend environment."}
handleProviderError ProviderTimedOut = err504{errBody = "The AI provider request timed out. Retry or choose a faster model."}
handleProviderError ProviderConnectionFailed = err502{errBody = "Unable to connect to the AI provider. Check OPENAI_BASE_URL and network access."}
handleProviderError ProviderInvalidResponse = err502{errBody = "The AI provider returned an invalid or incomplete response. Retry or choose a model supporting the required JSON schema."}
handleProviderError (ProviderHttpError code _)
  | code == 401 = err502{errBody = "AI provider authentication failed. Check OPENAI_API_KEY for the configured provider."}
  | code == 403 = err502{errBody = "The AI provider denied access. Check API key permissions and model access."}
  | code == 404 = err502{errBody = "The AI provider could not find the model or endpoint. Check OPENAI_BASE_URL, the model ID, and Chat Completions support."}
  | code == 429 = err502{errBody = "The AI provider rate or quota limit was reached. Check quota or billing, or retry later."}
  | code `elem` [400, 422] = err502{errBody = "The AI provider rejected the request. Check the model and support for Chat Completions with strict JSON schemas."}
  | code `elem` [408, 504] = handleProviderError ProviderTimedOut
  | code >= 500 && code < 600 = err502{errBody = "The AI provider is unavailable. Try again later."}
  | otherwise = err502{errBody = "The AI provider rejected the request. Check provider configuration and model compatibility."}

-- | Grade saved inputs with one resolved context value and normalize the result.
-- Reject blank drafts and invalid rubric totals before contacting the provider.
gradeHandler :: WorkspaceRoot -> AccountProfile -> GradeRequest -> Handler GradeResponse
gradeHandler workspaceRoot accountProfile (GradeRequest path) = do
  context <- effectiveContextHandler workspaceRoot path

  let AccountProfile{preferredModel = accountModel} = accountProfile
      EffectiveContext{model = contextModel, rubric = gradingRubric} = context
      selectedModel = contextModel <|> accountModel
      totalRubricWeight = sum $ map weight $ Map.elems gradingRubric

  essay <- loadEssayForGrading workspaceRoot path

  let WorkspaceEssayContent {markdown = essayContent} = essay
  when (Text.null $ Text.strip essayContent) $
    throwError err422 { errBody = "Essay content is empty" }

  -- Context validation checks individual weights; their sum can still overflow.
  when (totalRubricWeight <= 0 || isNaN totalRubricWeight || isInfinite totalRubricWeight) $
    throwError err422 { errBody = "Grading rubric requires a finite, positive total weight" }

  case selectedModel of
    Nothing -> throwError $ handleProviderError ModelNotSelected
    Just model -> do
      res <- liftIO $ generateGrade model context essay
      case res of
        Left err -> throwError $ handleProviderError err
        Right grade -> case normalizeGrade grade gradingRubric of
          Left err -> throwError $ handleProviderError err
          Right response -> pure response

-- | Load the saved draft and optional assignment through workspace validation.
-- Called after effective-context path validation. Missing assignments become
-- empty text; filesystem exceptions become fixed public messages.
loadEssayForGrading :: WorkspaceRoot -> FilePath -> Handler WorkspaceEssayContent
loadEssayForGrading workspaceRoot path = do
  let segments = Text.splitOn "/" (Text.pack path)
  res <- liftIO
    (try $ loadWorkspaceEssay workspaceRoot segments :: IO (Either IOException (Maybe WorkspaceEssayContent)))

  case res of
    Left _ -> throwError err500 { errBody = "Unable to read the saved essay" }
    Right Nothing -> throwError err404 { errBody = "Essay not found" }
    Right (Just content) -> pure content

-- | Validate provider assessments and calculate normalized weights and the mean.
-- The rubric is expected to come from validated context (finite, nonnegative
-- individual weights); a finite positive total is checked defensively here too.
-- Zero-weight criteria remain in the result, with no contribution to the mean.
normalizeGrade :: ProviderGrade -> Map Text RubricCriterion -> Either ProviderError GradeResponse
normalizeGrade ProviderGrade{feedback = fb, criteria = crit} rubric
  | Map.keysSet rubric /= Map.keysSet crit = Left ProviderInvalidResponse
  | Text.null $ Text.strip fb = Left ProviderInvalidResponse
  | any (\ProviderCriterionGrade{score = s} -> isNaN s || isInfinite s || s < 0 || s > 100) (Map.elems crit) = Left ProviderInvalidResponse
  | any (\ProviderCriterionGrade{feedback = f} -> Text.null $ Text.strip f) (Map.elems crit) = Left ProviderInvalidResponse
  | totalWeight <= 0 || isNaN totalWeight || isInfinite totalWeight = Left $ GenerationFailed "Total weight of rubric criteria is invalid"
  | otherwise = Right $ GradeResponse { overallScore = overallScore
                                      , feedback = fb
                                      , criteria = newCriteria
                                      }
  where
    totalWeight = sum $ map weight $ Map.elems rubric
    -- The exact key-set check above prevents intersection from hiding omissions.
    newCriteria =
      Map.intersectionWith
        (\ProviderCriterionGrade{score = s, feedback = f}
          RubricCriterion{weight = w}
         -> CriterionGrade s f $ w / totalWeight) crit rubric
    overallScore = sum $ map (\CriterionGrade{score = s, normalizedWeight = w} -> s * w) $ Map.elems newCriteria
