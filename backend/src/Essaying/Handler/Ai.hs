{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DisambiguateRecordFields #-}

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
  , throwError
  , (:<|>) (..)
  )

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

handleProviderError :: ProviderError -> ServerError
handleProviderError ModelNotSelected = err422{errBody = "No model selected"}
handleProviderError ProviderNotImplemented = err501{errBody = "Prompt provider not implemented"}
handleProviderError (GenerationFailed _) = err502{errBody = "Prompt generation failed"}
handleProviderError (ProviderConfigurationMissing _) = err500{errBody = "Provider configuration missing "}
handleProviderError (ProviderHttpError code _) = err502{errBody = "The provider rejected the request"}

gradeHandler :: WorkspaceRoot -> AccountProfile -> GradeRequest -> Handler GradeResponse
gradeHandler workspaceRoot accountProfile (GradeRequest path) = do
  context <- effectiveContextHandler workspaceRoot path

  let AccountProfile{preferredModel = accountModel} = accountProfile
      EffectiveContext{model = contextModel, rubric = gradingRubric} = context
      selectedModel = contextModel <|> accountModel

  essay <- loadEssayForGrading workspaceRoot path

  let WorkspaceEssayContent {markdown = essayContent} = essay
  when (Text.null $ Text.strip essayContent) $
    throwError err422 { errBody = "Essay content is empty" }

  when (not (any (\RubricCriterion {weight = w} -> w > 0) $ Map.elems gradingRubric)) $
    throwError err422 { errBody = "Grading rubric has no criteria with positive weight" }

  case selectedModel of
    Nothing -> throwError $ handleProviderError ModelNotSelected
    Just model -> do
      res <- liftIO $ generateGrade model context essay
      case res of
        Left err -> throwError $ handleProviderError err
        Right grade -> case normalizeGrade grade gradingRubric of
          Left err -> throwError $ handleProviderError err
          Right response -> pure response

loadEssayForGrading :: WorkspaceRoot -> FilePath -> Handler WorkspaceEssayContent
loadEssayForGrading workspaceRoot path = do
  let segments = Text.splitOn "/" (Text.pack path)
  res <- liftIO
    (try $ loadWorkspaceEssay workspaceRoot segments :: IO (Either IOException (Maybe WorkspaceEssayContent)))

  case res of
    Left _ -> throwError err500 { errBody = "Unable to read the saved essay" }
    Right Nothing -> throwError err404 { errBody = "Essay not found" }
    Right (Just content) -> pure content

normalizeGrade :: ProviderGrade -> Map Text RubricCriterion -> Either ProviderError GradeResponse
normalizeGrade ProviderGrade{feedback = fb, criteria = crit} rubric
  | Map.keysSet rubric /= Map.keysSet crit = Left $ GenerationFailed "Provider grading criteria do not match the rubric"
  | Text.null $ Text.strip fb = Left $ GenerationFailed "Overall feedback is empty"
  | any (\ProviderCriterionGrade{score = s} -> isNaN s || isInfinite s || s < 0 || s > 100) (Map.elems crit) = Left $ GenerationFailed "Provider grade is outside the valid range"
  | any (\ProviderCriterionGrade{feedback = f} -> Text.null $ Text.strip f) (Map.elems crit) = Left $ GenerationFailed "Provider criterion feedback is empty"
  | totalWeight <= 0 || isNaN totalWeight || isInfinite totalWeight = Left $ GenerationFailed "Total weight of rubric criteria is invalid"
  | otherwise = Right $ GradeResponse { overallScore = overallScore
                                      , feedback = fb
                                      , criteria = newCriteria
                                      }
  where
    totalWeight = sum $ map weight $ Map.elems rubric
    newCriteria =
      Map.intersectionWith
        (\ProviderCriterionGrade{score = s, feedback = f}
          RubricCriterion{weight = w}
         -> CriterionGrade s f $ w / totalWeight) crit rubric
    overallScore = sum $ map (\CriterionGrade{score = s, normalizedWeight = w} -> s * w) $ Map.elems newCriteria
