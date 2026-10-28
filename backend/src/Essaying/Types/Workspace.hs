{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}

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

import Data.Aeson (FromJSON, ToJSON)
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
  , markdown :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data SaveWorkspaceEssayRequest = SaveWorkspaceEssayRequest
  { markdown :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

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
