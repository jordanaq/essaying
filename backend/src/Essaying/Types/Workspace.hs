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