{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module Essaying.Types.Workspace
  ( WorkspaceNodeType (..)
  , WorkspaceNode (..)
  , WorkspaceTreeResponse (..)
  , WorkspaceEssayContent (..)
  , CreateWorkspaceDirectoryRequest (..)
  , CreateWorkspaceEssayRequest (..)
  , SaveWorkspaceEssayRequest (..)
  , CreateWorkspaceDirectoryResult (..)
  , CreateWorkspaceEssayResult (..)
  , WorkspaceDeleteError (..)
  , WorkspaceDeleteResult (..)
  )
where

import Control.Monad (unless, when)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (Null), defaultOptions, genericToJSON, omitNothingFields, withObject, (.:?))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Maybe (isJust)
import Data.Text (Text)
import GHC.Generics (Generic)

data WorkspaceNodeType
  = WorkspaceDirectoryNode
  | WorkspaceEssayNode
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkspaceNode = WorkspaceNode
  { name :: Text
  , path :: [Text]
  , nodeType :: WorkspaceNodeType
  , children :: [WorkspaceNode]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype WorkspaceTreeResponse = WorkspaceTreeResponse
  { tree :: [WorkspaceNode]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkspaceEssayContent = WorkspaceEssayContent
  { path :: [Text]
  , title :: Text
  , prompt :: Text
  , markdown :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CreateWorkspaceDirectoryRequest = CreateWorkspaceDirectoryRequest
  { parentPath :: [Text]
  , directoryName :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CreateWorkspaceEssayRequest = CreateWorkspaceEssayRequest
  { parentPath :: [Text]
  , essayName :: Text
  , prompt :: Maybe Text
  , markdown :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data SaveWorkspaceEssayRequest = SaveWorkspaceEssayRequest
  { prompt :: Maybe Text
  , markdown :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SaveWorkspaceEssayRequest where
  toJSON = genericToJSON defaultOptions {omitNothingFields = True}

instance FromJSON SaveWorkspaceEssayRequest where
  parseJSON = withObject "SaveWorkspaceEssayRequest" $ \o -> do
    unless (all (`elem` ["prompt", "markdown"]) (KeyMap.keys o)) $
      fail "Unknown essay save field."
    when (any (== Null) (KeyMap.elems o)) $
      fail "Essay save fields must be strings."
    newPrompt <- o .:? "prompt"
    newMarkdown <- o .:? "markdown"
    unless (isJust newPrompt /= isJust newMarkdown) $
      fail "Provide exactly one of prompt or markdown."
    pure (SaveWorkspaceEssayRequest newPrompt newMarkdown)

-- | Result of attempting to create a directory in the workspace.
data CreateWorkspaceDirectoryResult
  = WorkspaceDirectoryCreated WorkspaceNode
  | WorkspaceDirectoryAlreadyExists
  | WorkspaceDirectoryCreationFailed Text
  deriving stock (Eq, Show)

-- | Result of attempting to create an essay in the workspace.
data CreateWorkspaceEssayResult
  = WorkspaceEssayCreated WorkspaceEssayContent
  | WorkspaceEssayAlreadyExists
  | WorkspaceEssayClobbersDirectory
  | WorkspaceEssayCreationFailed Text
  deriving stock (Eq, Show)

-- | Reason a workspace deletion was refused before removing anything.
data WorkspaceDeleteError
  = WorkspaceDeleteInvalidPath [Text]
  | WorkspaceDeleteRootDenied
  | WorkspaceDeleteTargetNotFound [Text]
  | WorkspaceDeleteWrongTargetType [Text]
  | WorkspaceDeleteSymbolicLink [Text]
  deriving stock (Eq, Show)

-- | Outcome of deleting a workspace essay or directory.
data WorkspaceDeleteResult
  = WorkspaceDeleteSucceeded
  | WorkspaceDeleteFailed WorkspaceDeleteError
  deriving stock (Eq, Show)
